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
  - Compiler-Kette (pro Plattform, in dieser Reihenfolge ausprobiert):
      * Windows: MSVC (setuptools-Default) -> mingw32 (falls ``gcc`` im PATH).
        ``ziglang`` hilft dort NICHT: setuptools benutzt auf Windows immer
        den MSVC-Treiber und ignoriert ``CC``/``LDSHARED``.
      * POSIX: System-CC -> ``ziglang`` (Wheel-Compiler, kein System-Setup).
    Jede Strategie wird beim ersten Fehler verworfen, die naechste probiert;
    erst wenn alle scheitern, gibt es einen strukturierten Fehler mit
    Installations-Hinweis - kein Crash.
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
TMP_DIR = "cython_build_tmp"


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


# Marker, an denen sich ein Compiler-/Linker-Problem von einem Fehler IN der
# .pyx unterscheiden laesst. Nur dann lohnt die naechste Strategie.
_COMPILER_ERROR_MARKERS = (
    "microsoft visual c++", "vcvarsall", "command 'cl.exe'",
    "command 'gcc' failed", "gcc: not found", "gcc: command not found",
    "clang: not found", "clang: command not found",
    "command 'cc' failed", "cc: not found", "no such file or directory: 'gcc'",
    "cannot find -lpython", "undefined reference", "unable to find a c",
    "linker command failed", "fatal error",
)


def _looks_like_compiler_error(message: str) -> bool:
    text = (message or "").lower()
    return any(marker in text for marker in _COMPILER_ERROR_MARKERS)


def _build_packages_missing() -> list[str]:
    """Fehlende Python-Build-Pakete (Cython/setuptools) in DIESER venv."""
    missing = []
    for mod in ("Cython", "setuptools"):
        try:
            __import__(mod)
        except ImportError:
            missing.append(mod)
    return missing


def _zig_strategy() -> dict | None:
    """``ziglang`` als kompletter C-Compiler (nur POSIX sinnvoll).

    ``zig cc`` kennt exotische Distro-Linker-Flags (-Bsymbolic-functions)
    nicht; deshalb werden CC und LDSHARED vollstaendig auf zig gesetzt.
    Auf Windows ignoriert setuptools diese Variablen (MSVC-Treiber), dort ist
    die Strategie nutzlos - siehe ``_candidate_strategies()``.
    """
    try:
        import ziglang  # noqa: F401
    except ImportError:
        return None
    zig_cc = f'"{sys.executable}" -m ziglang cc'
    return {
        "name": "zig",
        "args": [],
        "env": {"CC": zig_cc, "LDSHARED": zig_cc + " -shared"},
    }


def _candidate_strategies() -> list[dict]:
    """Compiler-Strategien in Ausprobier-Reihenfolge (leer = keine moeglich).

    Windows: MSVC (setuptools findet es selbst) -> mingw32 bei ``gcc`` im PATH.
    Ohne beides ist kein Build moeglich; ``ziglang`` wird dort bewusst nicht
    angeboten, weil setuptools den MSVC-Treiber erzwingt.
    POSIX: System-CC -> zig-Fallback.
    """
    strategies: list[dict] = []
    if os.name == "nt":
        strategies.append({"name": "msvc", "args": [], "env": {}})
        if shutil.which("gcc"):
            strategies.append({"name": "mingw32", "args": ["--compiler=mingw32"],
                               "env": {}})
        return strategies

    if shutil.which("gcc") or shutil.which("cc") or shutil.which("clang"):
        strategies.append({"name": "system", "args": [], "env": {}})
    zig = _zig_strategy()
    if zig is not None:
        strategies.append(zig)
    return strategies


def _compiler_hint() -> str:
    """Handlungsfaehiger Hinweis, wenn gar kein Compiler verfuegbar ist."""
    if os.name == "nt":
        return ("Auf Windows braucht der Cython-Build einen C-Compiler: "
                "entweder die Visual Studio Build Tools (Workload "
                "\"Desktop development with C++\") oder MinGW-w64 mit "
                "``gcc`` im PATH.")
    return ("Es wurde kein C-Compiler gefunden. Installiere gcc/clang "
            "(oder lasse das Tool ``ziglang`` nachinstallieren).")


def _build_one(scripts_dir: Path, stem: str, strategy: dict) -> tuple[bool, str]:
    """Ein Modul kompilieren (Setup-Skript in temporaere Datei im Ordner)."""
    setup_py = scripts_dir / "cython_setup.py"
    setup_py.write_text(
        "from setuptools import setup\n"
        "from Cython.Build import cythonize\n"
        "setup(ext_modules=cythonize(%r, language_level=3, compiler_directives="
        "{'language_level': 3}))\n" % (stem + ".pyx"),
        "utf-8",
    )
    # --inplace legt das fertige Modul neben die .pyx (dort muss es liegen,
    # damit scripts/ auf sys.path es importiert). Temp- und Lib-Ordner wandern
    # nach cython_build_tmp: sonst bleibt ein "build/"-Baum im Skriptordner
    # liegen, den der Export nicht kennt.
    tmp_root = scripts_dir / TMP_DIR
    cmd = [sys.executable, str(setup_py), "build_ext", "--inplace",
           "--build-temp", str(tmp_root / ("temp_" + stem)),
           "--build-lib", str(tmp_root / ("lib_" + stem))] + list(strategy.get("args") or [])
    env = strategy.get("env") or {}
    try:
        proc = subprocess.run(
            cmd, cwd=str(scripts_dir), env={**os.environ, **env},
            capture_output=True, text=True, timeout=600)
        if proc.returncode != 0:
            tail = (proc.stdout or "") + (proc.stderr or "")
            return False, tail.strip()[-2000:] or "build_ext failed (rc=%d)" % proc.returncode
        # Temp-/Lib-Baeume sind reine Zwischenstaende: das Modul liegt per
        # --inplace neben der .pyx. Aufraeumen haelt den Skriptordner leer.
        shutil.rmtree(tmp_root / ("temp_" + stem), ignore_errors=True)
        shutil.rmtree(tmp_root / ("lib_" + stem), ignore_errors=True)
        return True, ""
    except subprocess.TimeoutExpired:
        # Timeout ist kein Compiler-Problem: alle weiteren Strategien
        # wuerden genauso haengen.
        return False, "Build-Timeout (600 s) bei '%s' [%s]" % (stem, strategy.get("name"))
    except Exception as exc:  # noqa: BLE001
        return False, "%s: %s [%s]" % (type(exc).__name__, exc, strategy.get("name"))
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

    scripts_dir = Path(args.scripts_dir).resolve()
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
    built, skipped, errors = [], [], []
    installed: list[str] = []
    strategies: list[dict] = []
    compiler = "-"

    if targets:
        # Self-Provisioning: fehlende Build-Pakete (Cython, setuptools)
        # automatisch in DIESE venv installieren - der erste .pyx-Build soll
        # ohne manuelle Vorbereitung laufen.
        missing = _build_packages_missing()
        if missing and not args.no_install:
            for m in list(missing):
                ok, _log = _pip_install([m])
                if ok:
                    installed.append(m)
                    missing.remove(m)
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

        strategies = _candidate_strategies()
        if not strategies and os.name != "nt" and not args.no_install:
            # POSIX ohne System-CC: ziglang ist dort ein vollwertiger Ersatz
            # (Wheel mit clang/lld). Auf Windows bewusst nicht - setuptools
            # erzwingt dort den MSVC-Treiber und ignoriert CC/LDSHARED.
            ok_install, _log = _pip_install(["ziglang"])
            if ok_install:
                installed.append("ziglang")
                strategies = _candidate_strategies()
        if not strategies:
            hint = _compiler_hint()
            for t in targets:
                errors.append({"file": t.name,
                               "message": "Kein C-Compiler verfuegbar. " + hint})
            _emit({"ok": False, "built": [], "skipped": [], "errors": errors,
                   "compiler": "none", "duration_s": round(time.time() - t0, 2),
                   "missing": [], "self_installed": installed}, args.report)
            return 0
        compiler = strategies[0]["name"]

    for pyx in targets:
        stem = pyx.stem
        h = _pyx_hash(pyx)
        if not args.force and state.get(stem) == h and _output_present(scripts_dir, stem):
            skipped.append(stem)
            continue
        attempts: list[str] = []
        ok = False
        for strategy in strategies:
            ok, msg = _build_one(scripts_dir, stem, strategy)
            if ok:
                compiler = strategy["name"]
                break
            attempts.append("%s: %s" % (strategy["name"], msg))
            # Nur bei einem Compiler-Problem die naechste Strategie probieren.
            # Ein Cython-/Syntax-Fehler in der .pyx scheitert ueberall gleich.
            if not _looks_like_compiler_error(msg):
                break
        if ok:
            state[stem] = h
            built.append(stem)
        else:
            entry = {"file": pyx.name, "message": "\n".join(attempts)[-2000:]}
            if attempts and not ok:
                entry["hint"] = _compiler_hint()
            errors.append(entry)

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
