#!/usr/bin/env python3
"""Orchestrator-Worker.

Ein eigenstaendiger kleiner Worker, der auf einem **anderen Rechner** laeuft und
Python-Aufgaben des Task-Orchestrators annimmt und ausfuehrt. Er ist bewusst
unabhaengig von der Python-Bridge: er fuehrt die Zielskripte als eigenen
Prozess aus (`scripts/<id>.py` bzw. inline-Source wie die Bridge), faengt
stdout/stderr ab und meldet ACK / Start / Ergebnis zurueck.

SICHERHEIT (wichtig - bitte lesen):

  * **Token-Pflicht.** Ohne gueltiges Token wird keine Verbindung bedient.
    `--token` (oder `--token-file`) MUSS gesetzt sein; ohne startet der Worker
    bewusst nicht. Jeder Controller-Frame vor dem HELLO-AUTH wird ignoriert,
    bis authentifiziert wurde. Faile Auth-Versuche trennen die Verbindung
    (Rate-Limit).
  * **Kein Pfad-Traversal.** Der Script-Name wird strikt validiert
    (keine '/', '\\', '..', keine absoluten Pfade) und muss als Datei direkt
    in `--scripts-dir` liegen.
  * **Nur ein Client gleichzeitig.** Eine neue Verbindung ersetzt die alte
    (logisch) - Ergebnisse werden trotzdem dedupliziert (Task-ID-Set).

Protokoll (JSON-Textnachrichten ueber WebSocket):

    Controller -> Worker    {"t":"hello_auth", "token": "..."}
    Worker  -> Controller   {"t":"hello", "worker":..., "queue_capacity":...,
                             "auth":"ok"}                      (nach Token-Check)
    Controller -> Worker    {"t":"run",     "task_id":..., "script":...,
                             "attempt": n, "command": "run"|"call",
                             "input":..., "function":..., "args":[...],
                             "kwargs": {...}, "source": "..."}

  Optional kann statt einer einzelnen Quelle ein **Projekt** mitgeschickt
  werden. Dann uebernimmt der Worker Umgebung und Build selbst:

    Controller -> Worker    {"t":"run", "task_id":..., "files": {"main.py":"...",
                             "fast.pyx":"...", "requirements.txt":"cython"},
                             "entry":"main.py", "build":"auto"|"none",
                             "requirements": "..." (optional, sonst requirements.txt)}
    Worker  -> Controller   {"t":"progress", "task_id":..., "stage":"build",
                             "fraction":0.5, "text":"Projekt kompilieren"}
    Worker  -> Controller   {"t":"result", ..., "build": {"cached":true,
                             "built":true, "key":"..."},
                             "error_hint":"...", "error_action":"...",
                             "stage":"build"}

    Controller -> Worker    {"t":"cancel",  "task_id":...}
    Controller -> Worker    {"t":"ping",    "ts":...}
    Worker  -> Controller   {"t":"heartbeat", "cpu":..,"ram":..,"queue_used":..}
    Worker  -> Controller   {"t":"ack"/"started"/"cancel_ack"/"result"/"pong",
                             "task_id":..., "attempt": n}

DISCOVERY (V1 - kein manuelles IP-Eintragen):

  Der Worker meldet sich zusaetzlich per UDP-Broadcast im lokalen Netz an.
  Der Controller (Godot ClusterManager) hoert mit und verbindet sich danach
  selbststaendig per WebSocket - niemand muss eine IP oder einen Port tippen.

    Worker  -> Broadcast  {"t":"python_bridge_worker", "proto":1, "name":...,
                           "host":..., "port":8765, "pair":true,
                           "token":"..."}      (Token nur bei --auto-pair)
    Controller -> Broadcast {"t":"python_bridge_discover"}   (Anfrage, optional)

  Der Discovery-Kanal ist bewusst **getrennt** von der Aufgabenkommunikation.
  Ohne `--auto-pair` enthaelt der Beacon **kein** Token; dann muss das Token
  einmalig auf dem Controller hinterlegt werden.

Aufruf (Token generieren mit `python -m secrets`-Einzeiler siehe Doku):

    python orchestrator_worker.py --bind 0.0.0.0 --port 8765 --name worker-a \\
        --token "$ORCHESTRATOR_TOKEN" \\
        --scripts-dir /pfad/zu/scripts

Ohne Terminal (empfohlen fuer Client-Rechner): `worker_app.py` starten - die
App kuemmert sich um Token, Discovery und Start des Workers.
"""

from __future__ import annotations

import argparse
import asyncio
import functools
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import sys
import tempfile
import threading
import time
from pathlib import Path

# python_build liegt neben dieser Datei - unabhaengig vom Aufrufort laden.
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from python_build import (  # noqa: E402 - bewusst nach dem sys.path-Eingriff
        BuildError,
        Prepared,
        ProjectBuilder,
        collect_project_dir,
        default_cache_root,
        detect_env,
        diagnose_report,
        venv_python,
    )
except ImportError as _import_error:  # pragma: no cover
    print(f"[orchestrator-worker] FEHLER: python_build.py fehlt: {_import_error}",
          file=sys.stderr)
    raise SystemExit(2) from None

try:
    from file_store import FileError, FileStore  # noqa: E402 - siehe oben
except ImportError as _import_error:  # pragma: no cover
    print(f"[orchestrator-worker] FEHLER: file_store.py fehlt: {_import_error}",
          file=sys.stderr)
    raise SystemExit(2) from None

try:
    from tls_cert import (  # noqa: E402 - selbstsignierte Zertifikate
        CertificateError,
        certificate_fingerprint,
        ensure_self_signed,
        format_fingerprint,
    )
except ImportError as _import_error:  # pragma: no cover
    print(f"[orchestrator-worker] FEHLER: tls_cert.py fehlt: {_import_error}",
          file=sys.stderr)
    raise SystemExit(2) from None

# Obergrenzen fuer den Datei-Empfang. Bewusst konservativ: der Worker soll den
# Rechner nie durch Speicher- oder Plattenverbrauch in Schwierigkeiten bringen.
_MAX_FILES_IN_REPORT = 2000                 # so viele IDs nennt der Worker im Bestand
_MAX_INPUT_FILES_PER_TASK = 64              # Eingabedateien pro Aufgabe

try:  # websockets >= 14 (neue asyncio-Implementierung)
    from websockets.asyncio.server import serve
except ImportError:  # pragma: no cover - Fallback fuer aeltere Versionen
    from websockets.server import serve  # type: ignore


# Script-Namen: Buchstaben/Zahlen/Unterstrich/Punkt/Bindestrich; kein
# Pfad-Trenner, kein "..". Damit ist path traversal strukturell ausgeschlossen.
_SAFE_SCRIPT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

# Token-Format: 16..256 Zeichen aus dem URL-sicheren Base64-Alphabet.
_SAFE_TOKEN_RE = re.compile(r"^[A-Za-z0-9_\-]{16,256}$")

_MAX_TOKEN_LEN = 256
_MAX_FRAME_BYTES = 4 * 1024 * 1024          # Schutz vor Riesen-Frames
_MAX_SOURCE_BYTES = 2 * 1024 * 1024         # Inline-Source-Limit (2 MB)
_MAX_ARGS_JSON_BYTES = 1024 * 1024          # Groesse der args/kwargs/input
_MAX_SEEN_TASKS = 4096                      # LRU-Grenze fuer Task-Dedup
_MAX_RESULTS = 512                          # LRU-Grenze fuer Ergebnis-Replay
_AUTH_ATTEMPTS_ALLOWED = 3                  # Fehlversuche pro Verbindung
_DEFAULT_DISCOVERY_PORT = 8766              # UDP-Port des Discovery-Broadcasts
_DISCOVERY_MESSAGE = "python_bridge_worker"  # Beacon-Typ (Worker -> Netz)
_DISCOVERY_REQUEST = "python_bridge_discover"  # Suchanfrage (Controller -> Netz)
_DISCOVERY_PROTO = 1                        # Protokollversion des Beacons


def _cpu_pct() -> float:
    """Grobe CPU-Auslastung ueber die Load-Average (portabel, ohne psutil)."""
    try:
        load = os.getloadavg()[0]
    except (OSError, AttributeError):
        return 0.0
    n = os.cpu_count() or 1
    return max(0.0, min(100.0, load / n * 100.0))


def _ram_pct() -> float:
    """RAM-Auslastung unter Linux ueber /proc/meminfo; sonst 0."""
    try:
        info: dict[str, int] = {}
        with open("/proc/meminfo", encoding="ascii") as handle:
            for line in handle:
                key, _, rest = line.partition(":")
                info[key.strip()] = int(rest.split()[0])
        total = info.get("MemTotal", 0)
        available = info.get("MemAvailable", info.get("MemFree", 0))
        if total > 0:
            return max(0.0, min(100.0, (total - available) / total * 100.0))
    except (OSError, ValueError):
        pass
    return 0.0


def _now_ms() -> int:
    return int(time.time() * 1000)


def _local_ip(peer: str) -> str:
    """Ermittelt die LAN-Adresse, ueber die `peer` erreichbar waere.

    Reines UDP ohne Verbindungsaufbau (kein Paket wird gesendet): damit steht
    die richtige Interface-Adresse fest, auch wenn der Rechner mehrere Netze
    hat. Faellt das fehl, wird die Peer-Adresse selbst verwendet.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect((peer, 1))
        return sock.getsockname()[0]
    except OSError:
        return ""
    finally:
        sock.close()


def _tls_log(message: str, stream=None) -> None:
    """Statuszeilen der Zertifikat-Erzeugung ausgeben.

    Standardmaessig nach stdout (die Worker-App liest das mit). Wichtig: bei
    `--diagnose` **muss** das nach stderr, sonst steht vor dem JSON noch Text
    und der Bericht ist nicht mehr maschinenlesbar.
    """
    print(f"[orchestrator-worker] {message}", file=stream or sys.stdout, flush=True)


def build_tls_context(args: argparse.Namespace, log=None) -> dict:
    """TLS-Kontext des Workers bauen (oder bewusst keiner).

    Drei Betriebsarten:

        --tls-cert/--tls-key   vorhandenes Zertifikat (z. B. aus der eigenen PKI)
        --tls-self-signed      Zertifikat automatisch erzeugen und wiederverwenden
        (nichts)               unverschluesselt - wie bisher

    Rueckgabe (immer ein dict):
        {"ctx": SSLContext|None, "mode": "off"|"file"|"self-signed",
         "fingerprint": "<64 hex>", "cert": "<pfad>", "error": ""}

    Wichtig: Wurde TLS angefordert und scheitert es, wird **nicht** heimlich
    unverschluesselt weitergearbeitet - der Aufrufer bricht dann ab. Ein
    stiller Rueckfall waere genau die Art Ueberraschung, die niemand will.
    """
    result = {"ctx": None, "mode": "off", "fingerprint": "", "cert": "", "error": ""}
    want_file = bool(getattr(args, "tls_cert", "") or getattr(args, "tls_key", ""))
    want_self = bool(getattr(args, "tls_self_signed", False))
    if not want_file and not want_self:
        return result

    cert_path = str(getattr(args, "tls_cert", "") or "")
    key_path = str(getattr(args, "tls_key", "") or "")
    if want_file:
        if not cert_path or not key_path:
            result["error"] = ("--tls-cert und --tls-key muessen **zusammen** angegeben "
                               "werden (Zertifikat und privater Schluessel).")
            return result
        for path, label in ((cert_path, "Zertifikat"), (key_path, "Schluessel")):
            if not Path(path).expanduser().is_file():
                result["error"] = f"{label} nicht gefunden: {path}"
                return result
        result["mode"] = "file"
    else:
        cache_root = (Path(getattr(args, "cache_dir", "")).expanduser()
                      if getattr(args, "cache_dir", "") else default_cache_root())
        emit = log if log is not None else _tls_log
        try:
            made = ensure_self_signed(cache_root, log=emit)
        except CertificateError as exc:
            result["error"] = str(exc)
            return result
        cert_path, key_path = made["cert"], made["key"]
        result["mode"] = "self-signed"

    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(cert_path, key_path)
    except (ssl.SSLError, OSError, ValueError) as exc:
        result["error"] = f"Zertifikat/Schluessel nicht ladbar: {exc}"
        return result
    result["ctx"] = ctx
    result["cert"] = str(cert_path)
    try:
        result["fingerprint"] = certificate_fingerprint(
            Path(cert_path).read_text(encoding="utf-8"))
    except (OSError, CertificateError):
        result["fingerprint"] = ""
    return result


def _safe_task_dir(task_id: str) -> str:
    """Task-ID wird als Verzeichnisname benutzt -> streng bereinigen."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", task_id).strip(".")
    return (cleaned or "task")[:96]


# Uebliche Einstiegsdateien - damit "Projekt starten" ohne Nachfrage klappt.
_ENTRY_CANDIDATES = ("main.py", "app.py", "run.py", "start.py", "__main__.py")


def _guess_entry(files: dict) -> str:
    """Einstiegsdatei raten, wenn der Manager keine angibt."""
    if not isinstance(files, dict):
        return ""
    for name in _ENTRY_CANDIDATES:
        if name in files:
            return name
    top_level = sorted(n for n in files
                       if isinstance(n, str) and "/" not in n and n.endswith(".py"))
    if len(top_level) == 1:
        return top_level[0]
    nested = sorted(n for n in files if isinstance(n, str) and n.endswith(".py"))
    if len(nested) == 1:
        return nested[0]
    return ""


class DiscoveryBeacon:
    """Meldet diesen Worker per UDP-Broadcast im lokalen Netz an.

    Der Beacon ist der Grund, warum auf der Managerseite **keine IP eingegeben**
    werden muss. Er enthaelt nur unkritische Metadaten; das Zugangs-Token nur,
    wenn ``auto_pair`` aktiv ist (bewusste Bequemlichkeit fuer ein vertrautes
    LAN, siehe Dokumentation).
    """

    def __init__(self, name: str, port: int, capacity: int,
                 token: str = "", auto_pair: bool = False,
                 discover_port: int = _DEFAULT_DISCOVERY_PORT,
                 interval_ms: int = 2000, tls: bool = False,
                 fingerprint: str = "") -> None:
        self.name = name
        self.port = port
        self.capacity = capacity
        self.token = token
        self.auto_pair = auto_pair
        self.discover_port = discover_port
        self.interval = max(interval_ms, 250) / 1000.0
        self.host = ""
        # Der Manager muss wissen, ob er ws:// oder wss:// sprechen soll. Der
        # Fingerabdruck ist **kein** Geheimnis (er identifiziert nur das
        # Zertifikat) und wird nur zur Anzeige/Erkennung mitgeschickt.
        self.tls = tls
        self.fingerprint = fingerprint

    def _payload(self) -> bytes:
        body: dict = {
            "t": _DISCOVERY_MESSAGE,
            "proto": _DISCOVERY_PROTO,
            "name": self.name,
            "host": self.host,
            "port": self.port,
            "queue_capacity": self.capacity,
            "pair": bool(self.auto_pair),
            "tls": bool(self.tls),
        }
        if self.tls:
            body["scheme"] = "wss"
            if self.fingerprint:
                body["fp"] = self.fingerprint
        if self.auto_pair and self.token:
            body["token"] = self.token
        return json.dumps(body).encode("utf-8")

    async def run(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        try:
            sock.bind(("0.0.0.0", 0))
        except OSError as exc:
            print(f"[orchestrator-worker] Discovery inaktiv ({exc})", flush=True)
            return
        sock.setblocking(False)
        self.host = self.host or _local_ip("8.8.8.8") or socket.gethostbyname(socket.gethostname())
        print(f"[orchestrator-worker] Discovery aktiv: {self.name} @ "
              f"{self.host}:{self.port} (UDP {self.discover_port}, "
              f"Auto-Pair: {'an' if self.auto_pair else 'aus'})", flush=True)
        loop = asyncio.get_running_loop()
        try:
            while True:
                # Direkte Suchanfragen sofort beantworten (schneller Start).
                try:
                    _data, sender = sock.recvfrom(2048)
                    payload = json.loads(_data.decode("utf-8", "replace"))
                    if isinstance(payload, dict) and str(payload.get("t", "")) == _DISCOVERY_REQUEST:
                        sock.sendto(self._payload(), sender)
                except BlockingIOError:
                    pass
                except (OSError, ValueError):
                    pass
                try:
                    sock.sendto(self._payload(), ("255.255.255.255", self.discover_port))
                except OSError:
                    pass
                await asyncio.sleep(self.interval)
        finally:
            sock.close()


class Worker:
    """Nimmt Aufgaben an, fuehrt sie aus und meldet den Verlauf zurueck."""

    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.work_root = Path(args.work_dir).expanduser().resolve() if args.work_dir \
            else Path(tempfile.gettempdir()) / "python_bridge_worker"
        # Ohne --scripts-dir ist das nur ein (leerer) Cache-Ordner; die eigentliche
        # Quelle ist dann die Inline-Source, die der Manager mitschickt.
        self.scripts_dir = Path(args.scripts_dir).expanduser().resolve() if args.scripts_dir \
            else self.work_root / "scripts"
        self.python = args.python or sys.executable
        # Umgebungs-/Build-Verwaltung (Plug & Play): Cache liegt **ausserhalb**
        # der Temp-Verzeichnisse, damit Builds Neustarts ueberleben.
        self.cache_root = (Path(args.cache_dir).expanduser().resolve()
                           if getattr(args, "cache_dir", "") else default_cache_root())
        self.auto_install = not getattr(args, "no_auto_install", False)
        self.allow_build = not getattr(args, "no_build", False)
        self.build_timeout_ms = max(int(getattr(args, "build_timeout_ms", 600000)), 1000)
        self.env_info = detect_env(self.python, self.cache_root)
        self._builder: ProjectBuilder | None = None
        self.token: str = args.token
        self.authenticated: set = set()          # websockets, die authentifiziert sind
        self.owner = None                        # aktive (authentifizierte) Verbindung
        # Eingabedateien (§11-§14): inhaltsadressierter Cache. Liegt **unter**
        # work_root, damit '--work-dir' alles an einem Ort haelt und sich ein
        # Worker-Verzeichnis komplett loeschen laesst.
        self.store = FileStore(
            self.work_root / "filedata",
            max_file_bytes=max(int(getattr(args, "max_file_mb", 512)), 1) * 1024 * 1024,
            max_total_bytes=max(int(getattr(args, "max_cache_mb", 4096)), 1) * 1024 * 1024,
            log=self._log)
        self.transfers: dict[str, dict] = {}     # transfer_id -> Laufzeitdaten
        self.bytes_received = 0
        try:
            self.files_cached = len(self.store.present_ids())
        except OSError:
            self.files_cached = 0
        self._last_status = None
        self.seen: set[str] = set()              # erkannte Task-IDs (Dedup, §10)
        self.jobs: dict[str, asyncio.Task] = {}  # laufende async Task-Jobs
        self.job_attempt: dict[str, int] = {}    # task_id -> Attempt des laufenden Jobs
        self.running: dict[str, asyncio.subprocess.Process] = {}
        self.results: dict[str, dict] = {}       # Ergebnis-Replay bei Retry
        self.cancelled: set[str] = set()
        self.active = 0
        self._tasks_handled = 0

    # ------------------------------------------------------- Umgebung / Build
    def builder(self) -> ProjectBuilder:
        """Einmal erzeugt, danach wiederverwendet (haelt den Cache warm)."""
        if self._builder is None:
            self._builder = ProjectBuilder(
                self.env_info, self.python, log=self._log,
                auto_install=self.auto_install,
                build_timeout_s=self.build_timeout_ms / 1000.0)
        return self._builder

    # -------------------------------------------------------------- Sicherheit
    @staticmethod
    def _check_script_name(script: str) -> bool:
        """Strikte Validierung: kein Traversal, keine Trenner, kein Prefix-'.'."""
        return bool(script) and bool(_SAFE_SCRIPT_RE.match(script)) \
            and ".." not in script and not script.startswith(".")

    async def _authenticate(self, websocket) -> bool:
        """Erwartet als ERSTE Nachricht hello_auth mit dem gueltigen Token.

        Alles andere vor erfolgreichem Auth wird ignoriert; nach
        `_AUTH_ATTEMPTS_ALLOWED` Fehlversuchen wird getrennt. Der Timer
        verhindert, dass unauthentifizierte Verbindungen Ressourcen binden.
        """
        deadline = time.monotonic() + max(self.args.auth_timeout_ms, 500) / 1000.0
        failures = 0
        while time.monotonic() < deadline:
            try:
                raw = await asyncio.wait_for(websocket.recv(), timeout=0.5)
            except asyncio.TimeoutError:
                continue
            except Exception:  # noqa: BLE001 - Verbindungsabbruch waehrend Auth
                return False
            if not isinstance(raw, (str, bytes)) or len(raw) > _MAX_FRAME_BYTES:
                return False
            try:
                message = json.loads(raw)
            except (TypeError, ValueError):
                failures += 1
                if failures >= _AUTH_ATTEMPTS_ALLOWED:
                    return False
                continue
            if not isinstance(message, dict) or str(message.get("t", "")) != "hello_auth":
                failures += 1
                if failures >= _AUTH_ATTEMPTS_ALLOWED:
                    return False
                continue
            token = str(message.get("token", ""))
            if _SAFE_TOKEN_RE.match(token) and secrets.compare_digest(token, self.token):
                self.authenticated.add(websocket)
                return True
            failures += 1
            self._log("WARNUNG: fehlgeschlagener Auth-Versuch")
            if failures >= _AUTH_ATTEMPTS_ALLOWED:
                return False
        return False

    # -------------------------------------------------------------- Protokoll
    async def handler(self, websocket) -> None:
        if not await self._authenticate(websocket):
            self._log("Verbindung ohne gueltiges Token getrennt")
            try:
                await websocket.close(code=4401, reason="unauthorized")
            except Exception:  # noqa: BLE001
                pass
            return

        usage = self.store.usage()
        await self._send(websocket, {
            "t": "hello",
            "worker": self.args.name,
            "queue_capacity": self.args.queue_capacity,
            "scripts_dir": str(self.scripts_dir),
            "python": self.python,
            "cache": str(self.cache_root),
            "build": self.allow_build,
            "env": self.env_info.describe(),
            "files_cached": usage["files"],
            "files_bytes": usage["bytes"],
            "auth": "ok",
        })
        # Bestandsliste: nach einem Reconnect (oder Worker-Neustart) weiss der
        # Controller sonst nicht, welche Dateien hier schon liegen - und wuerde
        # alles erneut uebertragen (§12).
        await self._send_file_have(websocket)
        self._log("Client authentifiziert und verbunden")
        # Nur EINE aktive Verbindung ist Besitzer der Jobs (siehe Klassendoku).
        self.owner = websocket
        heartbeat = asyncio.create_task(self._heartbeat(websocket))
        try:
            async for raw in websocket:
                if not isinstance(raw, (str, bytes)) or len(raw) > _MAX_FRAME_BYTES:
                    self._log("Frame verworfen (zu gross / falscher Typ)")
                    continue
                try:
                    message = json.loads(raw)
                except (TypeError, ValueError):
                    continue
                if not isinstance(message, dict):
                    continue
                await self._handle(websocket, message)
        except Exception as exc:  # noqa: BLE001 - Verbindungsabbruch ist normal
            self._log(f"Verbindung beendet: {exc}")
        finally:
            heartbeat.cancel()
            self.authenticated.discard(websocket)
            if self.owner is websocket:
                self.owner = None
                if self.transfers:
                    # Halbe Dateien nie liegen lassen: ein abgebrochener Transfer
                    # wird beim naechsten Versuch komplett neu gesendet.
                    self._log("Verbindung getrennt - laufende Datei-Transfers verworfen")
                    self.store.abort_all()
                    self.transfers.clear()
            self._log("Client getrennt")

    async def _handle(self, websocket, message: dict) -> None:
        kind = message.get("t")
        if kind == "ping":
            await self._send(websocket, {"t": "pong", "ts": message.get("ts")})
        elif kind == "run":
            await self._run(websocket, message)
        elif kind == "cancel":
            await self._cancel(websocket, message)
        elif kind == "file_begin":
            await self._file_begin(websocket, message)
        elif kind == "file_chunk":
            await self._file_chunk(websocket, message)
        elif kind == "file_end":
            await self._file_end(websocket, message)
        elif kind == "file_abort":
            self._file_abort(message)
        elif kind == "file_query":
            await self._send_file_have(websocket)

    # ----------------------------------------------------- Datei-Empfang (§13)
    async def _send_file_have(self, websocket) -> None:
        """Meldet dem Controller, welche Dateien hier schon vorhanden sind."""
        ids = self.store.present_ids()
        # Bei sehr vielen Dateien nur die neuesten nennen: die Nachricht soll
        # nicht selbst zum Problem werden (Frame-Limit).
        listed = ids[-_MAX_FILES_IN_REPORT:] if len(ids) > _MAX_FILES_IN_REPORT else ids
        await self._send(websocket, {"t": "file_have", "file_ids": listed,
                                     "count": len(ids)})

    async def _file_begin(self, websocket, message: dict) -> None:
        """Anmeldung einer Datei: 'have' (schon da) oder 'accepted'."""
        transfer_id = str(message.get("transfer_id", ""))
        try:
            state = self.store.begin(
                transfer_id,
                str(message.get("file_id", "")),
                str(message.get("name", "")),
                int(message.get("size", 0) or 0),
                str(message.get("sha256", "")),
            )
        except FileError as exc:
            self._log(f"Datei abgelehnt: {exc.message}")
            await self._send(websocket, {"t": "file_ack", "transfer_id": transfer_id,
                                         "state": "rejected", "reason": exc.message})
            return
        if state == "accepted":
            self.transfers[transfer_id] = {
                "received": 0,
                "size": int(message.get("size", 0) or 0),
                "name": Path(str(message.get("name", ""))).name,
                "percent": 0,
            }
            self._log(f"Datei-Empfang gestartet: {Path(str(message.get('name', ''))).name}"
                      f" ({int(message.get('size', 0) or 0)} Bytes)")
        else:
            self._log(f"Datei bereits vorhanden: {Path(str(message.get('name', ''))).name}"
                      " - kein Transfer noetig")
        await self._send(websocket, {"t": "file_ack", "transfer_id": transfer_id,
                                     "state": state, "file_id": str(message.get("file_id", ""))})

    async def _file_chunk(self, websocket, message: dict) -> None:
        transfer_id = str(message.get("transfer_id", ""))
        try:
            received = self.store.chunk(transfer_id, int(message.get("index", 0) or 0),
                                        str(message.get("data", "")))
        except FileError as exc:
            # Ein kaputtes/zu spaetes Stueck beendet den Transfer sauber, statt
            # einen halben Zustand stehen zu lassen.
            self.store.abort(transfer_id)
            self.transfers.pop(transfer_id, None)
            self._log(f"Datei-Stueck abgelehnt: {exc.message}")
            await self._send(websocket, {"t": "file_ack", "transfer_id": transfer_id,
                                         "state": "rejected", "reason": exc.message})
            return
        entry = self.transfers.get(transfer_id)
        if entry is not None:
            entry["received"] = received
            self._log_file_progress(entry)
        await self._send(websocket, {"t": "file_ack", "transfer_id": transfer_id,
                                     "state": "chunk_ok", "received": received})

    def _log_file_progress(self, entry: dict) -> None:
        """Alle 25 % eine Zeile: die Worker-App zeichnet daraus den Balken."""
        size = int(entry.get("size", 0)) or 0
        if size <= 0:
            return
        percent = int(int(entry.get("received", 0)) * 100 / size)
        step = percent - percent % 25
        if step <= int(entry.get("percent", 0)) or step >= 100:
            return
        entry["percent"] = step
        self._log(f"Datei {entry.get('name', '?')}: {step} %")

    async def _file_end(self, websocket, message: dict) -> None:
        transfer_id = str(message.get("transfer_id", ""))
        entry = self.transfers.pop(transfer_id, None)
        try:
            path = await _to_thread(self.store.finish, transfer_id,
                                    str(message.get("sha256", "")))
        except FileError as exc:
            self._log(f"Datei-Pruefung fehlgeschlagen: {exc.message}")
            await self._send(websocket, {"t": "file_ack", "transfer_id": transfer_id,
                                         "state": "hash_failed", "reason": exc.message})
            return
        if entry is not None:
            self.bytes_received += int(entry.get("received", 0))
            self.files_cached += 1
            self._log(f"Datei {entry.get('name', '?')}: 100 %")
        self._log(f"Datei geprueft und abgelegt (SHA-256 ok): {Path(path).name[:12]}…")
        await self._send(websocket, {"t": "file_ack", "transfer_id": transfer_id,
                                     "state": "verified",
                                     "file_id": str(message.get("sha256", "")),
                                     "bytes": int(entry.get("received", 0)) if entry else 0})

    def _file_abort(self, message: dict) -> None:
        transfer_id = str(message.get("transfer_id", ""))
        self.transfers.pop(transfer_id, None)
        self.store.abort(transfer_id)
        self._log("Datei-Transfer abgebrochen (auf Anforderung)")

    def _status_line(self) -> None:
        """Zustandszeile nur bei Aenderung - die Worker-App liest sie mit."""
        current = (self.active, self.files_cached, self.bytes_received)
        if current == self._last_status:
            return
        self._last_status = current
        self._log(f"STATUS aktiv={self.active} dateien={self.files_cached} "
                  f"empfangen={self.bytes_received}")

    async def _heartbeat(self, websocket) -> None:
        interval = max(self.args.heartbeat_ms, 100) / 1000.0
        while True:
            self._status_line()
            if not await self._send(websocket, {
                "t": "heartbeat",
                "cpu": round(_cpu_pct(), 1),
                "ram": round(_ram_pct(), 1),
                "active_tasks": self.active,
                "queue_used": self.active,
                "queue_capacity": self.args.queue_capacity,
                "files": self.store.usage()["files"],
                "bytes_received": self.bytes_received,
            }):
                return
            await asyncio.sleep(interval)

    # ------------------------------------------------------------------ Tasks
    async def _run(self, websocket, message: dict) -> None:
        task_id = str(message.get("task_id", ""))
        script = str(message.get("script", ""))
        if not task_id or len(task_id) > 128:
            return
        # Projekt-Modus: der Manager schickt die Dateien mit, dann ist der
        # Name nur noch eine Bezeichnung (die Dateipfade prueft validate_project).
        files = message.get("files")
        project_mode = isinstance(files, dict) and bool(files)
        if not project_mode and not self._check_script_name(script):
            self._log(f"ABGELEHNT: ungueltiger Script-Name {script!r}")
            result = _error_result(
                "Ungueltiger Aufgabennname",
                hint="Der Name darf nur Buchstaben, Zahlen, '_', '-' und '.' "
                     "enthalten (keine Pfade).",
                stage="run")
            result["attempt"] = int(message.get("attempt", 0) or 0)
            self.results[task_id] = result
            await self._send(websocket, {"t": "result", "task_id": task_id, **result})
            return
        attempt = int(message.get("attempt", 0) or 0)
        if task_id in self.results:
            # Ergebnis-Replay: der Controller darf nach einem Netz-Retry
            # nicht auf ein ACK ohne Ergebnis warten.
            cached = self.results[task_id].copy()
            cached["attempt"] = attempt
            await self._send(websocket, {"t": "ack", "task_id": task_id, "attempt": attempt, "duplicate": True})
            await self._send(websocket, {"t": "result", "task_id": task_id, **cached})
            return
        if task_id in self.jobs:
            # Läuft bereits. Die laufende Ausführung gehört zu einem älteren
            # Versuch; ein Retry des Controllers mit höherer Attempt-Nummer
            # bedeutet einen Neustart: alten Job abbrechen und neu starten,
            # sonst könnten zwei Versuche derselben Task parallel laufen.
            if attempt > self.job_attempt.get(task_id, 0):
                old_job = self.jobs.pop(task_id, None)
                if old_job is not None:
                    old_job.cancel()
                self.cancelled.add(task_id)
                await self._send(websocket, {"t": "ack", "task_id": task_id, "attempt": attempt})
                self._start_job(websocket, task_id, script, message, attempt)
                return
            await self._send(websocket, {"t": "ack", "task_id": task_id, "attempt": attempt, "duplicate": True})
            await self._send(websocket, {"t": "started", "task_id": task_id, "attempt": attempt})
            return
        if task_id in self.seen:
            await self._send(websocket, {"t": "ack", "task_id": task_id, "attempt": attempt, "duplicate": True})
            return
        self.seen.add(task_id)
        self._prune_task_memory()
        await self._send(websocket, {"t": "ack", "task_id": task_id, "attempt": attempt})

        if not project_mode:
            path = self.scripts_dir / f"{script}.py"
            # V1: Der Manager darf den Code als Inline-Source mitschicken. Dann ist
            # KEINE vorbereitete Skriptdatei auf dem Worker noetig (kein Ordner-
            # Management pro Rechner). Lokale Dateien bleiben als Cache/Fallback.
            has_inline_source = bool(str(message.get("source", "")))
            if not path.is_file() and not has_inline_source:
                result = _error_result(
                    f"Skript nicht gefunden: {script}.py",
                    hint="Entweder die Datei auf dem Worker ablegen oder im Manager "
                         "'Projekt/Datei senden' benutzen (dann kommt der Code mit).",
                    stage="run")
                result["attempt"] = attempt
                self.results[task_id] = result
                await self._send(websocket, {"t": "result", "task_id": task_id, **result})
                return

        self._start_job(websocket, task_id, script, message, attempt)

    def _start_job(self, websocket, task_id: str, script: str, message: dict, attempt: int) -> None:
        """Startet die Ausfuehrung als eigenen asyncio-Job (Reader bleibt frei)."""
        self.job_attempt[task_id] = attempt
        self.jobs[task_id] = asyncio.create_task(
            self._execute_task(task_id, script, message, attempt))

    async def _execute_task(self, task_id: str, script: str, message: dict, attempt: int) -> None:
        self.active += 1
        progress = _Progress(self, task_id)
        progress.start()
        try:
            await self._send_to_owner(task_id, {"t": "started", "task_id": task_id, "attempt": attempt})
            label = "Projekt" if isinstance(message.get("files"), dict) else script
            self._log(f"Task {task_id} → {label} läuft (Versuch {attempt})")
            result = await self._execute(task_id, script, message, progress)
            result["attempt"] = attempt
            self.results[task_id] = result
            self._log(f"Task {task_id} → {'OK' if result['ok'] else 'FEHLER'}"
                      + (f" ({result.get('error')})" if not result.get("ok") else ""))
            await self._send_to_owner(task_id, {"t": "result", "task_id": task_id, **result})
        except asyncio.CancelledError:
            # Abbruch (Cancel oder Neustart durch neuen Versuch): bewusst kein
            # Ergebnis speichern – der Task wurde nicht zu Ende gefuehrt.
            self._log(f"Task {task_id} → abgebrochen (Versuch {attempt})")
            raise
        except Exception as exc:  # noqa: BLE001 - niemals still haengen bleiben
            self._log(f"Task {task_id} → interner Fehler: {exc!r}")
            result = _error_result(
                f"Interner Fehler im Worker: {exc}",
                hint="Der Worker hat den Ablauf abgebrochen, statt zu haengen. "
                     "Bitte die Aufgabe erneut starten.",
                stage="run")
            result["attempt"] = attempt
            self.results[task_id] = result
            await self._send_to_owner(task_id, {"t": "result", "task_id": task_id, **result})
        finally:
            await progress.stop()
            self.active = max(0, self.active - 1)
            if self.jobs.get(task_id) is asyncio.current_task():
                self.jobs.pop(task_id, None)

    async def _send_to_owner(self, task_id: str, payload: dict) -> None:
        """Sendet an die aktive Verbindung (Besitzer der Jobs).

        Nach einem Reconnect laeuft der Job evtl. unter einer alten Verbindung;
        die Ausfuehrung ist trotzdem sicher: das Ergebnis landet in `results`
        und wird per Replay zugestellt, sobald der Controller neu anfragt.
        Gibt es keine Verbindung mehr, wird das Senden still verworfen.
        """
        if self.owner is not None:
            await self._send(self.owner, payload)

    def _make_work_dir(self, task_id: str) -> tuple[Path | None, dict | None]:
        """Temporaeres Arbeitsverzeichnis des Tasks (isoliert pro Task)."""
        work_dir = self.work_root / _safe_task_dir(task_id)
        try:
            work_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            return None, _error_result(
                f"Arbeitsverzeichnis nicht anlegbar: {exc}",
                hint="Schreibrechte im Arbeits-/Temp-Verzeichnis pruefen oder "
                     "'--work-dir' auf einen beschreibbaren Ort setzen.",
                stage="env")
        return work_dir, None

    def _materialize_inputs(self, task_id: str, message: dict,
                            target_dir: Path) -> dict | None:
        """Legt die Eingabedateien der Aufgabe ins Arbeitsverzeichnis (§11/§15).

        Der Controller schickt nur **logische** IDs (SHA-256) plus Anzeigenamen -
        niemals absolute Pfade des Hauptrechners. Der Dateiname wird erneut
        geprueft, bevor er auf die Platte kommt.

        Liefert None bei Erfolg, sonst ein fertiges Fehlerergebnis.
        """
        wanted = message.get("input_files")
        if not isinstance(wanted, list) or not wanted:
            return None
        if len(wanted) > _MAX_INPUT_FILES_PER_TASK:
            return _error_result(
                f"zu viele Eingabedateien ({len(wanted)}, Limit "
                f"{_MAX_INPUT_FILES_PER_TASK})", stage="run")
        placed: list[str] = []
        for entry in wanted:
            if not isinstance(entry, dict):
                continue
            file_id = str(entry.get("file_id", ""))
            name = str(entry.get("name", "")) or f"datei-{file_id[:12]}"
            try:
                path = self.store.materialize(file_id, name, target_dir)
            except FileError as exc:
                # Sollte nicht vorkommen (der Controller wartet auf die Dateien),
                # ist aber genau dann wichtig, wenn es doch passiert.
                return _error_result(
                    f"Eingabedatei fehlt auf diesem Rechner: {exc.message}",
                    hint="Aufgabe erneut starten - der Manager uebertraegt die "
                         "Datei dann noch einmal.", stage="run")
            placed.append(path.name)
        if placed:
            self._log(f"Task {task_id} → {len(placed)} Eingabedatei(en) bereitgestellt")
            # Die Namen stehen dem Programm als `input['_files']` zur Verfuegung.
            # Damit muss kein Skript raten, wie die Datei auf diesem Rechner heisst.
            message["_input_names"] = placed
            raw_input = message.get("input")
            if isinstance(raw_input, dict):
                raw_input["_files"] = placed
            elif raw_input is None:
                message["input"] = {"_files": placed}
        return None

    async def _execute(self, task_id: str, script: str, message: dict,
                       progress: _Progress) -> dict:
        """Fuehrt eine Aufgabe aus und liefert das Ergebnis zurueck.

        Zwei Wege, ein Ablauf:

        * **Projekt** (`files` im Auftrag): der Worker legt die Dateien im Cache
          ab, richtet bei Bedarf eine isolierte Umgebung ein, kompiliert wenn
          noetig (.pyx / setup.py) und startet dann die Einstiegsdatei.
        * **Einzelquelle** (bisheriges Verhalten): Inline-`source` oder
          `scripts-dir/<script>.py` nach der bestehenden Bridge-Semantik
          (`run` mit `input`/`result`, `call` mit Funktion/Argumenten).

        Jeder Task laeuft in einem **eigenen temporaeren Arbeitsverzeichnis**
        (siehe `--work-dir`), das nach dem Lauf wieder entfernt wird.
        """
        if task_id in self.cancelled:
            self.cancelled.discard(task_id)
            return _error_result("vor Start abgebrochen", stage="run")
        if isinstance(message.get("files"), dict) and message["files"]:
            return await self._execute_project(task_id, message, progress)
        path = self.scripts_dir / f"{script}.py"
        work_dir, work_error = self._make_work_dir(task_id)
        if work_error is not None:
            return work_error
        input_error = self._materialize_inputs(task_id, message, work_dir)
        if input_error is not None:
            _cleanup_dir(work_dir)
            return input_error
        command = str(message.get("command", "run"))
        source = str(message.get("source", ""))
        input_data = message.get("input", {})
        function = str(message.get("function", ""))
        args = message.get("args", [])
        kwargs = message.get("kwargs", {})

        if len(source) > _MAX_SOURCE_BYTES:
            return _error_result("Inline-Source zu gross (Limit 2 MB)", stage="run")
        try:
            args_blob = json.dumps({"a": args, "k": kwargs, "i": input_data})
        except (TypeError, ValueError):
            return _error_result("Argumente nicht JSON-serialisierbar",
                                 hint="args/kwargs/input muessen einfache Daten sein "
                                      "(Zahlen, Texte, Listen, Objekte).", stage="run")
        if len(args_blob) > _MAX_ARGS_JSON_BYTES:
            return _error_result("Argumente zu gross (Limit 1 MB)", stage="run")

        if not source:
            # Kein Inline-Source: die Skriptdatei selbst ist die Quelle.
            try:
                source = path.read_text(encoding="utf-8")
            except OSError as exc:
                return _error_result(f"Skript konnte nicht gelesen werden: {exc}",
                                     stage="run")

        if command == "call":
            if not function or not str(function).isidentifier():
                return _error_result(
                    f"ungueltiger Funktionsname: {function!r}",
                    hint="Im Manager den Namen einer Funktion aus dem Skript angeben.",
                    stage="run")
            runner = (
                "import json\n"
                + source + "\n"
                + "__orchestrator_value = globals()[" + repr(function) + "](*" + repr(args)
                + ", **" + repr(kwargs) + ")\n"
                + "print(json.dumps(__orchestrator_value, default=str))\n"
            )
        elif command == "run":
            runner = (
                "import json\n"
                + "__orchestrator_input = " + repr(input_data) + "\n"
                + "input = __orchestrator_input\n"
                + source + "\n"
                + "print(json.dumps(globals().get('result'), default=str))\n"
            )
        else:
            runner = source + "\n"

        runner_path = work_dir / "task.py"
        try:
            runner_path.write_text(runner, encoding="utf-8")
        except OSError as exc:
            _cleanup_dir(work_dir)
            return _error_result(
                "Temporaere Task-Datei konnte nicht geschrieben werden.",
                detail=str(exc), stage="run")
        return await self._run_process(task_id, self.python, runner_path, work_dir,
                                      command)

    # -------------------------------------------------------------- Projekte
    async def _execute_project(self, task_id: str, message: dict,
                               progress: _Progress) -> dict:
        """Projekt ablegen, Umgebung/Build besorgen, Einstieg starten."""
        files = message.get("files")
        if not isinstance(files, dict) or not files:
            return _error_result("Projektinhalt fehlt.", stage="run")
        command = str(message.get("command", "run"))
        entry = str(message.get("entry", "")).strip().replace("\\", "/")
        if entry == "":
            entry = _guess_entry(files)
        requirements = str(message.get("requirements", "") or "")
        if requirements == "":
            for name in ("requirements.txt", "Requirements.txt"):
                if name in files:
                    requirements = str(files[name])
                    break
        build_mode = str(message.get("build", "auto") or "auto")
        notes: list[str] = []
        if not self.allow_build and build_mode != "none":
            notes.append("Builds auf diesem Worker abgeschaltet (--no-build)")
            build_mode = "none"
        if entry == "":
            return _error_result(
                "Keine Einstiegsdatei bestimmt.",
                hint="Im Manager eine .py-Datei als Einstieg auswaehlen.",
                stage="run")

        builder = self.builder()
        try:
            prepared = await _to_thread(builder.prepare, files, requirements,
                                        build_mode, progress.emit)
        except BuildError as exc:
            self._log(f"Task {task_id} → {exc.stage}-Fehler: {exc.message}")
            return _error_result(exc.message, hint=exc.hint, action=exc.action,
                                 stage=exc.stage, detail=_tail(exc.detail, 4000))
        except Exception as exc:  # noqa: BLE001 - nie haengen bleiben
            return _error_result(f"Vorbereitung fehlgeschlagen: {exc}", stage="env")

        if task_id in self.cancelled:
            # Abbruch waehrend Umgebung/Build: der Build laeuft nicht abbrechbar
            # in einem Subprozess, aber gestartet wird danach nichts mehr.
            self.cancelled.discard(task_id)
            return _error_result("vor Start abgebrochen", stage="run")
        if entry not in files:
            return _error_result(
                f"Einstiegsdatei nicht im Projekt: {entry}",
                hint="Vorhanden sind: " + ", ".join(sorted(files)[:8]),
                stage="run")

        work_dir, work_error = self._make_work_dir(task_id)
        if work_error is not None:
            return work_error
        input_error = self._materialize_inputs(task_id, message, work_dir)
        if input_error is not None:
            _cleanup_dir(work_dir)
            return input_error
        runner_path = work_dir / "task.py"
        try:
            runner_path.write_text(
                self._project_runner(entry, str(prepared.project_dir), message),
                encoding="utf-8")
        except OSError as exc:
            _cleanup_dir(work_dir)
            return _error_result("Ausfuehrungsdatei konnte nicht geschrieben werden.",
                                 detail=str(exc), stage="run")

        progress.emit("run", 1.0, "Programm starten")
        result = await self._run_process(task_id, prepared.python, runner_path,
                                        work_dir, command)
        result["build"] = prepared.describe()
        result["notes"] = notes + list(prepared.notes)
        if not result.get("ok"):
            self._log(f"Task {task_id} → Vorbereitung: {json.dumps(prepared.describe())}")
        return result

    async def _run_process(self, task_id: str, python: str, runner_path: Path,
                           cwd: Path, command: str) -> dict:
        """Python-Prozess starten, Ausgabe einsammeln, aufraeumen."""
        timeout = max(self.args.task_timeout_ms, 1) / 1000.0
        try:
            process = await asyncio.create_subprocess_exec(
                python, str(runner_path),
                cwd=str(cwd),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except OSError as exc:
            _cleanup_dir(cwd)
            return _error_result(
                f"Python konnte nicht gestartet werden: {exc}",
                hint="Python-Installation auf dem Worker pruefen "
                     "(in der Worker-App: 'Umgebung pruefen').",
                stage="run")
        self.running[task_id] = process
        try:
            try:
                out, err = await asyncio.wait_for(process.communicate(), timeout=timeout)
            except (asyncio.TimeoutError, TimeoutError):
                process.kill()
                await process.wait()
                return _error_result(
                    f"Zeitueberschreitung: die Aufgabe lief laenger als "
                    f"{self.args.task_timeout_ms // 1000} s.",
                    hint="Timeout auf dem Worker erhoehen (--task-timeout-ms oder "
                         "in der Worker-App) oder die Aufgabe verkuerzen.",
                    stage="run")
        finally:
            self.running.pop(task_id, None)
            _cleanup_dir(cwd)
        return _process_result(process.returncode, out.decode(errors="replace"),
                               err.decode(errors="replace"), command,
                               self.args.max_stdout_bytes, self.args.max_stderr_bytes)

    @staticmethod
    def _project_runner(entry: str, project_dir: str, message: dict) -> str:
        """Erzeugt das kleine Startprogramm fuer ein Projekt.

        Der Projektordner liegt im Cache, das Arbeitsverzeichnis ist temporaer.
        Der Projektordner wird darum als Konstante eingebettet (statt ueber
        cwd/sys.path[0]) - so bleibt der Cache unberuehrt.

        `run`  startet die Einstiegsdatei als `__main__`; `input` ist vorbelegt
               und eine globale Variable `result` wird zurueckgemeldet.
        `call` laedt die Einstiegsdatei als Modul und ruft die Funktion auf.
        """
        command = str(message.get("command", "run"))
        header = (
            "import json\n"
            "import os\n"
            "import sys\n\n"
            f"HERE = {project_dir!r}\n"
            f"ENTRY = os.path.join(HERE, {entry!r})\n"
            "if HERE not in sys.path:\n"
            "    sys.path.insert(0, HERE)\n"
        )
        if command == "call":
            function = str(message.get("function", ""))
            args = message.get("args", [])
            kwargs = message.get("kwargs", {})
            return header + (
                "import importlib.util\n\n"
                f"_args = {args!r}\n"
                f"_kwargs = {kwargs!r}\n"
                f"_name = {function!r}\n"
                "spec = importlib.util.spec_from_file_location('_pbr_entry', ENTRY)\n"
                "if spec is None or spec.loader is None:\n"
                "    raise SystemExit('Einstiegsdatei nicht ladbar: ' + ENTRY)\n"
                "module = importlib.util.module_from_spec(spec)\n"
                "sys.modules['_pbr_entry'] = module\n"
                "spec.loader.exec_module(module)\n"
                "if not hasattr(module, _name):\n"
                "    raise SystemExit('Funktion %r nicht in %s gefunden'\n"
                "                     % (_name, ENTRY))\n"
                "print(json.dumps(getattr(module, _name)(*_args, **_kwargs),\n"
                "                 default=str))\n"
            )
        if command == "run":
            input_data = message.get("input", {})
            names = message.get("_input_names")
            if isinstance(names, list) and names and isinstance(input_data, dict):
                input_data = dict(input_data)
                input_data.setdefault("_files", list(names))
            return header + (
                f"_input = {input_data!r}\n"
                "import runpy\n"
                "# Bestehende Bridge-Semantik: `input` ist vorbelegt, das Programm\n"
                "# kann `result` setzen. Beides wird zurueckgemeldet.\n"
                "_ns = runpy.run_path(ENTRY, init_globals={'input': _input},\n"
                "                     run_name='__main__')\n"
                "print(json.dumps(_ns.get('result'), default=str))\n"
            )
        return header + (
            "import runpy\n"
            "runpy.run_path(ENTRY, run_name='__main__')\n"
        )

    async def _cancel(self, websocket, message: dict) -> None:
        task_id = str(message.get("task_id", ""))
        attempt = int(message.get("attempt", 0) or 0)
        process = self.running.get(task_id)
        running_attempt = self.job_attempt.get(task_id, 0)
        if process is not None and attempt > 0 and running_attempt > attempt:
            # Der Abbruch gehoert zu einem aelteren Versuch. Der neue Lauf ist
            # gewollt und darf nicht mitbeendet werden (sonst wuerde ein
            # verspaeteter Abbruch die Wiederaufnahme zerstoeren).
            self._log(f"Task {task_id} → Abbruch ignoriert (gehoert zu Versuch "
                      f"{attempt}, es laeuft {running_attempt})")
        elif process is not None:
            self._log(f"Task {task_id} → Abbruch angefordert")
            try:
                process.kill()
            except ProcessLookupError:
                pass
        else:
            self.cancelled.add(task_id)
        await self._send(websocket, {"t": "cancel_ack", "task_id": task_id})

    # ----------------------------------------------------------------- Helfer
    def _prune_task_memory(self) -> None:
        """Begrenzt Dedup-/Replay-Speicher (LRU-artig, aelteste zuerst).

        Ohne Grenze waere das ein DoS-Vektor: ein Controller (oder Angreifer
        mit Token) koennte mit Milliarden eindeutiger Task-IDs den RAM fuellen.
        """
        if len(self.seen) > _MAX_SEEN_TASKS:
            for task_id in sorted(self.seen)[: len(self.seen) - _MAX_SEEN_TASKS]:
                self.seen.discard(task_id)
        if len(self.results) > _MAX_RESULTS:
            for task_id in sorted(self.results)[: len(self.results) - _MAX_RESULTS]:
                self.results.pop(task_id, None)

    @staticmethod
    async def _send(websocket, payload: dict) -> bool:
        try:
            await websocket.send(json.dumps(payload))
            return True
        except Exception:  # noqa: BLE001 - geschlossene Verbindung ist normal
            return False

    @staticmethod
    def _log(text: str) -> None:
        print(f"[orchestrator-worker] {text}", flush=True)


def _last_json(text: str):
    """Letzte stdout-Zeile als JSON interpretieren (falls vorhanden)."""
    for line in reversed(text.strip().splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            return json.loads(line)
        except ValueError:
            return None
    return None


def _tail(text: str, limit: int) -> str:
    if limit <= 0 or len(text) <= limit:
        return text
    return text[-limit:]


def _cleanup_dir(work_dir: Path) -> None:
    """Temporaeres Task-Verzeichnis entfernen (Fehler duerfen nicht stoeren)."""
    try:
        shutil.rmtree(work_dir, ignore_errors=True)
    except OSError:
        pass


def _error_result(message: str, *, hint: str = "", action: str = "",
                  stage: str = "", detail: str = "") -> dict:
    """Einheitliche Fehlerantwort.

    `error_hint`/`error_action` sind fuer die GUI gedacht: der Benutzer soll
    lesen, was los ist und was er tun kann - ohne Terminal.
    """
    return {
        "ok": False,
        "value": None,
        "error": message,
        "error_hint": hint,
        "error_action": action,
        "stage": stage,
        "stdout": "",
        "stderr": detail,
    }


def _process_result(code: int, stdout: str, stderr: str, command: str,
                    max_stdout: int, max_stderr: int) -> dict:
    """Ergebnis eines Python-Laufs in die einheitliche Form bringen."""
    ok = code == 0
    error = ""
    hint = ""
    if not ok:
        error = stderr.strip() or stdout.strip() or f"Exit-Code {code}"
        hint = _python_error_hint(stderr + "\n" + stdout)
    return {
        "ok": ok,
        "value": _last_json(stdout) if ok and command != "define" else None,
        "error": error,
        "error_hint": hint,
        "error_action": "",
        "stage": "" if ok else "run",
        "stdout": _tail(stdout, max_stdout),
        "stderr": _tail(stderr, max_stderr),
    }


# Bekannte Python-Fehler -> verstaendlicher Hinweis fuer den Benutzer.
_ERROR_HINTS: tuple[tuple[str, str], ...] = (
    ("ModuleNotFoundError: No module named",
     "Ein Python-Paket fehlt. Den Namen in eine requirements.txt schreiben - der "
     "Worker installiert es beim naechsten Start der Aufgabe automatisch."),
    ("ImportError:",
     "Ein Import schlaegt fehl. Fehlt das Paket, gehoert es in die "
     "requirements.txt; bei Cython-Modulen pruefen, ob der Build erfolgreich war."),
    ("SyntaxError", "Python-Syntaxfehler im uebermittelten Code."),
    ("IndentationError", "Einrueckung im Python-Code ist fehlerhaft."),
    ("PermissionError", "Dem Worker fehlen Rechte fuer eine Datei oder einen Ordner."),
    ("FileNotFoundError", "Eine erwartete Datei liegt nicht im Projekt."),
    ("KeyError", "Ein erwarteter Schluessel fehlt in den Eingabedaten (input)."),
    ("TypeError", "Die uebergebenen Argumente passen nicht zur Funktion."),
    ("AttributeError", "Die aufgerufene Funktion/Methode existiert nicht."),
    ("MemoryError", "Der Worker-Rechner hat zu wenig Arbeitsspeicher fuer die Aufgabe."),
    ("No space left on device", "Auf dem Worker-Rechner ist die Platte voll."),
)


def _python_error_hint(text: str) -> str:
    if not text:
        return ""
    for needle, hint in _ERROR_HINTS:
        if needle in text:
            return hint
    return ""


async def _to_thread(func, *args):
    """Blockierende Arbeit in einen Thread auslagern (Python 3.8+).

    Ohne das wuerde ein Cython-Build (Sekunden bis Minuten) den WebSocket-Reader
    blockieren: keine Heartbeats, kein `cancel`.
    """
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, functools.partial(func, *args))


class _Progress:
    """Sammelt Fortschrittsmeldungen aus Threads und sendet sie asynchron.

    Der Build laeuft in einem Worker-Thread; gesendet werden darf nur im
    Event-Loop. Darum puffert `emit()` und ein kleiner Flush-Task schickt die
    Nachrichten (`{"t":"progress"}`) regelmaessig an den Controller.
    """

    FLUSH_INTERVAL_S = 0.2

    def __init__(self, worker: "Worker", task_id: str) -> None:
        self._worker = worker
        self._task_id = task_id
        self._items: list[tuple[str, float, str]] = []
        self._lock = threading.Lock()
        self._stop = asyncio.Event()
        self._flusher: asyncio.Task | None = None
        self._last_stage = ""

    def emit(self, stage: str, fraction: float, text: str) -> None:
        """Darf aus jedem Thread aufgerufen werden."""
        with self._lock:
            self._items.append((stage, max(0.0, min(1.0, float(fraction))), str(text)))
        # Jede neue Stufe einmal ins Worker-Log: die Worker-App zeigt damit
        # sichtbar, was gerade passiert (Umgebung, Build, Start).
        if text and stage != self._last_stage:
            self._last_stage = stage
            self._worker._log(text)

    def start(self) -> None:
        self._flusher = asyncio.create_task(self._loop())

    async def _loop(self) -> None:
        while not self._stop.is_set():
            await self.flush()
            try:
                await asyncio.wait_for(self._stop.wait(), self.FLUSH_INTERVAL_S)
            except (asyncio.TimeoutError, TimeoutError):
                continue
            except asyncio.CancelledError:
                raise

    async def flush(self) -> None:
        with self._lock:
            items, self._items = self._items, []
        for stage, fraction, text in items:
            await self._worker._send_to_owner(self._task_id, {
                "t": "progress",
                "task_id": self._task_id,
                "stage": stage,
                "fraction": round(fraction, 3),
                "text": text,
            })

    async def stop(self) -> None:
        self._stop.set()
        if self._flusher is not None:
            try:
                await asyncio.wait_for(self._flusher, 1.0)
            except (asyncio.TimeoutError, TimeoutError, asyncio.CancelledError):
                self._flusher.cancel()
        else:
            await self.flush()


def _load_token(args: argparse.Namespace) -> str:
    """Token aus --token oder --token-file; beides fehlt => harter Fehler."""
    token = ""
    if args.token:
        token = args.token.strip()
    elif args.token_file:
        try:
            token = Path(args.token_file).expanduser().read_text(encoding="utf-8").strip()
        except OSError as exc:
            print(f"[orchestrator-worker] FEHLER: Token-Datei nicht lesbar: {exc}",
                  file=sys.stderr)
            raise SystemExit(2) from None
    if not _SAFE_TOKEN_RE.match(token):
        print(
            "[orchestrator-worker] FEHLER: kein gueltiges Token gesetzt.\n"
            "  Aus Sicherheitsgruenden startet der Worker NUR mit Token\n"
            "  (16-256 Zeichen, [A-Za-z0-9_-]). Generieren mit:\n"
            "      python3 -c \"import secrets; print(secrets.token_urlsafe(32))\"\n"
            "  und dann --token \"$TOKEN\" oder --token-file token.txt uebergeben.",
            file=sys.stderr)
        raise SystemExit(2)
    return token


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Orchestrator-Worker (WebSocket)")
    parser.add_argument("--bind", default="0.0.0.0",
                        help="Adresse, auf der gelauscht wird (0.0.0.0 = LAN)")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--name", default=socket.gethostname())
    parser.add_argument("--token", default="",
                        help="Zugangs-Token (PFLICHT, shared secret mit dem Controller)")
    parser.add_argument("--token-file", default="",
                        help="Datei mit dem Token (Alternative zu --token)")
    parser.add_argument("--scripts-dir", default="",
                        help="Verzeichnis mit optionalen <script>.py-Dateien (Cache; "
                             "nicht noetig, wenn der Manager den Code mitschickt)")
    parser.add_argument("--work-dir", default="",
                        help="Basisverzeichnis fuer temporaere Task-Laeufe "
                             "(Standard: System-Temp/python_bridge_worker)")
    parser.add_argument("--python", default="",
                        help="Python fuer die Skripte (Standard: dieselbe Interpreter)")
    parser.add_argument("--queue-capacity", type=int, default=4,
                        help="Wie viele Tasks der Orchestrator gleichzeitig einplanen darf")
    parser.add_argument("--heartbeat-ms", type=int, default=2000)
    parser.add_argument("--task-timeout-ms", type=int, default=300000)
    parser.add_argument("--auth-timeout-ms", type=int, default=10000,
                        help="Zeitfenster fuer den Auth-Handshake pro Verbindung")
    parser.add_argument("--max-file-mb", type=int, default=512,
                        help="Groesste Eingabedatei, die dieser Worker annimmt (MB)")
    parser.add_argument("--max-cache-mb", type=int, default=4096,
                        help="Obergrenze des Datei-Caches auf diesem Rechner (MB)")
    parser.add_argument("--max-stdout-bytes", type=int, default=65536)
    parser.add_argument("--max-stderr-bytes", type=int, default=65536)
    parser.add_argument("--discover", dest="discover", action="store_true", default=True,
                        help="Per UDP-Broadcast im LAN sichtbar sein (Standard: an)")
    parser.add_argument("--no-discover", dest="discover", action="store_false",
                        help="Discovery abschalten (nur direkte WebSocket-Verbindung)")
    parser.add_argument("--discover-port", type=int, default=_DEFAULT_DISCOVERY_PORT,
                        help="UDP-Port fuer den Discovery-Broadcast")
    parser.add_argument("--discover-interval-ms", type=int, default=2000,
                        help="Intervall des Discovery-Broadcasts")
    parser.add_argument("--auto-pair", action="store_true",
                        help="Token im Discovery-Beacon mitsenden (Bequemlichkeit im "
                             "vertrauten LAN - weniger sicher)")
    parser.add_argument("--cache-dir", default="",
                        help="Ablage fuer Umgebungen und Builds (Standard: "
                             "Benutzer-Cache des Systems)")
    parser.add_argument("--build-timeout-ms", type=int, default=600000,
                        help="Zeitlimit fuer einen Cython/nativen Build")
    parser.add_argument("--no-auto-install", action="store_true",
                        help="Keine pip-Installationen automatisch ausfuehren")
    parser.add_argument("--no-build", action="store_true",
                        help="Build-Schritte ablehnen (nur reine Python-Projekte)")
    parser.add_argument("--tls-self-signed", dest="tls_self_signed", action="store_true",
                        help="Verschluesselt laufen (wss://) mit einem automatisch "
                             "erzeugten, selbstsignierten Zertifikat - keine Dateien, "
                             "kein openssl noetig")
    parser.add_argument("--tls-cert", default="",
                        help="PEM-Zertifikat (mit --tls-key) fuer eine verschluesselte "
                             "Verbindung")
    parser.add_argument("--tls-key", default="",
                        help="PEM-Privatschluessel zum Zertifikat aus --tls-cert")
    parser.add_argument("--tls-fingerprint", action="store_true",
                        help="Nur den SHA-256-Fingerabdruck des TLS-Zertifikats "
                             "ausgeben und beenden")
    parser.add_argument("--diagnose", action="store_true",
                        help="Umgebung pruefen (Python, pip, venv, Compiler, Cache, TLS) "
                             "und als JSON ausgeben, dann beenden")
    args = parser.parse_args(argv)
    if getattr(args, "diagnose", False) or getattr(args, "tls_fingerprint", False):
        # Reiner Bericht: es wird keine Verbindung aufgebaut, also darf auch
        # noch kein Token gesetzt sein (die App ruft das vor dem Start auf).
        args.token = ""
    else:
        args.token = _load_token(args)
    return args


async def amain(args: argparse.Namespace) -> None:
    worker = Worker(args)
    if not worker.scripts_dir.is_dir():
        # Kein Fehler mehr: das Verzeichnis ist nur ein optionaler Skript-Cache.
        try:
            worker.scripts_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            print(f"[orchestrator-worker] FEHLER: scripts-dir nicht anlegbar: {exc}",
                  file=sys.stderr)
            raise SystemExit(2) from None
    try:
        worker.work_root.mkdir(parents=True, exist_ok=True)
        worker.cache_root.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        print(f"[orchestrator-worker] FEHLER: Arbeits-/Cache-Verzeichnis nicht "
              f"anlegbar: {exc}", file=sys.stderr)
        raise SystemExit(2) from None
    # Datei-Cache begrenzen (aelteste zuerst). Danach meldet sich der Worker
    # beim Manager neu und der weiss wieder, was tatsaechlich da ist.
    try:
        pruned = worker.store.prune()
        if pruned.get("removed"):
            print(f"[orchestrator-worker] Datei-Cache aufgeraeumt: "
                  f"{pruned['removed']} Datei(en)", flush=True)
    except OSError:
        pass
    # Cache aufraeumen: Builds und Umgebungen duerfen nicht unbegrenzt wachsen.
    try:
        cleaned = worker.builder().clean()
        if cleaned.get("projects_removed") or cleaned.get("envs_removed"):
            print(f"[orchestrator-worker] Cache aufgeraeumt: "
                  f"{cleaned['projects_removed']} Projekt(e), "
                  f"{cleaned['envs_removed']} Umgebung(en)", flush=True)
    except OSError:
        pass
    if not Path(worker.python).exists() and os.sep in worker.python:
        print(f"[orchestrator-worker] FEHLER: Python nicht gefunden: {worker.python}",
              file=sys.stderr)
        raise SystemExit(2)
    # TLS: entweder eigenes Zertifikat oder automatisch erzeugtes. Scheitert es,
    # wird abgebrochen statt still unverschluesselt weiterzulaufen.
    tls = build_tls_context(args)
    if tls["error"]:
        print(f"[orchestrator-worker] FEHLER: TLS nicht einsatzbereit: {tls['error']}\n"
              "  Ohne TLS starten: ohne --tls-cert/--tls-key/--tls-self-signed.",
              file=sys.stderr)
        raise SystemExit(2)
    scheme = "wss" if tls["ctx"] is not None else "ws"
    beacon_task = None
    if args.discover:
        beacon = DiscoveryBeacon(
            name=args.name,
            port=args.port,
            capacity=args.queue_capacity,
            token=args.token,
            auto_pair=args.auto_pair,
            discover_port=args.discover_port,
            interval_ms=args.discover_interval_ms,
            tls=tls["ctx"] is not None,
            fingerprint=tls["fingerprint"],
        )
        beacon_task = asyncio.create_task(beacon.run())
    async with serve(worker.handler, args.bind, args.port,
                     ssl=tls["ctx"],
                     max_size=_MAX_FRAME_BYTES,
                     ping_interval=20, ping_timeout=20) as _server:
        env = worker.env_info
        print(f"[orchestrator-worker] '{args.name}' lauscht auf "
              f"{scheme}://{args.bind}:{args.port}", flush=True)
        if tls["ctx"] is not None:
            source = ("eigenes Zertifikat" if tls["mode"] == "file"
                      else "automatisch erzeugtes Zertifikat")
            print(f"[orchestrator-worker] TLS aktiv ({source}, TLS >= 1.2): "
                  f"{tls['cert']}", flush=True)
            print(f"[orchestrator-worker] Zertifikat-SHA-256: "
                  f"{format_fingerprint(tls['fingerprint'])}", flush=True)
        print(f"[orchestrator-worker] Python {env.python_version} ({env.implementation}), "
              f"Compiler: {env.compiler or 'keiner'}, "
              f"pip: {'ja' if env.pip_available else 'nein'}, "
              f"Builds: {'ja' if worker.allow_build else 'nein'}", flush=True)
        print(f"[orchestrator-worker] Cache: {worker.cache_root}", flush=True)
        print(f"[orchestrator-worker] Datei-Cache: {worker.store.root} "
              f"(Grenzen: {args.max_file_mb} MB/Datei, {args.max_cache_mb} MB gesamt)",
              flush=True)
        await asyncio.Future()  # laeuft bis zum Abbruch
    if beacon_task is not None:
        beacon_task.cancel()


def _diagnose(args: argparse.Namespace) -> dict:
    """Bericht fuer die Worker-App: was fehlt, was automatisch passiert."""
    python = args.python or sys.executable
    cache = Path(args.cache_dir).expanduser().resolve() if args.cache_dir else None
    env = detect_env(python, cache)
    builder = ProjectBuilder(env, python)
    report = builder.diagnose(build_required=not args.no_build)
    report["python_path"] = python
    report["worker_name"] = args.name
    report["build_allowed"] = not args.no_build
    report["file_cache"] = _file_cache_report(args)
    # Zertifikat wird bei Bedarf hier erzeugt - die Statuszeilen gehen nach
    # stderr, damit stdout reines JSON bleibt.
    tls = build_tls_context(args, log=lambda m: _tls_log(m, sys.stderr))
    report["tls"] = {
        "mode": tls["mode"],
        "ready": tls["ctx"] is not None,
        "cert": tls["cert"],
        "error": tls["error"],
        "fingerprint": format_fingerprint(tls["fingerprint"]) if tls["fingerprint"] else "",
    }
    return report


def _file_cache_report(args: argparse.Namespace) -> dict:
    """Wieviel Platz belegen empfangene Eingabedateien, und welche Grenzen gelten?"""
    work_root = Path(args.work_dir).expanduser().resolve() if args.work_dir \
        else Path(tempfile.gettempdir()) / "python_bridge_worker"
    try:
        store = FileStore(work_root / "filedata",
                          max_file_bytes=max(int(args.max_file_mb), 1) * 1024 * 1024,
                          max_total_bytes=max(int(args.max_cache_mb), 1) * 1024 * 1024)
        usage = store.usage()
    except OSError as exc:
        return {"error": str(exc)}
    return {
        "root": str(store.root),
        "files": usage["files"],
        "bytes": usage["bytes"],
        "max_file_mb": int(args.max_file_mb),
        "max_cache_mb": int(args.max_cache_mb),
    }


def main(argv=None) -> None:
    args = parse_args(argv)
    if getattr(args, "tls_fingerprint", False):
        # Nur den Fingerabdruck zeigen: damit laesst sich der Manager einrichten,
        # ohne die Zertifikatsdatei von Hand zu oeffnen.
        tls = build_tls_context(args, log=lambda m: _tls_log(m, sys.stderr))
        if tls["error"]:
            print(f"[orchestrator-worker] FEHLER: {tls['error']}", file=sys.stderr)
            raise SystemExit(2)
        if tls["mode"] == "off":
            print("TLS ist aus (kein --tls-cert/--tls-key/--tls-self-signed).")
            return
        print(f"Zertifikat : {tls['cert']}\n"
              f"SHA-256    : {format_fingerprint(tls['fingerprint'])}\n"
              f"Rohteil    : {tls['fingerprint']}")
        return
    if getattr(args, "diagnose", False):
        print(json.dumps(_diagnose(args), ensure_ascii=False, indent=2))
        return
    try:
        asyncio.run(amain(args))
    except KeyboardInterrupt:
        print("\n[orchestrator-worker] beendet.", flush=True)


if __name__ == "__main__":
    main()
