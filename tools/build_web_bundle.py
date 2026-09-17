#!/usr/bin/env python3
"""Build the Python Bridge web bundle for static hosting.

Creates a deployable folder next to a Godot web export:

  <out>/
  ├── bridge_worker.js          the Pyodide worker (copied from the addon)
  ├── bridge_workspace.tar      virtual filesystem payload (python/, modules/,
  │                             plugins/, packages/ requirements manifest)
  ├── pyodide/                  optional local Pyodide runtime (offline-first;
  │                             CDN is used as fallback when omitted)
  └── bridge-lock.json          resolved versions for reproducible hosting

Strategy (configurable): local-bundle-first + CDN fallback. When --local-packs
is set, the tool pre-downloads pure-python wheels into the workspace's
packages/ folder so imports work without any network; NumPy/SciPy/Pandas are
loaded from the (local or CDN) Pyodide package repository instead - native
wheels cannot be shipped through plain static hosting, Pyodide's repo can.

Examples:
    python tools/build_web_bundle.py --project . --out build/web_bridge
    python tools/build_web_bundle.py --project . --out build/web_bridge \
        --local-pyodide ~/pyodide-0.26.4 --packages numpy,scipy,pandas
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Iterable

DEFAULT_CDN = "https://cdn.jsdelivr.net/pyodide/v0.26.4/full/"
WORKSPACE_DIRS = ("scripts", "modules", "plugins", "packages", "tmp")

# Scientific stack handled through the Pyodide package repository (WASM
# wheels). These names are recognized so the lockfile records them and the
# export check can verify availability.
PYODIDE_SCIENTIFIC = {"numpy", "scipy", "pandas", "matplotlib", "sympy"}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _gather_workspace(project: Path) -> tuple[Path, list[str]]:
    """Collects python sources into a staging dir and returns (staging, log).

    Sources are taken from the project workspace (python_bridge/scripts,
    /modules, /plugins) and the bridge runtime package from the addon. This
    keeps user code and bridge code platform-independent: the SAME files run
    on desktop (real FS) and in the browser (MEMFS).
    """
    staging = Path("_bridge_web_staging")
    if staging.exists():
        shutil.rmtree(staging)
    for d in WORKSPACE_DIRS:
        (staging / d).mkdir(parents=True, exist_ok=True)

    copied = []

    # 1) Bridge runtime package (from the addon, source of truth).
    bridge_src = project / "addons" / "python_bridge" / "python" / "python_bridge"
    dst_bridge = staging / "bridge" / "python_bridge"
    dst_bridge.mkdir(parents=True)
    for py in sorted(bridge_src.glob("*.py")):
        shutil.copy2(py, dst_bridge / py.name)
        copied.append(f"bridge/python_bridge/{py.name}")

    # 2) User workspace folders, if present.
    ws = project / "python_bridge"
    for d in ("scripts", "modules", "plugins"):
        src = ws / d
        if src.is_dir():
            for item in sorted(src.rglob("*")):
                if item.is_dir() or item.suffix == ".pyc" or "__pycache__" in item.parts:
                    continue
                rel = item.relative_to(src)
                target = staging / d / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(item, target)
                copied.append(f"{d}/{rel.as_posix()}")

    # 3) requirements manifest for pure-python packages (browser pip).
    req = ws / "packages" / "requirements.txt"
    if req.is_file():
        shutil.copy2(req, staging / "packages" / "requirements.txt")
        copied.append("packages/requirements.txt")

    return staging, copied


def _make_workspace_tar(staging: Path, out_tar: Path) -> str:
    with tarfile.open(out_tar, "w") as tar:
        for item in sorted(staging.rglob("*")):
            tar.add(item, arcname=item.relative_to(staging).as_posix())
    return _sha256(out_tar)


def _fetch_local_pyodide(src: Path, dst: Path, log: list[str]) -> dict:
    """Copies a local Pyodide distribution (runtime + package repo)."""
    dst.mkdir(parents=True, exist_ok=True)
    essential = [
        "pyodide.js", "pyodide.mjs", "pyodide.asm.js", "pyodide.asm.wasm",
        "python_stdlib.zip", "pyodide-lock.json",
    ]
    copied = []
    for name in essential:
        f = src / name
        if f.is_file():
            shutil.copy2(f, dst / name)
            copied.append(name)
    # Package repo subset requested by the user (numpy/scipy/pandas and deps).
    lock_path = src / "pyodide-lock.json"
    wanted: set[str] = set()
    if lock_path.is_file():
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        packages = lock.get("packages", {})
        def add_with_deps(name: str):
            if name in wanted or name not in packages:
                return
            wanted.add(name)
            for dep in packages[name].get("depends", []):
                add_with_deps(dep)
    # filled later from --packages (see build())
    return {"dst": dst, "copied": copied, "src": src, "wanted": wanted,
            "lock": lock_path if lock_path.is_file() else None, "log": log}


def build(project: Path, out: Path, packages: list[str], local_pyodide: Path | None,
          local_packs: bool, cdn: str) -> int:
    log: list[str] = []
    out.mkdir(parents=True, exist_ok=True)

    # 1) Worker script.
    worker_src = project / "addons" / "python_bridge" / "web" / "bridge_worker.js"
    shutil.copy2(worker_src, out / "bridge_worker.js")
    log.append("copied bridge_worker.js")

    # 2) Workspace bundle (virtual filesystem payload).
    staging, copied = _gather_workspace(project)
    tar_path = out / "bridge_workspace.tar"
    tar_sha = _make_workspace_tar(staging, tar_path)
    log.append(f"workspace tar: {len(copied)} file(s), sha256={tar_sha[:12]}")
    shutil.rmtree(staging, ignore_errors=True)

    # 3) Pyodide runtime: local bundle (preferred) or CDN-only.
    pyodide_info = None
    pyodide_dir = ""
    if local_pyodide and local_pyodide.is_dir():
        pyodide_info = _fetch_local_pyodide(local_pyodide, out / "pyodide", log)
        pyodide_dir = "pyodide"

    # Resolve the scientific stack against the Pyodide repo (local lockfile
    # when available, otherwise the CDN is assumed to serve them).
    scientific = [p for p in packages if p in PYODIDE_SCIENTIFIC]
    pure = [p for p in packages if p not in PYODIDE_SCIENTIFIC]

    if pyodide_info and scientific:
        lock = json.loads(pyodide_info["lock"].read_text(encoding="utf-8"))
        pkgs = lock.get("packages", {})
        wanted: set[str] = set()

        def add_with_deps(name: str):
            name = name.lower()
            if name in wanted or name not in pkgs:
                return
            wanted.add(name)
            for dep in pkgs[name].get("depends", []):
                add_with_deps(dep)

        for name in scientific:
            if name.lower() not in pkgs:
                print(f"WARN: {name} not in local pyodide-lock.json "
                      f"(CDN fallback will fetch it)", file=sys.stderr)
                continue
            add_with_deps(name)
        pkg_dst = out / "pyodide"
        for name in sorted(wanted):
            info = pkgs[name]
            file_name = info.get("file_name")
            if not file_name:
                continue
            src_file = pyodide_info["src"] / file_name
            if src_file.is_file():
                shutil.copy2(src_file, pkg_dst / file_name)
        log.append(f"pyodide packages copied: {len(wanted)} (deps included)")

    # 4) Pure-python wheels for offline pip (optional).
    if local_packs and pure:
        wheels = out / "wheels"
        wheels.mkdir(exist_ok=True)
        try:
            subprocess.run(
                [sys.executable, "-m", "pip", "download", "--dest", str(wheels),
                 "--only-binary=:all:", "--platform", "pyodide",
                 "--implementation", "pyodide", *pure],
                check=False, capture_output=True, text=True)
        except OSError:
            pass
        # pyodide platform wheels come from the pyodide repo; a plain pip
        # download only covers pure-python wheels - that is the documented
        # scope of --local-packs.
        log.append(f"wheels dir created for: {', '.join(pure)}")

    # 5) Lockfile (reproducibility).
    lock_out = {
        "bridge": "0.2.0",
        "pyodide": {
            "source": "local" if pyodide_dir else "cdn",
            "dir": pyodide_dir,
            "cdn": DEFAULT_CDN if not pyodide_dir else "",
        },
        "packages": {"pyodide": scientific, "pure": pure},
        "workspace": {
            "tar": "bridge_workspace.tar",
            "sha256": tar_sha,
            "files": copied,
        },
    }
    (out / "bridge-lock.json").write_text(
        json.dumps(lock_out, indent=2, ensure_ascii=False), encoding="utf-8")
    log.append("wrote bridge-lock.json")

    # 6) README for the deploy step.
    (out / "DEPLOY.md").write_text(
        "# Python Bridge Web-Bundle\n\n"
        "Diese Dateien neben den Godot-Web-Export legen (gleicher Ordner):\n\n"
        "```\n"
        "index.html  <godot web export>\n"
        "bridge_worker.js\n"
        "bridge_workspace.tar\n"
        "pyodide/            (optional, lokal gebuendelt)\n"
        "bridge-lock.json\n"
        "```\n\n"
        "Der Export-Check (`tools/export_check.py --platform web`) verifiziert\n"
        "das Layout. Ohne `pyodide/` laedt der Worker die Runtime vom CDN.\n",
        encoding="utf-8")

    for line in log:
        print("  " + line)
    print(f"Web bundle: {out}")
    return 0


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path("."))
    parser.add_argument("--out", type=Path, default=Path("build/web_bridge"))
    parser.add_argument("--packages", default="numpy",
                        help="comma list, e.g. numpy,scipy,pandas")
    parser.add_argument("--local-pyodide", type=Path, default=None,
                        help="path to an unpacked pyodide distribution")
    parser.add_argument("--local-packs", action="store_true",
                        help="pre-download pure-python wheels for offline use")
    parser.add_argument("--cdn", default=DEFAULT_CDN)
    args = parser.parse_args(list(argv) if argv is not None else None)

    packages = [p.strip().lower() for p in args.packages.split(",") if p.strip()]
    return build(args.project, args.out, packages, args.local_pyodide,
                 args.local_packs, args.cdn)


if __name__ == "__main__":
    raise SystemExit(main())
