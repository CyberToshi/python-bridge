"""Entry-Point des Python-Servers.

Wird vom Godot-Tool mit der venv-Python ausgeführt:
    venv/python run_server.py --bind 127.0.0.1 --port 0 --tmpdir ... --tag ...
"""
import argparse
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Workspace-Ordner importierbar machen (Plattform-Parität mit dem Web-Host,
# der dieselben Pfade via browser_host.bootstrap() setzt): `import
# modules.rechner` funktioniert damit auf Desktop und im Browser identisch.
# --tmpdir zeigt auf <workspace>/tmp, der Workspace liegt einen Level höher.
# Beide CLI-Formen unterstuetzen: "--tmpdir x" und "--tmpdir=x".
def _arg_value(name):
    argv = sys.argv
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
        return None
    for a in argv:
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return None


_tmp = _arg_value("--tmpdir")
_tmpdir_parent = Path(_tmp).resolve().parent if _tmp else None
if _tmpdir_parent:
    # Root zuerst: macht `modules`/`plugins` als Namespace-Pakete importierbar
    # (`import modules.rechner`), die Unterordner erlauben direkte Imports
    # (`import rechner`) - identisch zu browser_host.bootstrap() im Web.
    if str(_tmpdir_parent) not in sys.path:
        sys.path.insert(0, str(_tmpdir_parent))
    for _sub in ("modules", "plugins", "packages"):
        _p = _tmpdir_parent / _sub
        if _p.is_dir() and str(_p) not in sys.path:
            sys.path.insert(0, str(_p))
    # Skript-Ordner am ENDE anhängen: macht kompilierte Cython-Module
    # (.so/.pyd aus .pyx) importierbar, ohne Standardpfade zu beschatten.
    _scripts_dir = _tmpdir_parent / "scripts"
    if _scripts_dir.is_dir() and str(_scripts_dir) not in sys.path:
        sys.path.append(str(_scripts_dir))

from python_bridge import server  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description="PythonBridge-Server")
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--tmpdir", required=True)
    ap.add_argument("--tag", default="instance")
    ap.add_argument("--max-stdout-bytes", type=int, default=0)
    ap.add_argument("--max-stderr-bytes", type=int, default=0)
    ap.add_argument("--max-result-bytes", type=int, default=0)
    ap.add_argument("--data-ref-threshold-bytes", type=int, default=0)
    ap.add_argument("--workers", type=int, default=0)
    ap.add_argument("--runaway-grace-ms", type=int, default=0)
    args = ap.parse_args()
    caps = {}
    if args.max_stdout_bytes > 0:
        caps["max_stdout_bytes"] = args.max_stdout_bytes
    if args.max_stderr_bytes > 0:
        caps["max_stderr_bytes"] = args.max_stderr_bytes
    if args.max_result_bytes > 0:
        caps["max_result_bytes"] = args.max_result_bytes
    if args.data_ref_threshold_bytes > 0:
        caps["data_ref_threshold_bytes"] = args.data_ref_threshold_bytes
    if args.workers > 0:
        caps["workers_per_instance"] = args.workers
    if args.runaway_grace_ms > 0:
        caps["runaway_grace_ms"] = args.runaway_grace_ms
    asyncio.run(server.run(args.bind, args.port, args.tmpdir, args.tag, caps))


if __name__ == "__main__":
    main()