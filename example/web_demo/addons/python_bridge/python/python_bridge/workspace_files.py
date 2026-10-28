"""Workspace-Dateioperationen für den ``file_op``-Kanal.

Warum es diesen Kanal gibt
--------------------------
Auf dem Desktop schreiben Godot und Python dieselben Dateien auf dieselbe
Festplatte: ``create_script()`` legt ``<workspace>/scripts/x.py`` an, und der
Python-Prozess sieht sie sofort.

Im Browser ist das nicht so. Godot schreibt in sein eigenes ``user://``-
Dateisystem, Python läuft dagegen in einem Pyodide-Worker mit einem
**eigenen** MEMFS unter ``/workspace`` (aus ``bridge_workspace.tar`` entpackt).
Ohne Spiegelung würde ein zur Laufzeit erstelltes Skript dort nie existieren -
``import x`` schlüge fehl, und ein gelöschtes Skript bliebe importierbar.

``file_op`` ist deshalb ein einseitiger Sync-Kanal (Godot -> Python) mit genau
zwei Operationen:

    {"type": "file_op", "op": "write", "path": "scripts/x.py", "content": "..."}
    {"type": "file_op", "op": "delete", "path": "scripts/x.py"}

Sicherheit: ``path`` ist relativ zum Workspace, ``..``-Anteile, absolute
Pfade und Laufwerkspfade werden abgelehnt; erlaubt sind nur die bekannten
Workspace-Ordner. So kann eine fehlerhafte Nachricht nie außerhalb des
Workspace schreiben.

Das Modul ist bewusst frei von Pyodide-Abhängigkeiten (nur ``os``/``pathlib``)
und damit vollständig unit-testbar.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Ordner, in die geschrieben werden darf (relativ zum Workspace-Root).
ALLOWED_PREFIXES = ("scripts/", "modules/", "plugins/", "packages/")
MAX_CONTENT_BYTES = 8 * 1024 * 1024


class FileOpError(ValueError):
    """Ungültige ``file_op``-Nachricht (Pfad, Operation, Größe)."""


def _normalize_rel_path(rel_path: str) -> str:
    raw = str(rel_path or "").replace("\\", "/").strip()
    if not raw:
        raise FileOpError("file_op: leerer Pfad")
    if raw.startswith("/") or (len(raw) > 1 and raw[1] == ":"):
        raise FileOpError("file_op: absolute Pfade sind nicht erlaubt: %s" % raw)
    parts = [p for p in raw.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        raise FileOpError("file_op: '..' ist nicht erlaubt: %s" % raw)
    normalized = "/".join(parts)
    if not normalized.startswith(ALLOWED_PREFIXES):
        raise FileOpError(
            "file_op: Pfad muss in einem der Ordner %s liegen: %s"
            % (", ".join(ALLOWED_PREFIXES), raw))
    return normalized


def apply_file_op(workspace_root: str, op: str, rel_path: str, content: str = "") -> dict:
    """Führt eine ``file_op`` im Workspace aus.

    Rückgabe: ``{"ok": bool, "op": str, "path": str, "error": str,
    "bytes": int}``. Fehler werden als strukturiertes Ergebnis gemeldet (der
    Aufrufer im Worker darf nie an einer Dateioperation sterben).
    """
    root = str(workspace_root or "").strip()
    if not root:
        return {"ok": False, "op": str(op), "path": str(rel_path),
                "error": "file_op: kein Workspace bekannt", "bytes": 0}
    # Der Workspace-Root muss bereits existieren: ein Tippfehler im Root darf
    # nicht dazu fuehren, dass irgendwo ein neuer Baum angelegt wird.
    if not Path(root).is_dir():
        return {"ok": False, "op": str(op), "path": str(rel_path),
                "error": "file_op: Workspace-Ordner existiert nicht: %s" % root,
                "bytes": 0}
    try:
        normalized = _normalize_rel_path(rel_path)
    except FileOpError as exc:
        return {"ok": False, "op": str(op), "path": str(rel_path),
                "error": str(exc), "bytes": 0}

    target = Path(root) / normalized
    try:
        if op == "write":
            text = str(content)
            encoded = text.encode("utf-8")
            if len(encoded) > MAX_CONTENT_BYTES:
                return {"ok": False, "op": "write", "path": normalized,
                        "error": "file_op: Inhalt zu groß (%d Bytes)" % len(encoded),
                        "bytes": 0}
            target.parent.mkdir(parents=True, exist_ok=True)
            # Atomar ersetzen: eine halb geschriebene Datei darf nie
            # importierbar sein.
            tmp = target.with_suffix(target.suffix + ".tmp")
            with open(tmp, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
            os.replace(tmp, target)
            # Neu geschriebene Quelle: ein bereits importiertes Modul darf
            # nicht als alter Stand weiterleben (import cached dauerhaft).
            _drop_loaded_modules(normalized)
            # Ordner, die erst zur Laufzeit entstehen (z. B. das erste Skript
            # ueberhaupt), muessen importierbar werden, ohne den Server neu
            # zu starten.
            ensure_on_sys_path(root)
            return {"ok": True, "op": "write", "path": normalized,
                    "error": "", "bytes": len(encoded)}
        if op == "delete":
            removed = []
            for candidate in (target, target.with_suffix(target.suffix + ".tmp")):
                try:
                    candidate.unlink()
                    removed.append(candidate.name)
                except FileNotFoundError:
                    pass
            _drop_pycache_for(target)
            # Gleiches Argument wie beim Schreiben: ohne ``sys.modules``-Auf-
            # raeumen bliebe ein geloeschtes Modul in derselben Sitzung
            # weiter importierbar - der haeufigste "Loeschen wirkt nicht"-Bug.
            _drop_loaded_modules(normalized)
            return {"ok": True, "op": "delete", "path": normalized,
                    "error": "", "bytes": len(removed)}
        return {"ok": False, "op": str(op), "path": normalized,
                "error": "file_op: unbekannte Operation '%s'" % op, "bytes": 0}
    except OSError as exc:
        return {"ok": False, "op": str(op), "path": normalized,
                "error": "file_op: %s: %s" % (type(exc).__name__, exc), "bytes": 0}


def ensure_on_sys_path(workspace_root: str) -> list:
    """Macht den Workspace importierbar (idempotent, best effort).

    Reihenfolge wie in ``run_server.py``: Root vorn (Namespace-Pakete
    ``modules.x``), die Unterordner hinten angehaengt, damit kompilierte
    Module und Standardpfade nicht beschattet werden.

    Rueckgabe: die tatsaechlich neu eingetragenen Pfade.
    """
    root = str(workspace_root or "").strip()
    if not root or not Path(root).is_dir():
        return []
    added = []
    if root not in sys.path:
        sys.path.insert(0, root)
        added.append(root)
    for sub in ("scripts", "modules", "plugins", "packages"):
        path = os.path.join(root, sub)
        if os.path.isdir(path) and path not in sys.path:
            sys.path.append(path)
            added.append(path)
    return added


def _module_names_for(rel_path: str) -> list:
    """Modulnamen, unter denen ``rel_path`` importierbar waere.

    ``scripts/x.py`` liegt im Ordner, der selbst auf ``sys.path`` steht ->
    ``x``. ``modules/p/x.py``/``plugins/...``/``packages/...`` liegen unter dem
    Workspace-Root (auch auf ``sys.path``) -> ``modules.p.x``.
    """
    rel = rel_path.replace("\\", "/")
    if not rel.endswith(".py"):
        return []
    rel = rel[:-3]
    if rel.endswith("/__init__"):
        rel = rel[: -len("/__init__")]
    if rel.startswith("scripts/"):
        rel = rel[len("scripts/"):]
    parts = [p for p in rel.split("/") if p]
    if not parts:
        return []
    dotted = ".".join(parts)
    return [dotted, dotted + ".__init__"]


def _drop_loaded_modules(rel_path: str) -> None:
    """Entfernt die geladene(n) Fassung(en) aus ``sys.modules`` (best effort).

    Auch Untermodule (``pkg.sub``) fliegen raus, damit ein geloeschtes Paket
    nicht ueber einen bereits importierten Teil weiterlebt.
    """
    for name in _module_names_for(rel_path):
        base = name[:-len(".__init__")] if name.endswith(".__init__") else name
        for key in [k for k in list(sys.modules)
                    if k == base or k.startswith(base + ".")]:
            sys.modules.pop(key, None)


def _drop_pycache_for(target: Path) -> None:
    """Entfernt den Bytecode-Cache zu ``target`` (best effort).

    Ohne das könnte ein gelöschtes Modul in derselben Sitzung aus
    ``__pycache__`` weiter importiert werden.
    """
    cache_dir = target.parent / "__pycache__"
    if not cache_dir.is_dir():
        return
    stem = target.stem
    try:
        for entry in cache_dir.iterdir():
            if entry.name.startswith(stem + ".") and entry.suffix == ".pyc":
                try:
                    entry.unlink()
                except OSError:
                    pass
    except OSError:
        pass
