#!/usr/bin/env python3
"""Check Python Bridge requirements for a Godot export.

The checker is deliberately conservative. Desktop exports can start a local
Python process when Python and the bridge runtime are available outside the
PCK. Web exports cannot start a normal local process; they require an external
Python service reachable over WebSocket.

Examples:
    python tools/export_check.py --project . --platform all
    python tools/export_check.py --project . --platform web --websocket-url wss://host/bridge
    python tools/export_check.py --project . --platform linux --fix
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable

PLATFORMS = ("windows", "linux", "web")
DESKTOP_PLATFORMS = {"windows", "linux"}


@dataclass
class Check:
    name: str
    status: str  # pass, warning, error, info
    message: str
    fixable: bool = False


@dataclass
class Report:
    project: str
    platform: str
    checks: list[Check] = field(default_factory=list)

    @property
    def errors(self) -> int:
        return sum(check.status == "error" for check in self.checks)

    @property
    def warnings(self) -> int:
        return sum(check.status == "warning" for check in self.checks)

    def to_dict(self) -> dict:
        return {
            "project": self.project,
            "platform": self.platform,
            "errors": self.errors,
            "warnings": self.warnings,
            "checks": [asdict(check) for check in self.checks],
        }


def _add(report: Report, name: str, status: str, message: str, fixable=False):
    report.checks.append(Check(name, status, message, fixable))


def _read(project: Path, relative: str) -> str:
    path = project / relative
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return ""


def _runtime_candidates() -> list[str]:
    candidates = []
    configured = os.environ.get("PYTHON_PATH", "").strip()
    if configured:
        candidates.append(configured)
    names = ["python.exe", "python", "python3", "py"] if os.name == "nt" else ["python3", "python"]
    candidates.extend(name for name in names if name not in candidates)
    return candidates


def _find_runtime() -> str | None:
    for candidate in _runtime_candidates():
        path = shutil.which(candidate) if not os.path.isabs(candidate) else candidate
        if path and Path(path).is_file():
            return str(Path(path).resolve())
    return None


def _python_version(runtime: str) -> tuple[int, int] | None:
    """Returns (major, minor) of the runtime, or None when not detectable."""
    try:
        out = subprocess.run(
            [runtime, "--version"], capture_output=True, text=True, timeout=15)
        text = (out.stdout or "") + (out.stderr or "")
        for token in text.replace(",", " ").split():
            if token.count(".") >= 1 and token[0].isdigit():
                parts = token.split(".")
                return int(parts[0]), int(parts[1])
    except (OSError, subprocess.TimeoutExpired, ValueError):
        pass
    return None


def _web_bundle_state(project: Path, bundle_dir: Path) -> dict:
    """Inspects a built web bundle (from tools/build_web_bundle.py)."""
    state = {"dir": str(bundle_dir), "lock": False, "worker": False,
             "tar": False, "local_runtime": False, "packages": []}
    lock_path = bundle_dir / "bridge-lock.json"
    worker = bundle_dir / "bridge_worker.js"
    tar = bundle_dir / "bridge_workspace.tar"
    if not bundle_dir.is_dir():
        for candidate in (project / "build" / "web_bridge",):
            if (candidate / "bridge-lock.json").is_file():
                bundle_dir = candidate
                lock_path = candidate / "bridge-lock.json"
                worker = candidate / "bridge_worker.js"
                tar = candidate / "bridge_workspace.tar"
                state["dir"] = str(candidate)
                break
    if lock_path.is_file():
        state["lock"] = True
        try:
            lock = json.loads(lock_path.read_text(encoding="utf-8"))
            state["packages"] = (lock.get("packages", {}).get("pyodide", []))
            state["local_runtime"] = bool(lock.get("pyodide", {}).get("dir"))
        except (OSError, ValueError):
            pass
    state["worker"] = worker.is_file()
    state["tar"] = tar.is_file()
    state["runtime_files"] = (bundle_dir / "pyodide").is_dir()
    return state


def _preset_platforms(project: Path) -> set[str]:
    text = _read(project, "export_presets.cfg")
    found = set()
    for line in text.splitlines():
        if not line.startswith("platform="):
            continue
        value = line.partition("=")[2].strip().strip('"').lower()
        if "windows" in value:
            found.add("windows")
        elif "linux" in value:
            found.add("linux")
        elif "web" in value:
            found.add("web")
    return found


def _check_common(project: Path, report: Report, fix: bool) -> None:
    required = {
        "project.godot": "Godot project configuration",
        "addons/python_bridge/plugin.cfg": "Godot editor plugin",
        "addons/python_bridge/core/python_bridge.gd": "Bridge facade",
        "addons/python_bridge/python/run_server.py": "Python bridge server",
        "addons/python_bridge/python/python_bridge/server.py": "Python protocol server",
        "addons/python_bridge/python/requirements.txt": "Python runtime requirements",
    }
    for relative, label in required.items():
        if (project / relative).is_file():
            _add(report, relative, "pass", f"{label} found")
        else:
            _add(report, relative, "error", f"{label} is missing")

    project_godot = _read(project, "project.godot")
    if 'PythonBridge="*res://addons/python_bridge/core/python_bridge.gd"' in project_godot:
        _add(report, "autoload", "pass", "PythonBridge autoload is configured")
    else:
        _add(report, "autoload", "warning", "PythonBridge autoload is not declared; enable the plugin before export")

    if 'res://addons/python_bridge/plugin.cfg' in project_godot:
        _add(report, "plugin", "pass", "Python Bridge plugin is enabled")
    else:
        _add(report, "plugin", "warning", "Python Bridge plugin is not enabled in project.godot")

    workspace = project / "python_bridge"
    required_dirs = (workspace / "scripts", workspace / "tmp", workspace / "config")
    missing = [path for path in required_dirs if not path.is_dir()]
    if not missing:
        _add(report, "workspace", "pass", "Bridge workspace directories are present")
    elif fix:
        for path in missing:
            path.mkdir(parents=True, exist_ok=True)
        (workspace / "venv").mkdir(exist_ok=True)
        (workspace / "venv" / ".gdignore").touch(exist_ok=True)
        _add(report, "workspace", "pass", "Created missing source workspace directories")
    else:
        _add(report, "workspace", "warning", "Workspace directories are missing; --fix can create safe source directories", True)


def check_project(project: Path, target: str, websocket_url: str = "", fix: bool = False,
                  web_bundle_dir: str = "build/web_bridge") -> Report:
    project = project.resolve()
    # Bundle-Pfade immer gegen das Projekt aufloesen (nie gegen das CWD):
    # sonst leaken Build-Artefakte des eigenen Repos in fremde Projekte.
    _bundle = Path(web_bundle_dir)
    if not _bundle.is_absolute():
        _bundle = project / _bundle
    web_bundle_dir = str(_bundle)
    report = Report(str(project), target)
    _check_common(project, report, fix)

    targets = PLATFORMS if target == "all" else (target,)
    presets = _preset_platforms(project)
    if presets:
        _add(report, "export_presets", "pass", "Export presets found for: " + ", ".join(sorted(presets)))
    else:
        _add(report, "export_presets", "warning", "No platform export presets found; configure them in Godot before exporting")

    for platform in targets:
        if platform in DESKTOP_PLATFORMS:
            runtime = _find_runtime()
            if runtime:
                _add(report, f"{platform}.python", "pass", f"Python runtime detected: {runtime}")
                version = _python_version(runtime)
                if version is None:
                    _add(report, f"{platform}.version", "warning",
                         "Python version could not be determined (bridge requires 3.8+)")
                elif version < (3, 8):
                    _add(report, f"{platform}.version", "error",
                         f"Python {version[0]}.{version[1]} is too old; the bridge requires 3.8+")
                else:
                    _add(report, f"{platform}.version", "pass",
                         f"Python {version[0]}.{version[1]} satisfies the 3.8+ requirement")
            else:
                _add(report, f"{platform}.python", "error", "No Python runtime detected on the build machine")
            if platform in presets:
                _add(report, f"{platform}.preset", "pass", "Matching export preset is available")
            else:
                _add(report, f"{platform}.preset", "warning", "No matching export preset detected")
            if platform == "linux":
                workspace = project / "python_bridge"
                if workspace.is_dir() and os.access(workspace, os.W_OK):
                    _add(report, "linux.permissions", "pass",
                         "Bridge workspace is writable (venv creation possible)")
                else:
                    _add(report, "linux.permissions", "warning",
                         "Bridge workspace missing or not writable; the bridge creates it at first start")
            else:  # windows
                _add(report, "windows.runtime", "info",
                     "The exported game needs python.exe (or a bundled runtime) next to the "
                     "export at runtime; the bridge finds it via PATH or python_executable")
            _add(report, f"{platform}.runtime", "info",
                 "The exported game needs a Python runtime, a writable workspace, and the "
                 "bridge Python files next to the export (tools/export_check verifies the "
                 "build machine; runtime files are provisioned at first start)")
        else:
            # --- Web: Pyodide transport (default) ------------------------
            if platform in presets:
                _add(report, "web.preset", "pass", "Web export preset is available")
            else:
                _add(report, "web.preset", "warning", "No matching Web export preset detected")

            _add(report, "web.transport", "info",
                 "Python runs in the browser via Pyodide/WebAssembly in a Web Worker "
                 "(virtual filesystem, no server required). Static hosting only.")

            worker_src = project / "addons" / "python_bridge" / "web" / "bridge_worker.js"
            if worker_src.is_file():
                _add(report, "web.worker", "pass", "Pyodide worker script found in the addon")
            else:
                # Tolerant: das Add-on kann auch woanders installiert sein;
                # entscheidend ist das gebaute Bundle, nicht der Quellordner.
                _add(report, "web.worker", "warning",
                     "addons/python_bridge/web/bridge_worker.js not found in this "
                     "project (fine when the addon lives elsewhere)", True)

            bundle = _web_bundle_state(project, Path(web_bundle_dir))
            if bundle["lock"] and bundle["worker"] and bundle["tar"]:
                pkgs = ", ".join(bundle["packages"]) or "none"
                runtime_mode = "local bundle (offline-first)" if bundle["local_runtime"] else "CDN fallback"
                _add(report, "web.bundle", "pass",
                     f"Web bundle present at {bundle['dir']} (packages: {pkgs}; runtime: {runtime_mode})")
            elif fix and worker_src.is_file():
                built = _build_web_bundle(project)
                if built:
                    _add(report, "web.bundle", "pass", "Web bundle was built by --fix (build/web_bridge)")
                else:
                    _add(report, "web.bundle", "warning",
                         "Could not build the web bundle automatically; run tools/build_web_bundle.py", True)
            else:
                _add(report, "web.bundle", "warning",
                     "No web bundle found; run tools/build_web_bundle.py (or --fix) before "
                     "exporting, otherwise the web build has no Python runtime files", True)

            if websocket_url:
                scheme_ok = websocket_url.startswith(("ws://", "wss://"))
                secure = websocket_url.startswith("wss://")
                if scheme_ok:
                    status = "pass" if secure else "warning"
                    message = "External Python WebSocket endpoint configured (optional alternative mode)" + (" (TLS)" if secure else " (ws:// is not encrypted)")
                    _add(report, "web.websocket", status, message)
                else:
                    _add(report, "web.websocket", "error", "WebSocket URL must start with ws:// or wss://")

    return report


def _build_web_bundle(project: Path) -> bool:
    """Builds the web bundle via tools/build_web_bundle.py (used by --fix)."""
    script = project / "tools" / "build_web_bundle.py"
    if not script.is_file():
        return False
    try:
        out = subprocess.run(
            [sys.executable, str(script), "--project", str(project),
             "--out", str(project / "build" / "web_bridge")],
            capture_output=True, text=True, timeout=120)
        return out.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _print_text(report: Report) -> None:
    print(f"Python Bridge export check: {report.project} [{report.platform}]")
    for check in report.checks:
        marker = {"pass": "OK", "warning": "WARN", "error": "ERROR", "info": "INFO"}[check.status]
        suffix = " [fixable]" if check.fixable else ""
        print(f"[{marker:5}] {check.name}: {check.message}{suffix}")
    print(f"Summary: {report.errors} error(s), {report.warnings} warning(s)")


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path("."), help="Godot project root")
    parser.add_argument("--platform", choices=(*PLATFORMS, "all"), default="all")
    parser.add_argument("--websocket-url", default=os.environ.get("PYTHON_BRIDGE_WS_URL", ""))
    parser.add_argument("--fix", action="store_true", help="Create missing safe source workspace directories and build the web bundle when missing")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON")
    parser.add_argument("--web-bundle-dir", default="build/web_bridge",
                        help="web bundle directory to inspect (from tools/build_web_bundle.py)")
    args = parser.parse_args(list(argv) if argv is not None else None)

    report = check_project(args.project, args.platform, args.websocket_url, args.fix,
                           args.web_bundle_dir)
    if args.json:
        print(json.dumps(report.to_dict(), indent=2, ensure_ascii=False))
    else:
        _print_text(report)
    return 1 if report.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
