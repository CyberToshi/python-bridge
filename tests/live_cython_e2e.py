"""Live-E2E: Cython-Sonderpfad gegen einen echten Server-Prozess.

Portabel (Windows/Linux/macOS) - kein hartkodierter Pfad, keine Annahme ueber
einen fremden Rechner. Der Build wird hier frisch gemacht, damit genau die
Kette geprueft wird, die ein Nutzer auch geht:

  1. ``cython_build.py`` kompiliert ``scripts/mathx.pyx`` -> ``.so``/``.pyd``
     (Compiler-Strategie: MSVC/mingw32 auf Windows, gcc/zig auf POSIX).
  2. Ein echter ``run_server.py`` startet mit ``--tmpdir <ws>/tmp``; sein
     Workspace-Root ist ``<ws>``, ``scripts/`` liegt damit auf ``sys.path``.
  3. ``call`` auf den Kontext ``cython:<pfad>/mathx.pyx`` importiert das
     kompilierte Modul (kein Cython-Quelltext wird ausgefuehrt).
  4. Der zweite Call nutzt denselben persistenten Kontext.
  5. Ein ``cython:``-Kontext ohne kompiliertes Modul liefert einen
     strukturierten ``CythonModuleNotFound``-Fehler statt eines Crashes.

Voraussetzungen: ``websockets`` und ``Cython``/``setuptools`` in der laufenden
Python-Umgebung, plus ein C-Compiler (siehe ``python -m cython_build``-Report).

Aufruf::

    python tests/live_cython_e2e.py
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
PY_DIR = REPO / "addons" / "python_bridge" / "python"
BUILD_TOOL = PY_DIR / "cython_build.py"
RUN_SERVER = PY_DIR / "run_server.py"

sys.path.insert(0, str(PY_DIR))

RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, cond: bool, detail: str = "") -> bool:
    RESULTS.append((name, bool(cond), detail))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name,
                           (" -> " + detail) if detail else ""))
    return bool(cond)


def _optional(name: str):
    try:
        return __import__(name)
    except ImportError:
        return None


def build(scripts_dir: Path) -> dict:
    """Ruft das Build-Tool wie die GDScript-Seite (gleiche CLI)."""
    proc = subprocess.run(
        [sys.executable, str(BUILD_TOOL), "--scripts-dir", str(scripts_dir)],
        capture_output=True, text=True, timeout=900)
    for line in reversed((proc.stdout or "").strip().splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except ValueError:
                continue
    return {"ok": False, "error": "kein JSON-Report",
            "stdout": (proc.stdout or "")[-1500:], "stderr": (proc.stderr or "")[-1500:]}


def wait_port_file(tmpdir: Path, tag: str, timeout: float = 40.0) -> dict | None:
    path = tmpdir / (tag + ".json")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            try:
                return json.loads(path.read_text("utf-8"))
            except ValueError:
                pass
        time.sleep(0.1)
    return None


async def main() -> int:
    try:
        import websockets  # noqa: F401
    except ImportError:
        print("SKIP: websockets fehlt (pip install websockets)")
        return 0
    if _optional("Cython") is None or _optional("setuptools") is None:
        print("SKIP: Cython/setuptools fehlen (pip install cython setuptools)")
        return 0

    from python_bridge import protocol

    tmp = Path(tempfile.mkdtemp(prefix="pb_cy_live_"))
    ws = tmp / "ws"
    scripts = ws / "scripts"
    (ws / "tmp").mkdir(parents=True, exist_ok=True)
    scripts.mkdir(parents=True, exist_ok=True)
    (scripts / "mathx.pyx").write_text(
        "def dot(a, b):\n"
        "    return float(sum(x * y for x, y in zip(a, b)))\n"
        "\n"
        "def twice(v):\n"
        "    cdef int i\n"
        "    s = 0\n"
        "    for i in range(v):\n"
        "        s += 2\n"
        "    return s\n",
        "utf-8")

    proc = None
    try:
        # ------------------------------------------------------------- Build
        report = build(scripts)
        check("cython_build.py: ok", bool(report.get("ok")), json.dumps(
            {k: report.get(k) for k in ("built", "skipped", "compiler", "duration_s", "error")},
            ensure_ascii=False))
        built = list(report.get("built") or []) + list(report.get("skipped") or [])
        check("mathx wurde gebaut", "mathx" in built, str(built))
        artifacts = [p.name for p in scripts.iterdir()
                     if p.name.startswith("mathx.") and p.suffix in (".so", ".pyd")]
        if not check("kompiliertes Modul liegt neben der .pyx", bool(artifacts), str(artifacts)):
            for err in report.get("errors") or []:
                print("     build error: %s" % (err.get("message", "")[-600:]))
            return 1

        # ------------------------------------------------------------ Server
        proc = subprocess.Popen(
            [sys.executable, str(RUN_SERVER), "--bind", "127.0.0.1", "--port", "0",
             "--tmpdir", str(ws / "tmp"), "--tag", "cy"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        info = wait_port_file(ws / "tmp", "cy")
        if not check("Server meldet seinen Port", info is not None):
            return 1
        url = "ws://127.0.0.1:%d" % int(info["port"])
        context = "cython:" + str(scripts / "mathx.pyx")

        async with websockets.connect(url, subprotocols=["pybridge-v2"]) as sock:
            async def call(task_id: str, function: str, args: list, source: str = ""):
                await sock.send(protocol.build_text({
                    "v": 2, "type": "task", "id": task_id, "command": "call",
                    "context": context, "source": source, "function": function,
                    "data": {"args": args, "kwargs": {}},
                }))
                raw = await asyncio.wait_for(sock.recv(), timeout=30)
                msg, data = protocol.parse(raw)
                return msg, data

            msg, data = await call("c1", "dot", [[3.0, 4.0], [5.0, 6.0]])
            check("cython-Call dot(...) -> 39.0", msg.get("type") == "task_result" and data == 39.0,
                  "%s / %s" % (msg.get("type"), data))

            msg, data = await call("c2", "twice", [21])
            check("zweiter Call nutzt denselben Kontext (twice(21) -> 42)",
                  msg.get("type") == "task_result" and data == 42, str(data))

            # Fehlendes Modul: eigener Kontext, keine kompilierte Seite
            await sock.send(protocol.build_text({
                "v": 2, "type": "task", "id": "c3", "command": "call",
                "context": "cython:" + str(scripts / "missing.pyx"), "source": "",
                "function": "nope", "data": {"args": [], "kwargs": {}},
            }))
            raw = await asyncio.wait_for(sock.recv(), timeout=30)
            msg, _ = protocol.parse(raw)
            check("fehlendes Modul -> strukturierter task_error",
                  msg.get("type") == "task_error"
                  and (msg.get("error") or {}).get("code") in
                  ("CythonModuleNotFound", protocol.CATEGORY_TASK_ERROR),
                  json.dumps(msg.get("error") or {})[:300])

            # Verbindung bleibt nutzbar
            await sock.send(protocol.build_text({"v": 2, "type": protocol.MSG_PING,
                                                 "id": "p1"}))
            raw = await asyncio.wait_for(sock.recv(), timeout=10)
            msg, _ = protocol.parse(raw)
            check("Verbindung nach dem Fehler weiter nutzbar",
                  msg.get("type") == protocol.MSG_PONG)

        # ------------------------------------------------------- Inkrementell
        again = build(scripts)
        check("unveraenderte .pyx wird uebersprungen (inkrementell)",
              bool(again.get("ok")) and "mathx" in list(again.get("skipped") or []),
              json.dumps({k: again.get(k) for k in ("built", "skipped")}))
    finally:
        if proc is not None:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except Exception:  # noqa: BLE001
                pass
        shutil.rmtree(tmp, ignore_errors=True)

    failed = [name for name, ok, _ in RESULTS if not ok]
    print("\n%d/%d Checks bestanden%s" % (len(RESULTS) - len(failed), len(RESULTS),
                                         "" if not failed else " - FAIL: " + ", ".join(failed)))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
