"""Live-E2E: Cython-Sonderpfad gegen einen echten Server-Prozess.

Beweist die Kette end-to-end:
  1. .pyx liegt kompiliert (.so) im scripts/-Ordner einer Test-Workspace
  2. echter Server (venv-Python, echtes websockets) bootet,
     run_server haengt scripts/ an sys.path
  3. call auf einen "cython:"-Kontext importiert das Modul und liefert
     das Ergebnis (dot -> 32.0)
  4. zweiter Call nutzt denselben persistenten Kontext (twice(21) -> 42)
  5. fehlendes Modul -> strukturierter task_error CythonModuleNotFound
     (kein Crash, Verbindung bleibt nutzbar)

Voraussetzung: mathx.so wurde bereits gebaut (tests/live_cython_build.sh).
"""

import json
import os
import shutil
import subprocess
import sys
import time
import asyncio
from pathlib import Path

REPO = Path("/home/toshix/python_bridge")
WS = Path.home() / ".local/share/godot/app_userdata/TestingSetup/python_bridge"
RUN_SERVER = WS / "bridge/run_server.py"
VENV_PY = WS / "venv/bin/python"
CY_VENV_PY = Path("/tmp/cy2/bin/python")       # venv mit cython/setuptools
SCRATCH = Path("/tmp/cy2/scratch")             # liegt .pyx + .so + build_state
LIVE = Path("/tmp/cy_live")

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name,
                           (" -> " + detail) if detail else ""))


def wait_port_file(tmpdir, tag, timeout=30):
    p = Path(tmpdir) / (tag + ".json")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if p.exists():
            return json.loads(p.read_text())
        time.sleep(0.1)
    raise RuntimeError("Port-Datei kam nicht: " + str(p))


async def recv_until(ws, want_type, timeout=10):
    import websockets
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            frame = await asyncio.wait_for(ws.recv(), timeout=max(0.1, deadline - time.time()))
        except (asyncio.TimeoutError, asyncio.IncompleteReadError):
            break
        except websockets.ConnectionClosed:
            break
        if isinstance(frame, str):
            m = json.loads(frame)
            if m.get("type") == want_type:
                return m
    return None


async def main():
    import websockets

    # ---------------------------------------------------------------- Aufbau
    if LIVE.exists():
        shutil.rmtree(LIVE)
    (LIVE / "tmp").mkdir(parents=True)
    (LIVE / "scripts").mkdir(parents=True)
    # .so aus dem Build-Scratch uebernehmen (gleiche Python-ABI 3.12)
    so_files = list(SCRATCH.glob("mathx.*.so"))
    check("kompiliertes Modul vorhanden (Vorlauf-Build)", bool(so_files),
          ", ".join(f.name for f in so_files))
    for f in so_files:
        shutil.copy2(f, LIVE / "scripts" / f.name)
    shutil.copy2(SCRATCH / "mathx.pyx", LIVE / "scripts" / "mathx.pyx")

    tag = "inst"
    # Konvention wie in der echten Bridge: tmpdir = <workspace>/tmp ->
    # run_server leitet daraus <workspace>/scripts als Import-Pfad ab.
    tmpdir = LIVE / "tmp"
    tmpdir.mkdir(exist_ok=True)
    proc = subprocess.Popen(
        [str(VENV_PY), str(RUN_SERVER), "--bind", "127.0.0.1", "--port", "0",
         "--tmpdir", str(tmpdir), "--tag", tag],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        info = wait_port_file(tmpdir, tag)
        port = int(info["port"])
        check("Server gestartet (Port-Datei)", True, "port=%d" % port)

        async with websockets.connect("ws://127.0.0.1:%d" % port,
                                      subprotocols=["pybridge-v2"]) as ws:
            await ws.send(json.dumps({"v": 2, "type": "hello", "id": "h1", "caps": {}}))
            ack = await recv_until(ws, "hello_ack")
            check("hello_ack", ack is not None)

            call = lambda mid, ctx, fn, args: json.dumps(
                {"v": 2, "type": "task", "id": mid, "command": "call",
                 "context": ctx, "source": "", "source_hash": None,
                 "function": fn, "data": {"args": args}})

            # (3) Erster Call: import + Verdrahtung + Ausfuehrung
            await ws.send(call("c1", "cython:%s/scripts/mathx.pyx" % LIVE,
                               "dot", [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]))
            r = await recv_until(ws, "task_result")
            check("cython call dot == 32.0",
                  r is not None and r.get("status") == "ok"
                  and r.get("data") == 32.0,
                  "data=%s" % (r or {}).get("data"))

            # (4) Zweiter Call: gleicher Kontext, Namespace persistiert
            await ws.send(call("c2", "cython:%s/scripts/mathx.pyx" % LIVE,
                               "twice", [21]))
            r = await recv_until(ws, "task_result")
            check("cython call twice(21) == 42 (Namespace persistiert)",
                  r is not None and r.get("status") == "ok"
                  and r.get("data") == 42,
                  "data=%s" % (r or {}).get("data"))

            # (5) Fehlendes Modul: strukturierter Fehler, kein Crash
            await ws.send(call("c3", "cython:%s/scripts/ghost.pyx" % LIVE,
                               "f", []))
            e = await recv_until(ws, "task_error")
            ok = (e is not None
                  and e.get("error", {}).get("type") == "CythonModuleNotFound")
            check("CythonModuleNotFound strukturiert", ok,
                  "type=%s" % (e or {}).get("error", {}).get("type"))

            # Verbindung danach weiterhin nutzbar?
            await ws.send(call("c4", "cython:%s/scripts/mathx.pyx" % LIVE,
                               "twice", [2]))
            r = await recv_until(ws, "task_result")
            check("Verbindung nach Fehler weiterhin nutzbar",
                  r is not None and r.get("status") == "ok"
                  and r.get("data") == 4)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()

    print("\n== Ergebnis: %d/%d PASS" % (
        sum(1 for _, ok, _ in results if ok), len(results)))
    return 0 if all(ok for _, ok, _ in results) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
