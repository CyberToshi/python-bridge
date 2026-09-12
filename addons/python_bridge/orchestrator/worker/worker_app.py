#!/usr/bin/env python3
"""Worker-Anwendung fuer den Python-Bridge Task-Orchestrator (V1).

Diese App ist fuer die **Client-Rechner** gedacht und macht den Worker
"doppelklickfaehig":

  * dunkle, aufgeraeumte Oberflaeche (kein Terminal noetig),
  * Token wird beim ersten Start automatisch erzeugt und gespeichert,
  * Worker starten/stoppen mit einem Klick,
  * Live-Log des Worker-Prozesses,
  * LAN-Discovery ist standardmaessig aktiv -> der Manager findet den Rechner
    automatisch, ohne dass jemand eine IP eintippen muss.

Start:

    Windows:  Worker-Windows.bat   (oder: pythonw worker_app.py)
    Linux:    ./start_worker_linux.sh

Optional headless (ohne GUI) laeuft weiterhin direkt `orchestrator_worker.py`.

Abhaengigkeit: `websockets` (pip install websockets). Die App bietet den
Installationsknopf an, falls das Paket fehlt.
"""

from __future__ import annotations

import json
import os
import queue
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox

APP_DIR = Path(__file__).resolve().parent
WORKER_SCRIPT = APP_DIR / "orchestrator_worker.py"
CONFIG_PATH = APP_DIR / "worker_config.json"
IS_WINDOWS = os.name == "nt"

# --------------------------------------------------------------- Farbpalette
BG = "#14161c"
PANEL = "#1c1f28"
PANEL_HI = "#232735"
BORDER = "#2e3444"
TEXT = "#e8ecf5"
MUTED = "#98a2b8"
ACCENT = "#4c8dff"
ACCENT_DARK = "#3b73d1"
GOOD = "#39d98a"
WARN = "#f5c451"
BAD = "#ff6b6b"
LOG_BG = "#101218"

FONT = ("Segoe UI", 10) if IS_WINDOWS else ("DejaVu Sans", 10)
FONT_BOLD = (FONT[0], 11, "bold")
FONT_SMALL = (FONT[0], 9)
FONT_MONO = ("Consolas", 9) if IS_WINDOWS else ("DejaVu Sans Mono", 9)

DEFAULT_DISCOVERY_PORT = 8766
# Verschlüsselte Verbindung (wss://) ist der Standard: das Token und der Code
# gehen sonst im Klartext durch das Netz. Der Schalter in der App ist nur eine
# Notbremse fuer Umgebungen, in denen der Manager kein TLS kann.
DEFAULT_TLS = True
MAX_ROWS = 5            # so viele Aufgaben/Transfers sind gleichzeitig sichtbar
MAX_LOG_LINES = 800     # so viele Logzeilen bleiben im Speicher (Filter)
_ERROR_MARKERS = ("fehler", "fail", "error", "traceback", "abgelehnt", "warnung",
                  "abgebrochen", "zeitueberschreitung")


def _looks_like_error(line: str) -> bool:
    lowered = line.lower()
    return any(marker in lowered for marker in _ERROR_MARKERS)


def _human_bytes(value: int) -> str:
    size = float(max(value, 0))
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} GB"


def default_config() -> dict:
    """Standardwerte fuer einen frisch installierten Worker."""
    return {
        "name": socket.gethostname() or "worker",
        "port": 8765,
        "discover_port": DEFAULT_DISCOVERY_PORT,
        "scripts_dir": "",
        "work_dir": "",
        "queue_capacity": 4,
        "task_timeout_ms": 300000,
        "heartbeat_ms": 2000,
        "max_file_mb": 512,
        "max_cache_mb": 4096,
        "discover": True,
        "auto_pair": True,
        "tls": DEFAULT_TLS,
        "token": secrets.token_urlsafe(32),
    }


def _json_part(text: str) -> str:
    """JSON aus einer Ausgabe schneiden, der noch Text vorausgeht.

    Der Worker gibt beim Erzeugen eines Zertifikats Statuszeilen aus. Die
    gehoeren nach stderr - aber die App soll auch dann noch funktionieren,
    wenn doch einmal etwas davor steht.
    """
    start = text.find("{")
    return text[start:] if start >= 0 else "{}"


def diagnose_text(report: dict) -> str:
    """Diagnosebericht in lesbaren Klartext uebersetzen (ohne Fenster pruefbar).

    Der Bericht kommt aus `orchestrator_worker.py --diagnose`; hier wird er so
    aufbereitet, dass ein Benutzer ohne Terminal sieht, was fehlt und was das
    System selbst erledigt.
    """
    problems = report.get("problems") or []
    lines = [
        f"Python {report.get('python', '?')} ({report.get('implementation', '?')})",
        f"System {report.get('os', '?')}/{report.get('arch', '?')}",
        f"Compiler: {report.get('compiler') or 'keiner'}",
        "pip: %s    venv: %s" % ("ja" if report.get("pip") else "nein",
                                 "ja" if report.get("venv") else "nein"),
        f"Cache: {report.get('cache', '?')}",
    ]
    cache = report.get("file_cache") or {}
    if cache and not cache.get("error"):
        lines.append(f"Datei-Cache: {cache.get('files', 0)} Datei(en), "
                     f"{_human_bytes(int(cache.get('bytes', 0)))}")
        lines.append(f"Grenzen: {cache.get('max_file_mb', '?')} MB/Datei, "
                     f"{cache.get('max_cache_mb', '?')} MB gesamt")
    tls = report.get("tls") or {}
    if tls:
        mode = str(tls.get("mode", "off"))
        if mode == "off":
            lines.append("Verbindung: ohne Verschluesselung (ws://)")
        elif tls.get("ready"):
            quelle = ("eigenes Zertifikat" if mode == "file"
                      else "automatisch erzeugtes Zertifikat")
            lines.append(f"Verbindung: verschluesselt (wss://), {quelle}, TLS >= 1.2")
            if tls.get("fingerprint"):
                lines.append(f"Zertifikat-SHA-256: {tls['fingerprint']}")
        else:
            lines.append(f"Verbindung: TLS NICHT bereit - {tls.get('error', '?')}")
    if not problems:
        lines.append("")
        lines.append("Alles bereit - reine Python-Projekte und Cython-Builds "
                     "koennen ausgefuehrt werden.")
    else:
        lines.append("")
        lines.append("Es fehlt:")
        for problem in problems:
            lines.append(f"  - {problem.get('text', '?')}")
            if problem.get("hint"):
                lines.append(f"    {problem['hint']}")
    return "\n".join(lines)


def worker_args(cfg: dict, python: str | None = None) -> list[str]:
    """Kommandozeile des Workers aus der Konfiguration bauen.

    Bewusst als eigene Funktion: so laesst sich pruefen, was die App wirklich
    startet (inklusive TLS-Schalter), ohne ein Fenster zu oeffnen.
    """
    args = [
        python or sys.executable, str(WORKER_SCRIPT),
        "--bind", "0.0.0.0",
        "--port", str(int(cfg.get("port", 8765))),
        "--name", str(cfg.get("name", "worker")),
        "--token", str(cfg.get("token", "")),
        "--queue-capacity", str(int(cfg.get("queue_capacity", 4))),
        "--task-timeout-ms", str(int(cfg.get("task_timeout_ms", 300000))),
        "--heartbeat-ms", str(int(cfg.get("heartbeat_ms", 2000))),
        "--max-file-mb", str(int(cfg.get("max_file_mb", 512))),
        "--max-cache-mb", str(int(cfg.get("max_cache_mb", 4096))),
        "--discover-port", str(int(cfg.get("discover_port", DEFAULT_DISCOVERY_PORT))),
    ]
    args += ["--discover"] if cfg.get("discover", True) else ["--no-discover"]
    args += ["--auto-pair"] if cfg.get("auto_pair", True) else []
    # TLS: Zertifikat wird bei Bedarf automatisch erzeugt und wiederverwendet.
    if cfg.get("tls", DEFAULT_TLS):
        args += ["--tls-self-signed"]
    if cfg.get("scripts_dir"):
        args += ["--scripts-dir", str(cfg["scripts_dir"])]
    if cfg.get("work_dir"):
        args += ["--work-dir", str(cfg["work_dir"])]
    if cfg.get("cache_dir"):
        args += ["--cache-dir", str(cfg["cache_dir"])]
    return args


def load_config() -> dict:
    cfg = default_config()
    try:
        stored = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        if isinstance(stored, dict):
            for key, value in stored.items():
                if key in cfg and value is not None:
                    cfg[key] = value
    except (OSError, ValueError):
        pass
    if not str(cfg.get("token", "")):
        cfg["token"] = secrets.token_urlsafe(32)
    return cfg


def save_config(cfg: dict) -> None:
    try:
        CONFIG_PATH.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    except OSError:
        pass


def local_ip() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 1))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def machine_cpu_pct() -> float:
    """Grobe CPU-Auslastung ohne Zusatzpakete."""
    try:
        load = os.getloadavg()[0]
    except (OSError, AttributeError):
        return 0.0
    return max(0.0, min(100.0, load / (os.cpu_count() or 1) * 100.0))


def machine_ram_pct() -> float:
    """RAM-Auslastung unter Linux ueber /proc; sonst 0."""
    try:
        info: dict = {}
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


# Muster der Worker-Ausgaben, aus denen die Oberflaeche ihre Balken zeichnet.
# Bewusst hier (nicht in der Klasse): so ist die Auswertung ohne Bildschirm
# pruefbar (siehe tests/orchestrator/test_worker_ui.py).
_TASK_START_RE = re.compile(r"Task (\S+) \S+ (.*?) l(?:ae|\u00e4)uft")
_TASK_FILES_RE = re.compile(r"Task (\S+) \S+ (\d+) Eingabedatei")
_TASK_DONE_RE = re.compile(r"Task (\S+) \S+ (OK|FEHLER)")
_TRANSFER_START_RE = re.compile(r"Datei-Empfang gestartet: (\S+)")
_TRANSFER_PERCENT_RE = re.compile(r"Datei (\S+): (\d+) %")
_STATUS_RE = re.compile(r"STATUS aktiv=(\d+) dateien=(\d+) empfangen=(\d+)")


def read_status_line(line: str) -> dict | None:
    """Wertet eine Worker-Logzeile aus. None = fuer die Anzeige uninteressant."""
    match = _TASK_START_RE.search(line)
    if match:
        return {"kind": "task_start", "task_id": match.group(1),
                "label": match.group(2).strip()}
    match = _TASK_FILES_RE.search(line)
    if match:
        return {"kind": "task_files", "task_id": match.group(1),
                "count": int(match.group(2))}
    match = _TASK_DONE_RE.search(line)
    if match:
        return {"kind": "task_done", "task_id": match.group(1),
                "ok": match.group(2) == "OK"}
    match = _TRANSFER_START_RE.search(line)
    if match:
        return {"kind": "transfer_start", "name": match.group(1)}
    match = _TRANSFER_PERCENT_RE.search(line)
    if match:
        return {"kind": "transfer_progress", "name": match.group(1),
                "fraction": int(match.group(2)) / 100.0}
    match = _STATUS_RE.search(line)
    if match:
        return {"kind": "status", "active": int(match.group(1)),
                "files": int(match.group(2)), "bytes": int(match.group(3))}
    return None


def has_websockets() -> bool:
    try:
        import websockets  # noqa: F401
        return True
    except ImportError:
        return False


# ------------------------------------------------------------------ Widgets
class RoundedButton(tk.Canvas):
    """Button mit abgerundeten Ecken (tkinter kann das nicht von sich aus)."""

    def __init__(self, parent, text: str, command, *, width: int = 150, height: int = 36,
                 fill: str = ACCENT, hover: str = ACCENT_DARK, text_color: str = "#ffffff",
                 radius: int = 10, font=None) -> None:
        super().__init__(parent, width=width, height=height, bg=BG,
                         highlightthickness=0, bd=0)
        self._command = command
        self._fill = fill
        self._hover = hover
        self._radius = radius
        self._enabled = True
        self._shape = self._round_rect(1, 1, width - 1, height - 1, radius, fill=fill)
        self._label = self.create_text(width / 2, height / 2, text=text,
                                       fill=text_color, font=font or FONT_BOLD)
        self.bind("<Enter>", self._on_enter)
        self.bind("<Leave>", self._on_leave)
        self.bind("<Button-1>", self._on_click)

    def _round_rect(self, x1, y1, x2, y2, r, **kwargs):
        points = [
            x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r, x2, y2 - r, x2, y2,
            x2 - r, y2, x1 + r, y2, x1, y2, x1, y2 - r, x1, y1 + r, x1, y1,
        ]
        return self.create_polygon(points, smooth=True, splinesteps=24, **kwargs)

    def configure_state(self, enabled: bool, fill: str | None = None) -> None:
        self._enabled = enabled
        self.itemconfigure(self._shape, fill=fill or self._fill)
        self.itemconfigure(self._label, fill=TEXT if enabled else MUTED)

    def set_text(self, text: str) -> None:
        self.itemconfigure(self._label, text=text)

    def _on_enter(self, _event) -> None:
        if self._enabled:
            self.itemconfigure(self._shape, fill=self._hover)

    def _on_leave(self, _event) -> None:
        if self._enabled:
            self.itemconfigure(self._shape, fill=self._fill)

    def _on_click(self, _event) -> None:
        if self._enabled and self._command is not None:
            self._command()


class Card(tk.Frame):
    """Einfache, abgerundet wirkende Karte (Panel mit Rand)."""

    def __init__(self, parent, **kwargs) -> None:
        super().__init__(parent, bg=PANEL, highlightbackground=BORDER,
                         highlightthickness=1, bd=0, **kwargs)


class TaskRow(tk.Frame):
    """Eine Zeile in der Aufgabenliste: Name, Status und ein Fortschrittsbalken.

    Der Balken ist selbst gezeichnet (tkinter bringt keinen dunklen, abgerundeten
    Fortschrittsbalken mit). 0.0..1.0 als Anteil, -1 zeigt einen unbestimmten
    Zustand ("laeuft, Dauer unbekannt").
    """

    BAR_HEIGHT = 8

    def __init__(self, parent, title: str, *, bar_width: int = 380) -> None:
        super().__init__(parent, bg=PANEL)
        self.bar_width = bar_width
        header = tk.Frame(self, bg=PANEL)
        header.pack(fill="x")
        self.title = tk.Label(header, text=title, bg=PANEL, fg=TEXT, font=FONT_SMALL,
                              anchor="w")
        self.title.pack(side="left")
        self.state_label = tk.Label(header, text="", bg=PANEL, fg=MUTED,
                                    font=FONT_SMALL, anchor="e")
        self.state_label.pack(side="right")
        self.bar = tk.Canvas(self, width=bar_width, height=self.BAR_HEIGHT, bg=PANEL,
                             highlightthickness=0, bd=0)
        self.bar.pack(fill="x", pady=(4, 10))
        self._fraction = -1.0
        self._color = ACCENT
        self.bar.bind("<Configure>", self._redraw)

    def set_state(self, text: str, color: str = MUTED, fraction: float = -1.0) -> None:
        self.state_label.configure(text=text, fg=color)
        self._fraction = fraction
        self._color = color
        self._redraw()

    def _redraw(self, _event=None) -> None:
        self.bar.delete("all")
        width = max(self.bar.winfo_width(), 40)
        height = self.BAR_HEIGHT
        radius = height / 2
        self._rounded(1, 1, width - 1, height - 1, radius, BORDER)
        if self._fraction < 0:
            # Unbestimmt: ein Stueck in der Mitte (kein "haengender" Eindruck).
            segment = width * 0.28
            start = width * 0.36
            self._rounded(start, 1, start + segment, height - 1, radius, self._color)
            return
        filled = max(width * max(0.0, min(1.0, self._fraction)) - 2, 0.0)
        if filled <= 0:
            return
        self._rounded(1, 1, 1 + filled, height - 1, radius, self._color)

    def _rounded(self, x1, y1, x2, y2, r, color) -> None:
        if x2 - x1 <= 2 * r:
            r = max((x2 - x1) / 2, 0)
        points = [
            x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r, x2, y2 - r, x2, y2,
            x2 - r, y2, x1 + r, y2, x1, y2, x1, y2 - r, x1, y1 + r, x1, y1,
        ]
        self.bar.create_polygon(points, smooth=True, splinesteps=18, fill=color,
                                outline="")


class Field(tk.Frame):
    """Label + Eingabefeld in einer Zeile."""

    def __init__(self, parent, label: str, value: str, width: int = 26) -> None:
        super().__init__(parent, bg=PANEL)
        tk.Label(self, text=label, bg=PANEL, fg=MUTED, font=FONT_SMALL,
                 anchor="w").pack(fill="x")
        self.var = tk.StringVar(value=value)
        self.entry = tk.Entry(self, textvariable=self.var, width=width, font=FONT,
                              bg=LOG_BG, fg=TEXT, insertbackground=TEXT,
                              relief="flat", highlightthickness=1,
                              highlightbackground=BORDER, highlightcolor=ACCENT)
        self.entry.pack(fill="x", ipady=5, pady=(3, 10))


# -------------------------------------------------------------------- App
class WorkerApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.cfg = load_config()
        self.proc: subprocess.Popen | None = None
        self.log_queue: "queue.Queue[str]" = queue.Queue()
        self._reader: threading.Thread | None = None
        self._manager_connected = False

        root.title("Python Bridge - Worker")
        root.configure(bg=BG)
        root.geometry("760x640")
        root.minsize(700, 560)

        self._build()
        self._refresh_status()
        self.root.after(200, self._drain_log)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    # ------------------------------------------------------------ Aufbau
    def _build(self) -> None:
        header = tk.Frame(self.root, bg=BG)
        header.pack(fill="x", padx=20, pady=(18, 6))
        tk.Label(header, text="Worker", bg=BG, fg=TEXT,
                 font=(FONT[0], 20, "bold")).pack(side="left")
        tk.Label(header, text="  Python Bridge - Task-Orchestrator", bg=BG, fg=MUTED,
                 font=FONT).pack(side="left", pady=(8, 0))

        status_card = Card(self.root)
        status_card.pack(fill="x", padx=20, pady=(6, 12))
        inner = tk.Frame(status_card, bg=PANEL)
        inner.pack(fill="x", padx=16, pady=14)

        self.dot = tk.Canvas(inner, width=16, height=16, bg=PANEL, highlightthickness=0)
        self.dot.pack(side="left", pady=(2, 0))
        self.dot_id = self.dot.create_oval(2, 2, 14, 14, fill=MUTED, outline="")

        self.status_label = tk.Label(inner, text="Gestoppt", bg=PANEL, fg=TEXT,
                                     font=FONT_BOLD)
        self.status_label.pack(side="left", padx=(10, 0))

        self.metrics_label = tk.Label(inner, text="", bg=PANEL, fg=MUTED, font=FONT_SMALL)
        self.metrics_label.pack(side="right", padx=(0, 14))
        self.info_label = tk.Label(inner, text="", bg=PANEL, fg=MUTED, font=FONT_SMALL)
        self.info_label.pack(side="right")

        body = tk.Frame(self.root, bg=BG)
        body.pack(fill="both", expand=True, padx=20, pady=(0, 8))

        left = Card(body)
        left.pack(side="left", fill="both", expand=True, padx=(0, 8))
        left_inner = tk.Frame(left, bg=PANEL)
        left_inner.pack(fill="both", expand=True, padx=16, pady=14)

        tk.Label(left_inner, text="Einstellungen", bg=PANEL, fg=TEXT,
                 font=FONT_BOLD).pack(anchor="w", pady=(0, 10))

        self.f_name = Field(left_inner, "Name dieses Rechners", str(self.cfg["name"]))
        self.f_name.pack(fill="x")
        self.f_port = Field(left_inner, "Port (muss frei sein)", str(self.cfg["port"]))
        self.f_port.pack(fill="x")
        self.f_scripts = Field(left_inner, "Skript-Ordner (optional, Cache)",
                               str(self.cfg.get("scripts_dir", "")))
        self.f_scripts.pack(fill="x")
        row = tk.Frame(left_inner, bg=PANEL)
        row.pack(fill="x")
        RoundedButton(row, "Ordner waehlen", self._pick_scripts, width=140, height=30,
                      fill=PANEL_HI, hover=BORDER, text_color=TEXT,
                      font=FONT_SMALL).pack(side="left", pady=(0, 10))

        self.f_capacity = Field(left_inner, "Gleichzeitige Aufgaben", str(self.cfg["queue_capacity"]))
        self.f_capacity.pack(fill="x")

        self.f_file_mb = Field(left_inner, "Groesste Eingabedatei (MB)",
                               str(self.cfg.get("max_file_mb", 512)))
        self.f_file_mb.pack(fill="x")
        self.f_cache_mb = Field(left_inner, "Datei-Cache gesamt (MB)",
                                str(self.cfg.get("max_cache_mb", 4096)))
        self.f_cache_mb.pack(fill="x")

        self.var_discover = tk.BooleanVar(value=bool(self.cfg.get("discover", True)))
        self.var_pair = tk.BooleanVar(value=bool(self.cfg.get("auto_pair", True)))
        self.var_tls = tk.BooleanVar(value=bool(self.cfg.get("tls", DEFAULT_TLS)))
        self._check(left_inner, "Automatisch im Netz sichtbar (Discovery)",
                    self.var_discover)
        self._check(left_inner, "Automatische Kopplung erlauben (bequem, weniger sicher)",
                    self.var_pair)
        self._check(left_inner, "Verschluesselt (TLS) - Zertifikat wird automatisch erzeugt",
                    self.var_tls)
        self.tls_label = tk.Label(left_inner, text="", bg=PANEL, fg=MUTED,
                                  font=FONT_SMALL, wraplength=260, justify="left")
        self.tls_label.pack(anchor="w", pady=(0, 6))
        tls_row = tk.Frame(left_inner, bg=PANEL)
        tls_row.pack(fill="x")
        RoundedButton(tls_row, "Fingerabdruck anzeigen", self._show_fingerprint,
                      width=210, height=30, fill=PANEL_HI, hover=BORDER,
                      text_color=TEXT, font=FONT_SMALL).pack(side="left", pady=(0, 6))
        self._update_tls_hint()
        self.var_tls.trace_add("write", lambda *_: self._update_tls_hint())

        right = Card(body)
        right.pack(side="left", fill="both", expand=True, padx=(8, 0))
        right_inner = tk.Frame(right, bg=PANEL)
        right_inner.pack(fill="both", expand=True, padx=16, pady=14)

        tk.Label(right_inner, text="Zugang", bg=PANEL, fg=TEXT,
                 font=FONT_BOLD).pack(anchor="w", pady=(0, 10))
        tk.Label(right_inner, text="Token (shared secret mit dem Manager)",
                 bg=PANEL, fg=MUTED, font=FONT_SMALL).pack(anchor="w")
        self.token_var = tk.StringVar(value=str(self.cfg["token"]))
        token_entry = tk.Entry(right_inner, textvariable=self.token_var, font=FONT_MONO,
                               bg=LOG_BG, fg=TEXT, insertbackground=TEXT,
                               relief="flat", highlightthickness=1,
                               highlightbackground=BORDER)
        token_entry.pack(fill="x", ipady=5, pady=(3, 8))
        btns = tk.Frame(right_inner, bg=PANEL)
        btns.pack(fill="x")
        RoundedButton(btns, "Kopieren", self._copy_token, width=110, height=30,
                      fill=PANEL_HI, hover=BORDER, text_color=TEXT,
                      font=FONT_SMALL).pack(side="left")
        RoundedButton(btns, "Neu erzeugen", self._new_token, width=120, height=30,
                      fill=PANEL_HI, hover=BORDER, text_color=TEXT,
                      font=FONT_SMALL).pack(side="left", padx=8)

        self.dep_label = tk.Label(right_inner, text="", bg=PANEL, fg=WARN,
                                  font=FONT_SMALL, wraplength=250, justify="left")
        self.dep_label.pack(anchor="w", pady=(14, 6))
        self.fix_button = RoundedButton(right_inner, "websockets installieren",
                                        self._install_deps, width=200, height=32,
                                        fill=WARN, hover="#d9a93c", text_color="#241d05",
                                        font=FONT_SMALL)

        # "Umgebung pruefen": zeigt in Klartext, was fuer Builds/Cython fehlt -
        # ohne Terminal. Genau hier bekommt der Benutzer eine Loesung angeboten.
        self.diag_button = RoundedButton(right_inner, "Umgebung pruefen",
                                         self._run_diagnose, width=200, height=32,
                                         fill=PANEL_HI, hover=BORDER, text_color=TEXT,
                                         font=FONT_SMALL)
        self.diag_button.pack(anchor="w", pady=(10, 6))
        self.diag_label = tk.Label(right_inner, text="", bg=PANEL, fg=MUTED,
                                   font=FONT_SMALL, wraplength=250, justify="left")
        self.diag_label.pack(anchor="w")

        self.hint = tk.Label(right_inner, text="", bg=PANEL, fg=MUTED, font=FONT_SMALL,
                             wraplength=250, justify="left")
        self.hint.pack(anchor="w", pady=(14, 0))

        # Aufgabenliste mit Fortschrittsbalken (pro Aufgabe und pro Datei).
        tasks_card = Card(self.root)
        tasks_card.pack(fill="x", padx=20, pady=(0, 8))
        tasks_head = tk.Frame(tasks_card, bg=PANEL)
        tasks_head.pack(fill="x", padx=16, pady=(10, 2))
        tk.Label(tasks_head, text="Aufgaben", bg=PANEL, fg=TEXT,
                 font=FONT_BOLD).pack(side="left")
        self.tasks_summary = tk.Label(tasks_head, text="keine", bg=PANEL, fg=MUTED,
                                      font=FONT_SMALL)
        self.tasks_summary.pack(side="right")
        self.tasks_box = tk.Frame(tasks_card, bg=PANEL)
        self.tasks_box.pack(fill="x", padx=16, pady=(4, 12))
        self.task_rows: dict[str, TaskRow] = {}
        self.transfer_rows: dict[str, TaskRow] = {}
        self.task_order: list[str] = []
        self.transfer_order: list[str] = []
        self.task_metrics = {"aktiv": 0, "dateien": 0, "empfangen": 0}

        # Steuerleiste
        controls = tk.Frame(self.root, bg=BG)
        controls.pack(fill="x", padx=20, pady=(4, 8))
        self.btn_start = RoundedButton(controls, "Worker starten", self.start_worker,
                                       width=190, height=42)
        self.btn_start.pack(side="left")
        self.btn_stop = RoundedButton(controls, "Beenden", self.stop_worker, width=120,
                                      height=42, fill=PANEL_HI, hover=BORDER,
                                      text_color=TEXT)
        self.btn_stop.pack(side="left", padx=10)
        self.btn_stop.configure_state(False)
        tk.Label(controls, text="Fenster offen lassen - der Worker laeuft im Hintergrund.",
                 bg=BG, fg=MUTED, font=FONT_SMALL).pack(side="right")

        # Log mit Filter
        log_card = Card(self.root)
        log_card.pack(fill="both", expand=True, padx=20, pady=(0, 18))
        log_head = tk.Frame(log_card, bg=PANEL)
        log_head.pack(fill="x", padx=16, pady=(10, 4))
        tk.Label(log_head, text="Log", bg=PANEL, fg=TEXT, font=FONT_BOLD).pack(side="left")
        tk.Label(log_head, text="Filter", bg=PANEL, fg=MUTED,
                 font=FONT_SMALL).pack(side="left", padx=(14, 6))
        self.filter_var = tk.StringVar(value="")
        self.filter_entry = tk.Entry(log_head, textvariable=self.filter_var, width=22,
                                     font=FONT_SMALL, bg=LOG_BG, fg=TEXT,
                                     insertbackground=TEXT, relief="flat",
                                     highlightthickness=1, highlightbackground=BORDER,
                                     highlightcolor=ACCENT)
        self.filter_entry.pack(side="left", ipady=3)
        self.filter_var.trace_add("write", lambda *_: self._render_log())
        self.var_errors_only = tk.BooleanVar(value=False)
        err_box = tk.Checkbutton(log_head, text="nur Fehler", variable=self.var_errors_only,
                                 command=self._render_log, bg=PANEL, fg=TEXT,
                                 activebackground=PANEL, activeforeground=TEXT,
                                 selectcolor=LOG_BG, font=FONT_SMALL, bd=0,
                                 highlightthickness=0)
        err_box.pack(side="left", padx=(10, 0))
        RoundedButton(log_head, "Leeren", self._clear_log, width=90, height=26,
                      fill=PANEL_HI, hover=BORDER, text_color=TEXT,
                      font=FONT_SMALL).pack(side="right")
        self.log = tk.Text(log_card, bg=LOG_BG, fg=TEXT, font=FONT_MONO, relief="flat",
                           wrap="none", height=9, insertbackground=TEXT)
        self.log.pack(fill="both", expand=True, padx=12, pady=(0, 12))
        self.log.configure(state="disabled")
        self._log_lines: list[str] = []
        self._append_log("Bereit. Token erzeugt und gespeichert.\n")

    def _check(self, parent, text: str, var: tk.BooleanVar) -> None:
        box = tk.Checkbutton(parent, text=text, variable=var, bg=PANEL, fg=TEXT,
                             activebackground=PANEL, activeforeground=TEXT,
                             selectcolor=LOG_BG, font=FONT_SMALL, anchor="w",
                             highlightthickness=0, bd=0)
        box.pack(anchor="w", pady=(0, 4))

    # ------------------------------------------------------------ Aktionen
    def _pick_scripts(self) -> None:
        chosen = filedialog.askdirectory(title="Skript-Ordner waehlen")
        if chosen:
            self.f_scripts.var.set(chosen)

    def _copy_token(self) -> None:
        self.root.clipboard_clear()
        self.root.clipboard_append(self.token_var.get())
        self._append_log("Token in die Zwischenablage kopiert.\n")

    def _new_token(self) -> None:
        if self.proc is not None:
            messagebox.showinfo("Worker laeuft", "Bitte zuerst den Worker beenden.")
            return
        self.token_var.set(secrets.token_urlsafe(32))
        self._append_log("Neues Token erzeugt - auf dem Manager aktualisieren.\n")

    def _install_deps(self) -> None:
        self.dep_label.configure(text="Installiere websockets ...")
        threading.Thread(target=self._pip_install, daemon=True).start()

    def _run_diagnose(self) -> None:
        """Umgebung pruefen und das Ergebnis lesbar anzeigen."""
        self.diag_label.configure(text="Pruefe ...", fg=MUTED)

        def worker() -> None:
            try:
                proc = subprocess.run(
                    [sys.executable, str(WORKER_SCRIPT), "--diagnose"],
                    capture_output=True, text=True, timeout=120, cwd=str(APP_DIR),
                    creationflags=subprocess.CREATE_NO_WINDOW if IS_WINDOWS else 0)
                report = json.loads(_json_part(proc.stdout or ""))
            except (OSError, subprocess.SubprocessError, ValueError) as exc:
                self.root.after(0, lambda: self._show_diagnose(
                    {"problems": [{"text": f"Pruefung fehlgeschlagen: {exc}",
                                    "hint": "", "action": ""}]}))
                return
            self.root.after(0, lambda: self._show_diagnose(report))

        threading.Thread(target=worker, daemon=True).start()

    def _show_diagnose(self, report: dict) -> None:
        problems = report.get("problems") or []
        text = diagnose_text(report)
        self.diag_label.configure(text=text, fg=TEXT if not problems else WARN)
        self._append_log("--- Umgebungspruefung ---\n" + text + "\n")

    def _pip_install(self) -> None:
        try:
            proc = subprocess.run(
                [sys.executable, "-m", "pip", "install", "--upgrade", "websockets"],
                capture_output=True, text=True, timeout=300,
                creationflags=subprocess.CREATE_NO_WINDOW if IS_WINDOWS else 0)
            tail = (proc.stdout or "").strip().splitlines()[-3:]
            for line in tail:
                self.log_queue.put(line + "\n")
            if proc.returncode == 0:
                self.log_queue.put("websockets installiert.\n")
            else:
                self.log_queue.put("Installation fehlgeschlagen:\n")
                self.log_queue.put((proc.stderr or "")[-800:] + "\n")
        except (OSError, subprocess.SubprocessError) as exc:
            self.log_queue.put(f"Installation fehlgeschlagen: {exc}\n")
        self.root.after(0, self._refresh_status)

    def _collect_config(self) -> dict:
        cfg = dict(self.cfg)
        cfg["name"] = self.f_name.var.get().strip() or "worker"
        cfg["port"] = self._as_int(self.f_port.var.get(), 8765)
        cfg["discover_port"] = int(self.cfg.get("discover_port", DEFAULT_DISCOVERY_PORT))
        cfg["scripts_dir"] = self.f_scripts.var.get().strip()
        cfg["queue_capacity"] = max(1, self._as_int(self.f_capacity.var.get(), 4))
        cfg["max_file_mb"] = max(1, self._as_int(self.f_file_mb.var.get(), 512))
        cfg["max_cache_mb"] = max(16, self._as_int(self.f_cache_mb.var.get(), 4096))
        cfg["discover"] = bool(self.var_discover.get())
        cfg["auto_pair"] = bool(self.var_pair.get())
        cfg["tls"] = bool(self.var_tls.get())
        cfg["token"] = self.token_var.get().strip()
        return cfg

    # --------------------------------------------------------------- TLS
    def _update_tls_hint(self) -> None:
        """Kurz erklaeren, was der Schalter bedeutet - ohne Fachchinesisch."""
        if getattr(self, "tls_label", None) is None:
            return
        if bool(self.var_tls.get()):
            self.tls_label.configure(
                text="Die Verbindung ist verschluesselt (wss://). Das Zertifikat "
                     "erzeugt der Worker selbst - auf dem Hauptrechner einmal "
                     "\"Selbstsignierte Zertifikate erlauben\" einschalten.",
                fg=GOOD)
        else:
            self.tls_label.configure(
                text="Ohne Verschluesselung (ws://). Im eigenen LAN meist in "
                     "Ordnung - im WLAN mit fremden Geraeten besser einschalten.",
                fg=WARN)

    def _show_fingerprint(self) -> None:
        """Fingerabdruck des Zertifikats anzeigen (zum Vergleichen)."""
        self.tls_label.configure(text="Ermittle Fingerabdruck ...", fg=MUTED)

        def worker() -> None:
            try:
                proc = subprocess.run(
                    [sys.executable, str(WORKER_SCRIPT), "--tls-self-signed",
                     "--tls-fingerprint"],
                    capture_output=True, text=True, timeout=300, cwd=str(APP_DIR),
                    creationflags=subprocess.CREATE_NO_WINDOW if IS_WINDOWS else 0)
                text = (proc.stdout or "").strip() or (proc.stderr or "").strip()
            except (OSError, subprocess.SubprocessError) as exc:
                text = f"Nicht ermittelbar: {exc}"
            self.root.after(0, lambda: self._show_fingerprint_result(text))

        threading.Thread(target=worker, daemon=True).start()

    def _show_fingerprint_result(self, text: str) -> None:
        self._append_log("--- Zertifikat ---\n" + text + "\n")
        self._update_tls_hint()
        messagebox.showinfo(
            "Zertifikat des Workers",
            text + "\n\nDieser Fingerabdruck muss auf dem Hauptrechner in der "
                   "Cluster-Oberflaeche erscheinen.")

    @staticmethod
    def _as_int(raw: str, fallback: int) -> int:
        try:
            return int(str(raw).strip())
        except (TypeError, ValueError):
            return fallback

    def start_worker(self) -> None:
        if self.proc is not None:
            return
        if not has_websockets():
            messagebox.showwarning(
                "Paket fehlt",
                "Das Paket 'websockets' fehlt.\n\nBitte den Knopf "
                "'websockets installieren' benutzen.")
            return
        cfg = self._collect_config()
        if len(cfg["token"]) < 16:
            messagebox.showwarning("Token", "Das Token ist zu kurz (min. 16 Zeichen).")
            return
        self.cfg = cfg
        save_config(cfg)

        args = worker_args(cfg, sys.executable)
        self._append_log("Worker startet %s ...\n" %
                         ("verschluesselt (wss://)" if cfg.get("tls", DEFAULT_TLS)
                          else "unverschluesselt (ws://)"))

        # CREATE_NO_WINDOW: es darf sich unter Windows kein Konsolenfenster
        # oeffnen - der Worker laeuft unsichtbar im Hintergrund.
        try:
            self.proc = subprocess.Popen(
                args, cwd=str(APP_DIR), stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                errors="replace", bufsize=1,
                creationflags=subprocess.CREATE_NO_WINDOW if IS_WINDOWS else 0)
        except OSError as exc:
            self.proc = None
            messagebox.showerror("Start fehlgeschlagen", str(exc))
            return
        self._append_log("--- Worker gestartet ---\n")
        self._reader = threading.Thread(target=self._read_output, daemon=True)
        self._reader.start()
        self._refresh_status()

    def _read_output(self) -> None:
        proc = self.proc
        if proc is None or proc.stdout is None:
            return
        for line in proc.stdout:
            # Verbindungszustand aus dem Worker-Log ableiten (kein Extra-Kanal).
            if "authentifiziert und verbunden" in line:
                self._manager_connected = True
            elif "Client getrennt" in line:
                self._manager_connected = False
            self.log_queue.put(line)
        self._manager_connected = False
        self.log_queue.put("--- Worker-Prozess beendet ---\n")

    def stop_worker(self) -> None:
        proc = self.proc
        if proc is None:
            return
        try:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
        except OSError:
            pass
        self.proc = None
        self._refresh_status()

    def _on_close(self) -> None:
        if self.proc is not None:
            if not messagebox.askyesno("Beenden",
                                       "Der Worker laeuft noch. Beenden?"):
                return
            self.stop_worker()
        self.root.destroy()

    # ------------------------------------------------------------ Status
    def _refresh_status(self) -> None:
        running = self.proc is not None and self.proc.poll() is None
        if self.proc is not None and self.proc.poll() is not None:
            self.proc = None
            running = False
        if running:
            connected = getattr(self, "_manager_connected", False)
            self.status_label.configure(
                text="Verbunden mit dem Manager" if connected else "Worker laeuft - wartet auf Manager")
            self.dot.itemconfigure(self.dot_id, fill=GOOD if connected else WARN)
            self.info_label.configure(
                text=f"{local_ip()}:{self.f_port.var.get()}  |  UDP "
                     f"{self.cfg.get('discover_port', DEFAULT_DISCOVERY_PORT)}")
            self.btn_start.configure_state(False)
            self.btn_stop.configure_state(True, fill=PANEL_HI)
        else:
            self.status_label.configure(text="Gestoppt")
            self.dot.itemconfigure(self.dot_id, fill=MUTED)
            self.info_label.configure(text=f"Windows/Linux  |  {local_ip()}")
            self.btn_start.configure_state(True, fill=ACCENT)
            self.btn_stop.configure_state(False, fill=PANEL_HI)
        if self.metrics_label is not None:
            self.metrics_label.configure(
                text=f"CPU {machine_cpu_pct():.0f} %   RAM {machine_ram_pct():.0f} %")

        if has_websockets():
            self.dep_label.configure(text="")
            self.fix_button.pack_forget()
            self.hint.configure(
                text="Der Manager findet diesen Rechner automatisch.\n"
                     "Nichts weiter einzutragen.")
        else:
            self.dep_label.configure(
                text="Fehlendes Paket: 'websockets' ist nicht installiert.")
            self.fix_button.pack(anchor="w", pady=(0, 6))
            self.hint.configure(text="Ohne dieses Paket kann der Worker nicht starten.")
        self.root.after(1000, self._refresh_status)

    def _drain_log(self) -> None:
        try:
            while True:
                line = self.log_queue.get_nowait()
                self._append_log(line)
                self._track_line(line)
        except queue.Empty:
            pass
        self.root.after(200, self._drain_log)

    # ------------------------------------------------- Aufgaben-/Transferliste
    def _track_line(self, line: str) -> None:
        """Liest den Worker-Ausgaben die Eckdaten fuer die Balken ab.

        Bewusst Zeilenbasiert: der Worker schreibt bereits verstaendliche
        Meldungen, ein zweiter Kanal waere nur zusaetzliche Komplexitaet.
        """
        # Der Worker schreibt z. B. "Task task-1 → Projekt läuft (Versuch 1)".
        info = read_status_line(line)
        if info is None:
            return
        kind = info["kind"]
        if kind == "task_start":
            self._upsert_task(info["task_id"], info["label"])
        elif kind == "task_files":
            self._set_task_state(info["task_id"], "Eingabedaten bereit", ACCENT)
        elif kind == "task_done":
            ok = bool(info["ok"])
            self._set_task_state(info["task_id"], "fertig" if ok else "Fehler",
                                 GOOD if ok else BAD, 1.0 if ok else -1.0)
            if ok:
                self._drop_task_later(info["task_id"])
        elif kind == "transfer_start":
            self._upsert_transfer(info["name"], 0.0)
        elif kind == "transfer_progress":
            self._upsert_transfer(info["name"], float(info["fraction"]))
        elif kind == "status":
            self.task_metrics = {"aktiv": info["active"], "dateien": info["files"],
                                 "empfangen": info["bytes"]}
            self._refresh_task_summary()

    def _upsert_task(self, task_id: str, label: str) -> None:
        short = task_id[-8:] if len(task_id) > 8 else task_id
        if task_id not in self.task_rows:
            row = TaskRow(self.tasks_box, f"{label}  ({short})")
            row.pack(fill="x")
            self.task_rows[task_id] = row
            self.task_order.append(task_id)
            while len(self.task_order) > MAX_ROWS:
                oldest = self.task_order.pop(0)
                self.task_rows.pop(oldest).destroy()
        self.task_rows[task_id].set_state("laeuft", WARN, -1.0)
        self._refresh_task_summary()

    def _set_task_state(self, task_id: str, text: str, color: str,
                        fraction: float = -1.0) -> None:
        row = self.task_rows.get(task_id)
        if row is not None:
            row.set_state(text, color, fraction)
        self._refresh_task_summary()

    def _drop_task_later(self, task_id: str) -> None:
        """Erledigte Aufgaben nach kurzer Anzeige ausblenden (Uebersicht)."""
        def remove() -> None:
            row = self.task_rows.pop(task_id, None)
            if row is not None:
                row.destroy()
            if task_id in self.task_order:
                self.task_order.remove(task_id)
            self._refresh_task_summary()
        self.root.after(8000, remove)

    def _upsert_transfer(self, name: str, fraction: float) -> None:
        if name not in self.transfer_rows:
            row = TaskRow(self.tasks_box, f"Datei: {name}")
            row.pack(fill="x")
            self.transfer_rows[name] = row
            self.transfer_order.append(name)
            while len(self.transfer_order) > MAX_ROWS:
                oldest = self.transfer_order.pop(0)
                self.transfer_rows.pop(oldest).destroy()
        done = fraction >= 1.0
        self.transfer_rows[name].set_state(
            "empfangen" if done else f"{int(fraction * 100)} %",
            GOOD if done else ACCENT, fraction)
        if done:
            self.root.after(4000, lambda: self._drop_transfer(name))
        self._refresh_task_summary()

    def _drop_transfer(self, name: str) -> None:
        row = self.transfer_rows.pop(name, None)
        if row is not None:
            row.destroy()
        if name in self.transfer_order:
            self.transfer_order.remove(name)
        self._refresh_task_summary()

    def _refresh_task_summary(self) -> None:
        metrics = self.task_metrics
        parts = [f"{len(self.task_rows)} sichtbar"]
        if metrics.get("aktiv"):
            parts.append(f"aktiv: {metrics['aktiv']}")
        if metrics.get("dateien"):
            parts.append(f"Dateien im Cache: {metrics['dateien']}")
        if metrics.get("empfangen"):
            parts.append(f"empfangen: {_human_bytes(int(metrics['empfangen']))}")
        self.tasks_summary.configure(text="   ".join(parts))

    # ------------------------------------------------------------------ Log
    def _append_log(self, text: str) -> None:
        self._log_lines.append(text)
        if len(self._log_lines) > MAX_LOG_LINES:
            self._log_lines = self._log_lines[-MAX_LOG_LINES:]
            self._render_log()
            return
        self._write_log_line(text)

    def _matches_filter(self, line: str) -> bool:
        if self.var_errors_only.get() and not _looks_like_error(line):
            return False
        needle = self.filter_var.get().strip().lower()
        return needle == "" or needle in line.lower()

    def _write_log_line(self, text: str) -> None:
        if not self._matches_filter(text):
            return
        self.log.configure(state="normal")
        self.log.insert("end", text)
        self.log.see("end")
        self.log.configure(state="disabled")

    def _render_log(self) -> None:
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        for line in self._log_lines:
            if self._matches_filter(line):
                self.log.insert("end", line)
        self.log.see("end")
        self.log.configure(state="disabled")

    def _clear_log(self) -> None:
        self._log_lines = []
        self._render_log()


def main() -> None:
    root = tk.Tk()
    try:
        root.tk.call("tk", "scaling", 1.15)
    except tk.TclError:
        pass
    WorkerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
