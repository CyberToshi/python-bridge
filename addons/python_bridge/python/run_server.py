"""Entry-Point des Python-Servers.

Wird vom Godot-Tool mit der venv-Python ausgeführt:
    venv/python run_server.py --bind 127.0.0.1 --port 0 --tmpdir ... --tag ...
"""
import argparse
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from python_bridge import server  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description="PythonBridge-Server")
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--tmpdir", required=True)
    ap.add_argument("--tag", default="instance")
    args = ap.parse_args()
    asyncio.run(server.run(args.bind, args.port, args.tmpdir, args.tag))


if __name__ == "__main__":
    main()