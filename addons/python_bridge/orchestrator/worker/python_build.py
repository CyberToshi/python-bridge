#!/usr/bin/env python3
"""Umgebungs- und Build-Verwaltung des Workers ("Plug & Play").

Dieses Modul kapselt **alles**, was ein Python-Projekt an Vorbereitung braucht,
damit der Benutzer niemals `pip`, `cython`, `setup.py` oder einen Compiler von
Hand aufrufen muss:

    .py             -> wird direkt ausgefuehrt (kein Build, keine venv)
    requirements.txt-> isolierte venv + automatisches `pip install`
    .pyx / setup.py -> zusaetzlich: Cython + Compiler bereitstellen, kompilieren

Die Idee ist bewusst allgemein gehalten: "Projekt braucht einen Build-Schritt".
Cython ist der erste Fall davon; weitere native Extensions koennen spaeter
denselben Weg nehmen (setup.py/pyproject.toml werden respektiert).

Eigenschaften:

* **Keine Systemveraenderung.** Alles landet im Cache-Verzeichnis des Workers
  (`--cache-dir` bzw. Benutzer-Cache). Keine Adminrechte noetig.
* **Kein Terminal.** Jede Aktion, die schiefgeht, liefert eine verstaendliche
  Meldung samt Hinweis und - wo moeglich - eine automatische Loesung
  (z. B. Rueckfall auf `--system-site-packages`, wenn pip das Netz nicht
  erreicht, aber die Pakete bereits vorhanden sind).
* **Build-Cache.** Ein Projekt wird nur neu gebaut, wenn sich `.pyx`/Quellen,
  Requirements, Python-Version oder Plattform/Architektur aendern.

Cache-Layout:

    <cache>/envs/<envkey>/        isolierte venv inkl. Cython/Compiler-Tools
    <cache>/projects/<projkey>/   Projektdateien + kompilierte Artefakte
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import sysconfig
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Mapping, Sequence

# ---------------------------------------------------------------------------
# Grenzen / Version
# ---------------------------------------------------------------------------

# Wird erhoeht, wenn sich die Buildlogik aendert: dann wird neu gebaut.
BUILD_SCHEMA = 1

MAX_PROJECT_FILES = 512
MAX_FILE_BYTES = 4 * 1024 * 1024            # pro Datei
MAX_TOTAL_BYTES = 32 * 1024 * 1024          # gesamtes Projekt
MAX_REQUIREMENTS_BYTES = 64 * 1024

# Pakete, die fuer einen Cython-Build bereitstehen muessen.
BUILD_TOOL_PACKAGES = ("cython", "setuptools", "wheel")

# Verzeichnisse/Dateien, die nie mit ins Projekt gehoeren.
IGNORED_DIR_NAMES = {
    "__pycache__", ".git", ".hg", ".svn", "venv", ".venv", "env", "build",
    "dist", "node_modules", ".mypy_cache", ".pytest_cache", ".godot",
    ".idea", ".vscode", "site-packages",
}
IGNORED_SUFFIXES = {
    ".pyc", ".pyo", ".so", ".pyd", ".dll", ".dylib", ".o", ".a", ".obj",
    ".exe", ".zip", ".png", ".jpg", ".jpeg", ".gif", ".pdf", ".whl",
}

# Textdateien, die ein Projekt sinnvoll ausmachen.
PROJECT_FILE_SUFFIXES = {
    ".py", ".pyx", ".pxd", ".pxi", ".txt", ".toml", ".cfg", ".ini", ".json",
    ".c", ".h", ".cpp", ".cc", ".hpp", ".md", ".rst", ".yaml", ".yml",
}

# Dateien, die den Build ausloesen.
BUILD_TRIGGER_SUFFIXES = {".pyx", ".pxd"}
BUILD_SCRIPTS = ("setup.py", "pyproject.toml", "setup.cfg")


class BuildError(RuntimeError):
    """Fehler mit verstaendlicher Erklaerung und optionaler Loesung.

    `message`  - was schiefging (kurz, fuer den Benutzer)
    `hint`     - warum/was zu tun ist
    `action`   - Maschinenlesbarer Vorschlag, z. B. "install_compiler"
    `detail`   - technischer Auszug (Compiler-/pip-Ausgabe), fuer das Log
    `stage`    - "detect" | "env" | "deps" | "build" | "run"
    """

    def __init__(self, message: str, *, hint: str = "", action: str = "",
                 detail: str = "", stage: str = "build") -> None:
        super().__init__(message)
        self.message = message
        self.hint = hint
        self.action = action
        self.detail = detail
        self.stage = stage

    def as_dict(self) -> dict:
        return {
            "message": self.message,
            "hint": self.hint,
            "action": self.action,
            "detail": self.detail,
            "stage": self.stage,
        }


# ---------------------------------------------------------------------------
# Umgebung erkennen
# ---------------------------------------------------------------------------

def default_cache_root() -> Path:
    """Plattformueblicher, **persistenter** Cache-Ort (nicht Temp!)."""
    override = os.environ.get("PYTHON_BRIDGE_WORKER_CACHE", "").strip()
    if override:
        return Path(override).expanduser()
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
        if base:
            return Path(base) / "python_bridge_worker" / "cache"
    elif sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "python_bridge_worker"
    else:
        base = os.environ.get("XDG_CACHE_HOME", "").strip()
        if base:
            return Path(base) / "python_bridge_worker"
        return Path.home() / ".cache" / "python_bridge_worker"
    return Path(tempfile_fallback()) / "python_bridge_worker" / "cache"


def tempfile_fallback() -> str:
    import tempfile
    return tempfile.gettempdir()


def find_compiler() -> str:
    """Sucht einen C-Compiler. Leerer String = keiner gefunden."""
    candidates: Sequence[str]
    if os.name == "nt":
        candidates = ("cl", "gcc", "clang", "clang-cl", "tcc")
    else:
        candidates = ("cc", "gcc", "clang", "c99", "tcc")
    for name in candidates:
        found = shutil.which(name)
        if found:
            return name
    # sysconfig kann einen Compiler kennen, auch wenn er nicht im PATH liegt.
    configured = (sysconfig.get_config_var("CC") or "").split()
    if configured and shutil.which(configured[0]):
        return configured[0]
    return ""


def venv_python(env_dir: Path) -> Path:
    if os.name == "nt":
        return env_dir / "Scripts" / "python.exe"
    return env_dir / "bin" / "python"


@dataclass(frozen=True)
class EnvInfo:
    """Erkannter Zustand des Worker-Rechners."""

    python_version: str
    implementation: str
    system: str
    machine: str
    compiler: str
    cache_root: Path
    venv_available: bool
    pip_available: bool

    def signature(self) -> str:
        """Alles, was ein Build-Artefakt ungueltig macht."""
        return "|".join([
            f"schema{BUILD_SCHEMA}",
            self.python_version,
            self.implementation,
            self.system,
            self.machine,
        ])

    def describe(self) -> dict:
        return {
            "python": self.python_version,
            "implementation": self.implementation,
            "os": self.system,
            "arch": self.machine,
            "compiler": self.compiler or "",
            "cache": str(self.cache_root),
            "venv": self.venv_available,
            "pip": self.pip_available,
        }


def _module_available(python: str, module: str) -> bool:
    try:
        result = subprocess.run(
            [python, "-c", f"import {module}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30,
            creationflags=_no_window_flags())
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def _no_window_flags() -> int:
    if os.name == "nt":
        return getattr(subprocess, "CREATE_NO_WINDOW", 0)
    return 0


def detect_env(base_python: str | None = None, cache_root: Path | None = None) -> EnvInfo:
    python = base_python or sys.executable
    version = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    return EnvInfo(
        python_version=version,
        implementation=platform.python_implementation().lower(),
        system=sys.platform,
        machine=platform.machine().lower(),
        compiler=find_compiler(),
        cache_root=(cache_root or default_cache_root()).expanduser(),
        venv_available=_module_available(python, "venv"),
        pip_available=_module_available(python, "pip"),
    )


# ---------------------------------------------------------------------------
# Projektdateien: Validierung, Hashing, Sammeln
# ---------------------------------------------------------------------------

def validate_project(files: Mapping[str, str]) -> dict:
    """Prueft Dateinamen/-groessen und liefert die bereinigte Dateiliste.

    Wirft BuildError bei: Pfad-Traversal, absoluten Pfaden, zu vielen/zu
    grossen Dateien.
    """
    if not isinstance(files, Mapping) or not files:
        raise BuildError("Kein Projektinhalt uebermittelt.",
                         hint="Die Aufgabe enthaelt keine Dateien.",
                         stage="run")
    if len(files) > MAX_PROJECT_FILES:
        raise BuildError(
            f"Projekt zu gross: {len(files)} Dateien (max. {MAX_PROJECT_FILES}).",
            hint="Bitte nur die tatsaechlich benoetigten Dateien senden.",
            stage="run")
    cleaned: dict[str, str] = {}
    total = 0
    for raw_name, raw_text in files.items():
        name = str(raw_name).replace("\\", "/").strip("/")
        if name == "" or name.startswith("../") or "/../" in name or name.startswith("/"):
            raise BuildError(f"Ungueltiger Dateiname: {raw_name!r}",
                             hint="Dateipfade innerhalb des Projekts sind erlaubt, "
                                  "aber keine Ausbrueche aus dem Projektordner.",
                             stage="run")
        if os.path.isabs(name) or ":" in name.split("/")[0]:
            raise BuildError(f"Ungueltiger Dateiname: {raw_name!r}",
                             hint="Absolute Pfade sind nicht erlaubt.", stage="run")
        text = raw_text if isinstance(raw_text, str) else json.dumps(raw_text)
        size = len(text.encode("utf-8", "replace"))
        if size > MAX_FILE_BYTES:
            raise BuildError(
                f"Datei {name} ist zu gross ({size // 1024} KB, max. "
                f"{MAX_FILE_BYTES // 1024} KB).",
                hint="Grosse Dateien gehoeren nicht in den Quelltext-Transfer.",
                stage="run")
        total += size
        if total > MAX_TOTAL_BYTES:
            raise BuildError("Projekt insgesamt zu gross.",
                             hint="Bitte die Dateien im Projekt reduzieren.",
                             stage="run")
        cleaned[name] = text
    return cleaned


def needs_build(files: Mapping[str, str], build_mode: str = "auto") -> bool:
    """Ob ein Build-Schritt noetig ist (Cython/native Extension)."""
    if build_mode == "none":
        return False
    if any(Path(name).suffix.lower() in BUILD_TRIGGER_SUFFIXES for name in files):
        return True
    if build_mode == "force":
        return True
    return any(Path(name).name in BUILD_SCRIPTS for name in files)


def content_key(files: Mapping[str, str], requirements: str, build_mode: str,
                env: EnvInfo) -> str:
    """Fingerabdruck des Projekts - aendert sich genau dann, wenn neu gebaut
    werden muss (Quellen, Requirements, Umgebung, Build-Modus)."""
    digest = hashlib.sha256()
    digest.update(env.signature().encode())
    digest.update(f"|build={build_mode}".encode())
    for name in sorted(files):
        digest.update(b"\0f\0")
        digest.update(name.encode())
        digest.update(b"\0")
        digest.update(files[name].encode("utf-8", "replace"))
    digest.update(b"\0r\0")
    digest.update(normalize_requirements(requirements).encode())
    return digest.hexdigest()[:32]


def normalize_requirements(requirements: str) -> str:
    """Requirements vereinheitlichen (Kommentare/Leerzeilen raus, sortiert).

    Dadurch loest eine reine Umsortierung keinen Neu-Build aus.
    """
    if not requirements:
        return ""
    lines = []
    for line in str(requirements).splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            lines.append(line)
    return "\n".join(sorted(lines))


def collect_project_dir(root: str | Path) -> dict:
    """Liest einen lokalen Projektordner ein (fuer den Manager).

    Nur Textdateien mit sinnvoller Endung; Build-/Cache-Ordner werden
    uebersprungen. Liefert {"files": {...}, "requirements": "...", "entry": "..."}.
    """
    base = Path(root).expanduser().resolve()
    if not base.is_dir():
        raise BuildError(f"Ordner nicht gefunden: {base}", stage="run")
    files: dict[str, str] = {}
    requirements = ""
    total = 0
    for path in sorted(base.rglob("*")):
        if any(part in IGNORED_DIR_NAMES for part in path.relative_to(base).parts):
            continue
        if not path.is_file():
            continue
        if path.suffix.lower() in IGNORED_SUFFIXES:
            continue
        if path.suffix.lower() not in PROJECT_FILE_SUFFIXES:
            continue
        if len(files) >= MAX_PROJECT_FILES:
            break
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if len(text.encode("utf-8", "replace")) > MAX_FILE_BYTES:
            continue
        total += len(text)
        if total > MAX_TOTAL_BYTES:
            break
        rel = path.relative_to(base).as_posix()
        files[rel] = text
        if rel in ("requirements.txt", "Requirements.txt"):
            requirements = text
    entry = ""
    for candidate in ("main.py", "app.py", "run.py", "start.py"):
        if candidate in files:
            entry = candidate
            break
    if entry == "":
        top = [name for name in sorted(files) if "/" not in name and name.endswith(".py")]
        if top:
            entry = top[0]
    return {"files": files, "requirements": requirements, "entry": entry}


# ---------------------------------------------------------------------------
# Vorbereitung: venv + Pakete + Build
# ---------------------------------------------------------------------------

@dataclass
class Prepared:
    """Ergebnis der Vorbereitung."""

    project_dir: Path
    python: str
    key: str
    cached: bool = False
    built: bool = False
    used_env: bool = False
    env_dir: Path | None = None
    notes: list[str] = field(default_factory=list)
    timings: dict = field(default_factory=dict)

    def describe(self) -> dict:
        return {
            "key": self.key,
            "cached": self.cached,
            "built": self.built,
            "venv": str(self.env_dir) if self.env_dir else "",
            "notes": list(self.notes),
            "timings": dict(self.timings),
        }


ProgressCB = Callable[[str, float, str], None]


class ProjectBuilder:
    """Bereitet Projekte vor: Dateien, Umgebung, Build, Cache."""

    def __init__(self, env: EnvInfo, base_python: str | None = None,
                 log: Callable[[str], None] | None = None,
                 auto_install: bool = True,
                 build_timeout_s: float = 600.0,
                 pip_timeout_s: float = 900.0) -> None:
        self.env = env
        self.base_python = base_python or sys.executable
        self.log = log or (lambda _text: None)
        self.auto_install = auto_install
        self.build_timeout_s = build_timeout_s
        self.pip_timeout_s = pip_timeout_s

    # -------------------------------------------------------------- öffentlich
    def prepare(self, files: Mapping[str, str], requirements: str = "",
                build_mode: str = "auto", emit: ProgressCB | None = None
                ) -> Prepared:
        progress = emit or (lambda _s, _f, _t: None)
        cleaned = validate_project(files)
        requirements = (requirements or "").strip()
        if len(requirements.encode("utf-8", "replace")) > MAX_REQUIREMENTS_BYTES:
            raise BuildError("requirements.txt ist zu gross.",
                             hint="Nur die wirklich benoetigten Pakete eintragen.",
                             stage="deps")
        must_build = needs_build(cleaned, build_mode)
        key = content_key(cleaned, requirements, build_mode, self.env)
        project_dir = self.env.cache_root / "projects" / key

        # --- Build-Cache: identischer Fingerabdruck => nichts zu tun ---------
        marker = self._read_marker(project_dir, key, cleaned)
        if marker is not None:
            python, env_dir = self._reuse_env(marker)
            progress("cache", 1.0, "Build-Cache verwendet")
            self.log(f"Build-Cache verwendet ({key})")
            return Prepared(project_dir=project_dir, python=python, key=key,
                            cached=True, built=bool(marker.get("built", False)),
                            used_env=env_dir is not None, env_dir=env_dir)

        started = time.monotonic()
        self._write_project(project_dir, cleaned)
        self.log(f"Projekt vorbereitet ({key}, {len(cleaned)} Dateien)")

        notes: list[str] = []
        env_dir: Path | None = None
        python = self.base_python
        used_env = False
        need_env = bool(requirements) or must_build

        if need_env:
            progress("env", 0.1, "Python-Umgebung vorbereiten")
            env_dir, python, env_notes = self._ensure_env(requirements, must_build)
            notes.extend(env_notes)
            used_env = True

        built = False
        if must_build:
            progress("build", 0.5, "Projekt kompilieren")
            self._build(project_dir, python, cleaned, notes)
            built = True

        # Erst jetzt den Cache als gueltig markieren: bricht der Build ab,
        # wird beim naechsten Mal sauber neu gebaut.
        self._mark_cache(project_dir, key, {"built": built, "env": str(env_dir or "")})
        progress("ready", 1.0, "Vorbereitung abgeschlossen")
        return Prepared(
            project_dir=project_dir, python=python, key=key, cached=False,
            built=built, used_env=used_env, env_dir=env_dir, notes=notes,
            timings={"prepare_ms": int((time.monotonic() - started) * 1000)},
        )

    def clean(self, max_projects: int = 64, max_age_days: int = 14) -> dict:
        """Raeumt den Cache auf: aelteste Projekte zuerst.

        Einfach gehalten: Projekte ueber der Anzahl bzw. aelter als die Frist
        werden geloescht. Der Cache waechst damit nicht unbegrenzt.
        """
        removed = 0
        projects = self.env.cache_root / "projects"
        if projects.is_dir():
            entries = sorted(
                ((p.stat().st_mtime, p) for p in projects.iterdir() if p.is_dir()),
                key=lambda item: item[0])
            deadline = time.time() - max_age_days * 86400
            for index, (mtime, path) in enumerate(entries):
                too_old = mtime < deadline
                too_many = len(entries) - index > max_projects
                if too_old or too_many:
                    shutil.rmtree(path, ignore_errors=True)
                    removed += 1
        envs_removed = 0
        envs = self.env.cache_root / "envs"
        if envs.is_dir():
            deadline = time.time() - max_age_days * 3 * 86400
            for path in envs.iterdir():
                try:
                    if path.is_dir() and path.stat().st_mtime < deadline:
                        shutil.rmtree(path, ignore_errors=True)
                        envs_removed += 1
                except OSError:
                    continue
        return {"projects_removed": removed, "envs_removed": envs_removed}

    def diagnose(self, requirements: str = "", build_required: bool = False) -> dict:
        """Klartext-Bericht fuer die GUI: was fehlt, was automatisch passiert."""
        info = self.env.describe()
        info["build_required"] = bool(build_required)
        info["requirements"] = normalize_requirements(requirements)
        problems: list[dict] = []
        if not self.env.pip_available:
            problems.append({
                "text": "pip fehlt im Worker-Python",
                "hint": "Ohne pip koennen Abhaengigkeiten nicht automatisch "
                        "installiert werden.",
                "action": "repair_python",
            })
        if not self.env.venv_available:
            problems.append({
                "text": "venv fehlt im Worker-Python",
                "hint": "Isolierte Umgebungen sind nicht anlegbar; es wird das "
                        "Worker-Python direkt benutzt.",
                "action": "repair_python",
            })
        if build_required and not self.env.compiler:
            problems.append({
                "text": "Kein C-Compiler gefunden",
                "hint": "Cython/native Extensions brauchen einen C-Compiler. "
                        "Windows: 'Microsoft C++ Build Tools' installieren. "
                        "Linux: build-essential bzw. gcc (meist per Paketmanager).",
                "action": "install_compiler",
            })
        info["problems"] = problems
        info["ready"] = not problems
        return info

    # -------------------------------------------------------------- intern
    @staticmethod
    def _read_marker(project_dir: Path, key: str,
                     files: Mapping[str, str]) -> dict | None:
        """Gueltigen Cache-Marker lesen (None = Cache unbrauchbar)."""
        marker = project_dir / ".pbr_ok"
        if not marker.is_file():
            return None
        try:
            data = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        if not isinstance(data, dict) or data.get("key") != key:
            return None
        if not data.get("complete", True):
            return None
        # Dateien pruefen: ein geloeschter/veraenderter Cache ist kein Cache.
        for name in files:
            if not (project_dir / name).is_file():
                return None
        # Wurde die Umgebung weggeraeumt, ist der Build nicht mehr nutzbar.
        env = str(data.get("env", ""))
        if env and not venv_python(Path(env)).is_file():
            return None
        return data


    def _reuse_env(self, marker: Mapping) -> tuple[str, Path | None]:
        env = str(marker.get("env", ""))
        if not env:
            return self.base_python, None
        env_dir = Path(env)
        python = venv_python(env_dir)
        if python.is_file():
            return str(python), env_dir
        return self.base_python, None

    def _mark_cache(self, project_dir: Path, key: str, extra: dict) -> None:
        payload = {"key": key, "schema": BUILD_SCHEMA, "at": int(time.time()),
                   "complete": True}
        payload.update(extra)
        try:
            (project_dir / ".pbr_ok").write_text(json.dumps(payload),
                                                 encoding="utf-8")
        except OSError as exc:
            self.log(f"Cache-Marker nicht schreibbar: {exc}")

    def _write_project(self, project_dir: Path, files: Mapping[str, str]) -> None:
        try:
            if project_dir.exists():
                shutil.rmtree(project_dir, ignore_errors=True)
            project_dir.mkdir(parents=True, exist_ok=True)
            for name, text in files.items():
                target = project_dir / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text, encoding="utf-8")
        except OSError as exc:
            raise BuildError("Projektordner konnte nicht geschrieben werden.",
                             hint="Schreibrechte im Cache-Verzeichnis pruefen "
                                  "(oder --cache-dir auf einen beschreibbaren Ort setzen).",
                             detail=str(exc), stage="env") from None

    # --- Umgebung ---------------------------------------------------------
    def _env_key(self, requirements: str, must_build: bool) -> str:
        digest = hashlib.sha256()
        digest.update(self.env.signature().encode())
        digest.update(b"|" + normalize_requirements(requirements).encode())
        if must_build:
            digest.update(b"|tools:" + ",".join(BUILD_TOOL_PACKAGES).encode())
        return digest.hexdigest()[:24]

    def _ensure_env(self, requirements: str, must_build: bool
                    ) -> tuple[Path, str, list[str]]:
        notes: list[str] = []
        env_dir = self.env.cache_root / "envs" / self._env_key(requirements, must_build)
        python = venv_python(env_dir)

        if not python.is_file():
            if not self.env.venv_available:
                # Kein venv-Modul: dann eben ohne Isolation arbeiten.
                notes.append("kein venv verfuegbar - Worker-Python wird direkt benutzt")
                self._install_packages(self.base_python, requirements, must_build, notes)
                return self.env.cache_root, self.base_python, notes
            env_dir.parent.mkdir(parents=True, exist_ok=True)
            self._run([self.base_python, "-m", "venv", "--system-site-packages",
                       str(env_dir)],
                      stage="env",
                      error_message="Python-Umgebung (venv) konnte nicht angelegt werden.",
                      hint="Falls das Systempaket fehlt: unter Linux 'python3-venv', "
                           "unter Windows die Python-Installation reparieren "
                           "(im Installer 'pip' und 'venv' aktivieren).")
            notes.append("isolierte Umgebung angelegt")

        marker = env_dir / ".pbr_packages.json"
        want = {"key": self._env_key(requirements, must_build)}
        have: dict = {}
        if marker.is_file():
            try:
                have = json.loads(marker.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                have = {}
        if have.get("key") != want["key"]:
            self._install_packages(python, requirements, must_build, notes)
            try:
                marker.write_text(json.dumps(want), encoding="utf-8")
            except OSError:
                pass
        else:
            notes.append("Abhaengigkeiten bereits installiert")
        return env_dir, str(python), notes

    def _install_packages(self, python: str, requirements: str, must_build: bool,
                          notes: list[str]) -> None:
        if not self.auto_install:
            notes.append("automatische Installation ist abgeschaltet (--no-auto-install)")
            return
        if not requirements and not must_build:
            return
        base_cmd = [python, "-m", "pip", "install", "--disable-pip-version-check",
                    "--no-input"]
        if must_build:
            self._pip(base_cmd, list(BUILD_TOOL_PACKAGES), "Build-Werkzeuge",
                      notes, required=True)
        if requirements:
            req_path = self.env.cache_root / "requirements.in"
            try:
                req_path.parent.mkdir(parents=True, exist_ok=True)
                req_path.write_text(requirements + "\n", encoding="utf-8")
            except OSError as exc:
                raise BuildError("requirements.txt konnte nicht abgelegt werden.",
                                 detail=str(exc), stage="deps") from None
            self._pip(base_cmd, ["-r", str(req_path)], "Projekt-Abhaengigkeiten",
                      notes, required=True)

    def _pip(self, base_cmd: list[str], extra: Iterable[str], what: str,
             notes: list[str], required: bool) -> None:
        try:
            self._run(base_cmd + list(extra), stage="deps",
                      error_message=f"{what} konnten nicht installiert werden.",
                      hint="Der Worker versucht die Installation selbst. Wenn "
                           "pip das Netz nicht erreicht: Internet/Proxy auf dem "
                           "Worker-Rechner pruefen (die Pakete werden im "
                           "Worker-Cache abgelegt, nicht im System).",
                      quiet=True)
            notes.append(f"{what} installiert")
        except BuildError as exc:
            if required:
                raise
            notes.append(f"{what} nicht installierbar: {exc.message}")

    # --- Build ------------------------------------------------------------
    def _build(self, project_dir: Path, python: str, files: Mapping[str, str],
               notes: list[str]) -> None:
        if not self.env.compiler:
            raise BuildError(
                "Kein C-Compiler gefunden - das Projekt kann nicht kompiliert werden.",
                hint="Windows: 'Microsoft C++ Build Tools' installieren "
                     "(kostenlos, kein Admin noetig). Linux: Paket 'build-essential' "
                     "bzw. 'gcc' nachinstallieren. Danach die Aufgabe einfach erneut starten.",
                action="install_compiler",
                stage="build")

        setup_script, targets = self._setup_script(project_dir, files)
        command = [python, str(setup_script), "build_ext", "--inplace"]
        self.log("Baue Projekt: " + " ".join(command))
        try:
            self._run(command, stage="build", cwd=project_dir,
                      error_message="Der Build ist fehlgeschlagen.",
                      hint="Die Compiler-Ausgabe steht im Protokoll (Feld stderr). "
                           "Haeufig: fehlende pyx-Imports oder fehlerhafter "
                           "Cython-Code.",
                      timeout=self.build_timeout_s, quiet=True)
        except BuildError as exc:
            raise BuildError(
                exc.message,
                hint=exc.hint,
                action=exc.action,
                detail=_tail(exc.detail, 4000),
                stage="build") from None

        module_names = {Path(name).stem for name in targets}
        missing = sorted(self._missing_modules(project_dir, module_names))
        if missing:
            raise BuildError(
                "Build lief durch, aber es wurde keine Erweiterung erzeugt: "
                + ", ".join(missing),
                hint="Cython hat keine ausfuehrbare Datei erzeugt. 'setup.py' bzw. "
                     "die Extension-Definitionen pruefen.",
                detail=str(list(project_dir.glob("*.c"))[:10]),
                stage="build")
        notes.append(f"{len(module_names)} Erweiterung(en) kompiliert")

    def _setup_script(self, project_dir: Path,
                      files: Mapping[str, str]) -> tuple[Path, list[str]]:
        """Build-Skript bestimmen: Projekt-eigenes bevorzugt, sonst erzeugen."""
        for name in BUILD_SCRIPTS:
            if name in files and name == "setup.py":
                return project_dir / name, self._cython_targets(files)
        if "pyproject.toml" in files or "setup.cfg" in files:
            # Projekt bringt seine eigene Build-Konfiguration mit: ein
            # ebenso einfacher wie robuster Weg ist der Inplace-Build.
            generated = project_dir / "_pbr_setup.py"
            generated.write_text(
                "from setuptools import setup\n"
                "setup()\n", encoding="utf-8")
            return generated, self._cython_targets(files)
        targets = self._cython_targets(files)
        if not targets:
            raise BuildError("Kein Build-Ziel gefunden.",
                             hint="Fuer einen Build wird eine .pyx-Datei oder ein "
                                  "setup.py erwartet.",
                             stage="build")
        generated = project_dir / "_pbr_setup.py"
        extensions = "\n".join(
            f'    Extension({_module_name(name)!r}, [{name!r}]),' for name in targets)
        generated.write_text(
            "from setuptools import Extension, setup\n"
            "from Cython.Build import cythonize\n\n"
            "SETUP = dict(\n"
            "    ext_modules=cythonize([\n" + extensions + "\n"
            "    ], language_level=3),\n"
            ")\n"
            "setup(**SETUP)\n", encoding="utf-8")
        return generated, targets

    @staticmethod
    def _cython_targets(files: Mapping[str, str]) -> list[str]:
        return sorted(name for name in files
                      if Path(name).suffix.lower() in BUILD_TRIGGER_SUFFIXES
                      and Path(name).suffix.lower() == ".pyx")

    @staticmethod
    def _missing_modules(project_dir: Path, names: Iterable[str]) -> set[str]:
        missing = set()
        for name in names:
            found = False
            for pattern in (f"{name}*.so", f"{name}*.pyd", f"{name}*.dylib",
                            f"{name}/__init__*.so", f"{name}/__init__*.pyd"):
                if list(project_dir.rglob(pattern)):
                    found = True
                    break
            if not found:
                missing.add(name)
        return missing

    # --- Prozess-Ausfuehrung ----------------------------------------------
    def _run(self, command: Sequence[str], *, stage: str, cwd: Path | None = None,
             error_message: str = "Befehl fehlgeschlagen.", hint: str = "",
             timeout: float | None = None, quiet: bool = False) -> str:
        try:
            result = subprocess.run(
                list(command), cwd=str(cwd) if cwd else None,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=timeout or self.pip_timeout_s,
                creationflags=_no_window_flags())
        except FileNotFoundError as exc:
            raise BuildError(f"{error_message} (Programm nicht gefunden)",
                             hint=hint or "Der Aufruf ist auf diesem Rechner nicht "
                                          "verfuegbar.",
                             detail=str(exc), stage=stage) from None
        except subprocess.TimeoutExpired as exc:
            raise BuildError(
                f"{error_message} (Zeitueberschreitung nach "
                f"{int(timeout or self.pip_timeout_s)} s)",
                hint=hint, detail=str(exc), stage=stage) from None
        output = (result.stdout or b"").decode("utf-8", "replace")
        if not quiet and output.strip():
            self.log(output.strip()[-2000:])
        if result.returncode != 0:
            raise BuildError(
                error_message, hint=hint or "Ausgabe siehe Detail.",
                detail=output, stage=stage)
        return output


def _module_name(path: str) -> str:
    """'pkg/fast.pyx' -> 'pkg.fast' (Paketpfad fuer Extension-Namen)."""
    stem = Path(path).with_suffix("")
    return ".".join(stem.parts)


def _tail(text: str, limit: int) -> str:
    if not text or len(text) <= limit:
        return text or ""
    return text[-limit:]


def diagnose_report(base_python: str | None = None,
                    cache_root: Path | None = None,
                    requirements: str = "",
                    build_required: bool = False) -> dict:
    """Sammelbericht fuer die Worker-App (Button 'Umgebung pruefen')."""
    env = detect_env(base_python, cache_root)
    builder = ProjectBuilder(env, base_python)
    return builder.diagnose(requirements, build_required)
