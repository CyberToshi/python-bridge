#!/usr/bin/env python3
"""Empfang und Ablage grosser Eingabedateien (Phase 6-8, Worker-Seite).

Dateien werden **inhaltsadressiert** gespeichert: der Dateiname im Speicher ist
der SHA-256 des Inhalts.

    <root>/files/<sha256>        fertige, gepruefte Datei
    <root>/incoming/<id>.part    laufender Empfang (wird nie ausgefuehrt)

Daraus folgen drei Eigenschaften:

* **Kein Doppeltransfer.** Kennt der Worker den Hash schon, meldet er "have"
  und der Controller schickt keine Daten (§12).
* **Integritaet.** Erst wenn der SHA-256 der empfangenen Datei passt, wird sie
  umbenannt und ist damit "vorhanden" (§14). Ein abgebrochener Transfer
  hinterlaesst nur eine `.part`-Datei.
* **Kein Pfad-Ausbruch.** Dateinamen kommen aus dem Netz: sie werden auf einen
  Basisnamen reduziert und gegen eine Zeichenliste geprueft. Zusaetzlich schuetzt
  eine Plattenplatz- und Groessenpruefung den Rechner (§ Sicherheit).

Es wird **nur** innerhalb von `root` geschrieben; Systemdateien sind nicht
erreichbar, weil jeder Pfad aus geprueften Bestandteilen zusammengesetzt wird.
"""

from __future__ import annotations

import base64
import hashlib
import os
import re
import shutil
from pathlib import Path
from typing import Callable

# 64 Hex-Zeichen: genau das Format, das der Controller als Datei-ID schickt.
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_TRANSFER_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
# Erlaubter Anzeigename (wird zum Dateinamen im Arbeitsverzeichnis der Aufgabe).
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._ -]{0,126}$")

DEFAULT_MAX_FILE_BYTES = 512 * 1024 * 1024          # 512 MB pro Datei
DEFAULT_MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024    # 4 GB Cache insgesamt
DEFAULT_MIN_FREE_BYTES = 512 * 1024 * 1024          # Reserve auf der Platte
DEFAULT_MAX_AGE_DAYS = 14


class FileError(RuntimeError):
    """Fehler mit klarer Ursache fuer den Benutzer."""

    def __init__(self, message: str, *, code: str = "rejected") -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class FileStore:
    """Verwaltet empfangene Eingabedateien im Worker-Cache."""

    def __init__(self, root: str | Path, *,
                 max_file_bytes: int = DEFAULT_MAX_FILE_BYTES,
                 max_total_bytes: int = DEFAULT_MAX_TOTAL_BYTES,
                 min_free_bytes: int = DEFAULT_MIN_FREE_BYTES,
                 log: Callable[[str], None] | None = None) -> None:
        self.root = Path(root).expanduser().resolve()
        self.files_dir = self.root / "files"
        self.incoming_dir = self.root / "incoming"
        self.max_file_bytes = max(int(max_file_bytes), 1)
        self.max_total_bytes = max(int(max_total_bytes), 1)
        self.min_free_bytes = max(int(min_free_bytes), 0)
        self.log = log or (lambda _text: None)
        self._active: dict[str, dict] = {}
        for directory in (self.files_dir, self.incoming_dir):
            directory.mkdir(parents=True, exist_ok=True)

    # -------------------------------------------------------------- Bestand
    def have(self, file_id: str) -> bool:
        return self._safe_id(file_id) is not None and \
            self.files_dir.joinpath(file_id.lower()).is_file()

    def present_ids(self) -> list[str]:
        try:
            return sorted(p.name for p in self.files_dir.iterdir()
                          if p.is_file() and _SHA256_RE.match(p.name))
        except OSError:
            return []

    def path_of(self, file_id: str) -> Path | None:
        key = self._safe_id(file_id)
        if key is None:
            return None
        candidate = self.files_dir / key
        return candidate if candidate.is_file() else None

    def usage(self) -> dict:
        total = 0
        count = 0
        try:
            for path in self.files_dir.iterdir():
                if path.is_file():
                    total += path.stat().st_size
                    count += 1
        except OSError:
            pass
        return {"files": count, "bytes": total, "active_transfers": len(self._active)}

    # -------------------------------------------------------------- Empfang
    def begin(self, transfer_id: str, file_id: str, name: str, size: int,
              sha256: str) -> str:
        """Anmeldung einer Datei. Liefert \"have\" oder \"accepted\".

        Wirft FileError mit klarer Begruendung, wenn etwas nicht passt
        (Groesse, Plattenplatz, ungueltiger Name, ...).
        """
        if not _TRANSFER_RE.match(transfer_id) or transfer_id in (".", ".."):
            raise FileError("ungueltige Transfer-ID")
        key = self._safe_id(sha256)
        if key is None or key != file_id.lower():
            raise FileError("ungueltige Datei-ID (SHA-256 erwartet)")
        size = int(size)
        if size < 0 or size > self.max_file_bytes:
            raise FileError(
                f"Datei ist zu gross ({size / 1048576.0:.1f} MB, Limit "
                f"{self.max_file_bytes / 1048576.0:.1f} MB)")
        if not _NAME_RE.match(Path(name).name) or Path(name).name in (".", ".."):
            raise FileError(f"ungueltiger Dateiname: {name!r}")
        if self.have(key):
            return "have"
        self._check_space(size)
        self._check_total(size)
        part = self.incoming_dir / f"{transfer_id}.part"
        try:
            with open(part, "wb") as handle:
                handle.truncate(size)          # Platz reservieren, kein RAM
        except OSError as exc:
            raise FileError(f"Arbeitsdatei nicht anlegbar: {exc}") from None
        self._active[transfer_id] = {
            "file_id": key,
            "name": Path(name).name,
            "size": size,
            "received": 0,
            "next_index": 0,
            "part": part,
        }
        return "accepted"

    def chunk(self, transfer_id: str, index: int, data_b64: str) -> int:
        """Ein Stueck ablegen. Liefert die bisher empfangene Bytezahl."""
        state = self._active.get(transfer_id)
        if state is None:
            raise FileError("kein laufender Transfer mit dieser ID")
        index = int(index)
        if index != state["next_index"]:
            raise FileError(f"Stueck {index} passt nicht (erwartet "
                            f"{state['next_index']})")
        try:
            data = base64.b64decode(data_b64, validate=True)
        except (ValueError, TypeError):
            raise FileError("Stueck ist nicht lesbar (Base64)") from None
        if state["received"] + len(data) > state["size"]:
            raise FileError("es kommen mehr Daten als angekuendigt")
        try:
            with open(state["part"], "r+b") as handle:
                handle.seek(state["received"])
                handle.write(data)
        except OSError as exc:
            raise FileError(f"Schreiben fehlgeschlagen: {exc}") from None
        state["received"] += len(data)
        state["next_index"] = index + 1
        return int(state["received"])

    def finish(self, transfer_id: str, sha256: str) -> str:
        """Abschluss: SHA-256 pruefen und Datei uebernehmen.

        Liefert den finalen Dateipfad. Bei falscher Pruefsumme wird die Datei
        verworfen (FileError mit code=\"hash_failed\").
        """
        state = self._active.pop(transfer_id, None)
        if state is None:
            raise FileError("kein laufender Transfer mit dieser ID")
        part: Path = state["part"]
        expected = self._safe_id(sha256) or state["file_id"]
        if expected != state["file_id"]:
            part.unlink(missing_ok=True)
            raise FileError("Pruefsumme passt nicht zur Anmeldung", code="hash_failed")
        if state["received"] != state["size"]:
            part.unlink(missing_ok=True)
            raise FileError(
                f"Datei unvollstaendig ({state['received']} von {state['size']} Bytes)",
                code="hash_failed")
        actual = _sha256_file(part)
        if actual != expected:
            part.unlink(missing_ok=True)
            self.log(f"Pruefsumme falsch: erwartet {expected[:12]}…, "
                     f"erhalten {actual[:12]}…")
            raise FileError("Pruefsumme stimmt nicht (SHA-256)", code="hash_failed")
        target = self.files_dir / expected
        try:
            os.replace(part, target)      # atomar: nie halbe Dateien sichtbar
        except OSError as exc:
            part.unlink(missing_ok=True)
            raise FileError(f"Datei konnte nicht abgelegt werden: {exc}") from None
        return str(target)

    def abort(self, transfer_id: str) -> None:
        state = self._active.pop(transfer_id, None)
        if state is not None:
            Path(state["part"]).unlink(missing_ok=True)

    def abort_all(self) -> None:
        for transfer_id in list(self._active):
            self.abort(transfer_id)

    # -------------------------------------------------------------- Nutzung
    def materialize(self, file_id: str, name: str, target_dir: Path) -> Path:
        """Datei fuer eine Aufgabe bereitstellen (im Arbeitsverzeichnis).

        Bevorzugt ein Hardlink (kein Kopieren); wenn das nicht geht, wird
        kopiert. Der Name wird erneut geprueft - er landet auf der Platte.
        """
        source = self.path_of(file_id)
        if source is None:
            raise FileError(f"Datei fehlt auf diesem Rechner: {name}")
        safe_name = Path(name).name
        if not _NAME_RE.match(safe_name):
            safe_name = f"datei-{file_id[:12]}"
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / safe_name
        if target.exists():
            return target
        try:
            os.link(source, target)
            return target
        except OSError:
            pass
        try:
            shutil.copyfile(source, target)
        except OSError as exc:
            raise FileError(f"Datei konnte nicht bereitgestellt werden: {exc}") from None
        return target

    # -------------------------------------------------------------- Pflege
    def prune(self, max_total_bytes: int | None = None,
              max_age_days: int = DEFAULT_MAX_AGE_DAYS) -> dict:
        """Speicher begrenzen: aelteste Dateien zuerst.

        Wird **nur beim Start** aufgerufen. Danach meldet sich der Worker neu
        beim Manager und der weiss durch die Bestandsliste wieder, was da ist.
        """
        limit = max(int(max_total_bytes or self.max_total_bytes), 1)
        import time
        removed = 0
        try:
            entries = sorted(((p.stat().st_mtime, p) for p in self.files_dir.iterdir()
                              if p.is_file()), key=lambda item: item[0])
        except OSError:
            return {"removed": 0}
        total = sum(mtime_size[1].stat().st_size for mtime_size in entries
                    if mtime_size[1].is_file())
        deadline = time.time() - max_age_days * 86400
        for mtime, path in entries:
            too_old = mtime < deadline
            too_big = total > limit
            if not (too_old or too_big):
                break
            try:
                total -= path.stat().st_size
                path.unlink(missing_ok=True)
                removed += 1
            except OSError:
                continue
        # Reste abgebrochener Transfers ebenfalls wegraeumen.
        try:
            for leftover in self.incoming_dir.iterdir():
                if leftover.is_file():
                    leftover.unlink(missing_ok=True)
        except OSError:
            pass
        return {"removed": removed, "bytes": total}

    # -------------------------------------------------------------- intern
    @staticmethod
    def _safe_id(value: str) -> str | None:
        text = str(value).strip().lower()
        return text if _SHA256_RE.match(text) else None

    def _check_space(self, needed: int) -> None:
        try:
            free = shutil.disk_usage(str(self.root)).free
        except OSError:
            return
        if free - needed < self.min_free_bytes:
            raise FileError(
                "zu wenig Platz auf dem Worker-Rechner "
                f"({free / 1048576.0:.0f} MB frei, "
                f"{self.min_free_bytes / 1048576.0:.0f} MB bleiben reserviert)")

    def _check_total(self, needed: int) -> None:
        # Laufende Empfaenge zaehlen mit: sonst koennten mehrere gleichzeitige
        # Transfers die Obergrenze um ein Vielfaches ueberschreiten (jeder
        # prueft nur gegen die bereits *fertigen* Dateien).
        used = int(self.usage()["bytes"])
        used += sum(int(state.get("size", 0)) for state in self._active.values())
        if used + needed > self.max_total_bytes:
            raise FileError(
                "Datei-Cache des Workers ist voll "
                f"({used / 1048576.0:.0f} MB von "
                f"{self.max_total_bytes / 1048576.0:.0f} MB)")


def _sha256_file(path: Path, block: int = 1024 * 1024) -> str:
    """SHA-256 strickenweise: grosse Dateien landen nie komplett im RAM."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            data = handle.read(block)
            if not data:
                break
            digest.update(data)
    return digest.hexdigest()
