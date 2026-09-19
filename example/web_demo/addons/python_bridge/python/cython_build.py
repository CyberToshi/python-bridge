#!/usr/bin/env python3
"""Python Bridge - Cython-Build-Tool (.pyx -> importierbares .so/.pyd).

Wird von der GDScript-Seite (CythonManager) mit der venv-Python aufgerufen:

    python cython_build.py --scripts-dir <dir> [--stems a,b] [--force]

Verhalten:
  - Prueft jede .pyx im Skript-Ordner gegen den letzten Build (SHA-256 im
    Zustandsfile ``.cython_state.json``). Unveraenderte Module werden
    uebersprungen (Start bleibt schnell), geaenderte inkrementell ueber
    setuptools ``build_ext --inplace`` kompiliert (Cython nutzt die
    Timestamp-Logik von distutils fuer .c/.o).
  - Compiler-Kette: bevorzugt der System-Compiler (gcc/cc bzw. MSVC). Wenn
    keiner gefunden wird, Fallback auf das pip-Paket ``ziglang`` (kompletter
    C-Compiler als Wheel, kein System-Setup). Fehlt eine Komponente, ist das
    ein strukturierter Fehler mit Installations-Hinweis - kein Crash.
  - Gibt IMMER einen JSON-Report auf stdout aus (letzte Zeile), auch bei
    Fehlerfaellen einzelner Dateien. Exit-Code 0, solange das Tool selbst
    lief; ok=false im Report signalisiert Build-Fehler.

Web/Pyodide: dort gibt es keinen C-Compiler - .pyx wird nicht unterstuetzt
(der Export-Check warnt). Dieses Tool ist Desktop-only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

STATE_FILE = ".cython_state.json"


def _report(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def _load_state(build_dir: Path) -> dict:
    try:
        return json.loads((build_dir / STATE_FILE).read_text("utf-8"))
    except Exception:
        return {}


def _save_state(build_dir: Path, state: dict) -> None:
    tmp = build_dir / (STATE_FILE + ".tmp")
    tmp.write_text(json.dumps(state, indent=1), "utf-8")
    os.replace(tmp, build_dir / STATE_FILE)


def _pyx_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _output_present(scripts_dir: Path, stem: str) -> bool:
    for f in scripts_dir.iterdir():
        if f.name.startswith(stem + ".") and f.suffix in (".so", ".pyd"):
            return True
    return False


def _pip_install(mods: list) -> tuple[bool, str]:
    """Installiert fehlende Build-Pakete in DIESE venv (Self-Provisioning,
    damit der erste .pyx-Build ohne manuelle Vorbereitung funktioniert)."""
    cmd = [sys.executable, "-m", "pip", "install", "--disable-pip-version-check",
           "--timeout", "60"] + mods
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        if proc.returncode != 0:
            return False, ((proc.stdout or "") + (proc.stderr or ""))[-1200:]
        return True, ""
    except Exception as exc:  # noqa: BLE001
        return False, "%s: %s" % (type(exc).__name__, exc)


def _compiler_env() -> tuple[dict, str, list]:
    """Env fuer subprocess + Beschreibung + fehlende Komponenten.

    Reihenfolge: System-CC (distutils-Default) -> ziglang-Fallback."""
    missing = []
    for mod in ("Cython", "setuptools"):
        try:
            __import__(mod)
        except ImportError:
            missing.append(mod)
    if missing:
        return {}, "none", missing

    if shutil.which("gcc") or shutil.which("cc") or shutil.which("clang"):
        return {}, "system", []  # distutils findet den Compiler selbst

    try:
        import ziglang  # noqa: F401
    except ImportError:
        missing.append("ziglang")
        return {}, "none", missing

    # zig cc kennt exotische Distro-Linker-Flags (-Bsymbolic-functions) nicht;
    # wir setzen CC/LDSHARED vollstaendig auf zig (Beweis: siehe Tests).
    zig_cc = f'"{sys.executable}" -m ziglang cc'
    return {
        "CC": zig_cc,
        "LDSHARED": zig_cc + " -shared",
    }, "zig", []


def _build_one(scripts_dir: Path, stem: str, env: dict) -> tuple[bool, str]:
    """Ein Modul kompilieren (setup.py-Fallback in(temp)-Datei)."""
    setup_py = scripts_dir / "cython_setup.py"
    setup_py.write_text(
        "from setuptools import setup\n"
        "from Cython.Build import cythonize\n"
        "setup(ext_modules=cythonize(%r, language_level=3))\n" % (stem + ".pyx"),
        "utf-8",
    )
    cmd = [sys.executable, str(setup_py), "build_ext", "--inplace", "--build-lib",
           str(scripts_dir / "cython_build_tmp")]
    try:
        proc = subprocess.run(
            cmd, cwd=str(scripts_dir), env={**os.environ, **env},
            capture_output=True, text=True, timeout=600)
        if proc.returncode != 0:
            tail = (proc.stdout or "") + (proc.stderr or "")
            return False, tail.strip()[-2000:] or "build_ext failed (rc=%d)" % proc.returncode
        return True, ""
    except subprocess.TimeoutExpired:
        return False, "Build-Timeout (600 s) bei '%s'" % stem
    except Exception as exc:  # noqa: BLE001
        return False, "%s: %s" % (type(exc).__name__, exc)
    finally:
        try:
            setup_py.unlink()
        except OSError:
            pass


def _emit(report: dict, report_file: str) -> None:
    """Report nach stdout UND (falls angegeben) atomar in die Report-Datei.
    os.replace garantiert, dass die Datei fuer den Poller erst sichtbar wird,
    wenn der Inhalt vollstaendig ist."""
    _report(report)
    if report_file:
        p = Path(report_file)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(p.suffix + ".tmp")
        tmp.write_text(json.dumps(report), "utf-8")
        os.replace(tmp, p)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--scripts-dir", required=True)
    ap.add_argument("--stems", default="", help="kommasepariert; leer = alle .pyx")
    ap.add_argument("--force", action="store_true", help="Hash-Check ignorieren")
    ap.add_argument("--report", default="",
                    help="Report zusaetzlich ATOMAR in diese Datei schreiben "
                         "(GDScript pollt das Erscheinen als Abschluss-Signal)")
    ap.add_argument("--no-install", action="store_true",
                    help="fehlende Build-Pakete NICHT automatisch installieren")
    args = ap.parse_args()

    scripts_dir = Path(args.stems).resolve() if False else Path(args.scripts_dir).resolve()
    if not scripts_dir.is_dir():
        _emit({"ok": False, "error": "scripts-dir fehlt: %s" % scripts_dir,
               "built": [], "skipped": [], "errors": [], "compiler": "none", "duration_s": 0},
              args.report)
        return 0

    if args.stems:
        wanted = [s.strip() for s in args.stems.split(",") if s.strip()]
        targets = [scripts_dir / (s + ".pyx") for s in wanted]
    else:
        targets = sorted(scripts_dir.glob("*.pyx"))
    targets = [t for t in targets if t.is_file()]

    state = _load_state(scripts_dir)
    t0 = time.time()
    built, skipped, errors, compiler = [], [], [], "-"
    env = {}

    if targets:
        env, compiler, missing = _compiler_env()
        if missing:
            # Self-Provisioning: fehlende Build-Pakete (cython, setuptools,
            # ziglang-Fallback) automatisch in DIESE venv installieren -
            # der erste .pyx-Build soll ohne manuelle Vorbereitung laufen.
            installed: list[str] = []
            if not args.no_install:
                for m in list(missing):
                    ok, _log = _pip_install([m])
                    if ok:
                        installed.append(m)
                        missing.remove(m)
            env, compiler, missing = _compiler_env() if not missing else ({}, "none", missing)
            if missing:
                hint = "pip install " + " ".join(missing) + "  (in der Bridge-venv)"
                for t in targets:
                    errors.append({"file": t.name, "message":
                                   "Cython-Build-Komponenten fehlen: %s. Abhilfe: %s"
                                   % (", ".join(missing), hint)})
                _emit({"ok": False, "built": [], "skipped": [], "errors": errors,
                       "compiler": "none", "duration_s": round(time.time() - t0, 2),
                       "missing": missing, "self_installed": installed}, args.report)
                return 0

    for pyx in targets:
        stem = pyx.stem
        h = _pyx_hash(pyx)
        if not args.force and state.get(stem) == h and _output_present(scripts_dir, stem):
            skipped.append(stem)
            continue
        ok, msg = _build_one(scripts_dir, stem, env)
        if ok:
            state[stem] = h
            built.append(stem)
        else:
            errors.append({"file": pyx.name, "message": msg})

    if targets:
        _save_state(scripts_dir, state)
    _emit({
        "ok": not errors,
        "built": built,
        "skipped": skipped,
        "errors": errors,
        "compiler": compiler,
        "duration_s": round(time.time() - t0, 2),
    }, args.report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
