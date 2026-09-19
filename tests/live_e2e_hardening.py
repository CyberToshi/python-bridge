"""Live-E2E: 2.7 (Budget-Vorabcheck) + 4.2 (Shutdown-Drain) + 4.3 (Exit-Codes)
gegen echte Server-Prozesse (venv-Python, echtes websockets).

Szenarien:
  1. Baseline   -> kleiner Call: task_result ok
  2. Budget     -> 2M-Element-Liste: task_error ResultTooLargeError/
                   SERIALIZATION_ERROR, VOR dem Encoding (schnelle Antwort)
  3. Shutdown   -> Task A (sleep 2s, in-flight) + Task B (liegt in der Queue),
                   dann shutdown: A liefert evtl. noch ein Ergebnis bzw. geht
                   verloren (dokumentierte Grenze), B bekommt task_error
                   CONNECTION_ERROR "shutting down" VOR dem Close (4.2).
                   Prozess endet mit Exit 0 (4.3: geordnete Beendigung).
  4. Exit-Code  -> Server ohne 'websockets' (System-Python): RuntimeError ->
                   stderr-Log + Exit 1 statt stummem Exit 0 (4.3).
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import asyncio
from pathlib import Path

REPO = Path("/home/toshix/python_bridge")
# run_server.py aus der WORKSPACE-Kopie des Testprojekts - genau der Pfad,
# den auch der echte Godot-Server nutzt (Konvention: <workspace>/bridge/).
WS = Path.home() / ".local/share/godot/app_userdata/TestingSetup/python_bridge"
RUN_SERVER = WS / "bridge/run_server.py"
VENV_PY = WS / "venv/bin/python"
SYS_PY = "/usr/bin/python3"
BRIDGE_WS_COPY = WS / "bridge/python_bridge"
REPO_BRIDGE = REPO / "addons/python_bridge/python/python_bridge"

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name,
                           (" -> " + detail) if detail else ""))


def start_server(python, tag, tmpdir, extra=()):
    return subprocess.Popen(
        [str(python), str(RUN_SERVER), "--bind", "127.0.0.1", "--port", "0",
         "--tmpdir", str(tmpdir), "--tag", tag, "--max-result-bytes", "262144",
         *extra],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def wait_port_file(tmpdir, tag, timeout=30):
    p = Path(tmpdir) / (tag + ".json")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if p.exists():
            return json.loads(p.read_text())
        time.sleep(0.1)
    raise RuntimeError("Port-Datei kam nicht: " + str(p))


def connect(port, subprotocol):
    import websockets
    return websockets.connect("ws://127.0.0.1:%d" % port,
                              subprotocols=[subprotocol])


def text_msg(msg):
    import websockets
    return websockets.frames.TextMessage  # nicht noetig; Platzhalter


async def recv_until(ws, want_type, timeout=10):
    """Empfaengt Frames bis ein Text-Frame vom gewuenschten Typ kommt;
    andere Frames (z. B. Binary-Ergebnisse) werden eingesammelt."""
    import websockets
    seen = []
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
            seen.append(m)
            if m.get("type") == want_type:
                return m, seen
        # Binary-Frames ignorieren wir hier (Baseline liefert kleine Texte)
    return None, seen


async def scenario_budget_and_shutdown(port):
    import websockets
    src = ("import time\n"
           "def make_list(n):\n"
           "    return list(range(n))\n"
           "def slow():\n"
           "    time.sleep(2.0)\n"
           "    return 'done'\n")
    async with connect(port, "pybridge-v2") as ws:
        # HELLO
        await ws.send(json.dumps({"v": 2, "type": "hello", "id": "h1",
                                  "caps": {}}))
        ack, _ = await recv_until(ws, "hello_ack")
        check("hello_ack", ack is not None)

        # (1) Baseline
        call = lambda mid, fn, args: json.dumps(
            {"v": 2, "type": "task", "id": mid, "command": "call",
             "context": "ctx", "source": src, "source_hash": None,
             "function": fn, "data": {"args": [
                 {"$pb": "int"} if False else a for a in args]}})
        # args muessen kodiert sein: einfache ints sind bereits JSON-Werte
        call = lambda mid, fn, args: json.dumps(
            {"v": 2, "type": "task", "id": mid, "command": "call",
             "context": "ctx", "source": src, "source_hash": None,
             "function": fn, "data": {"args": args}})
        await ws.send(call("c1", "make_list", [10]))
        r, _ = await recv_until(ws, "task_result")
        check("Baseline task_result ok", r is not None and r.get("status") == "ok")

        # (2) Budget: 2M Ints ~ weit ueber 256KB Budget
        t0 = time.time()
        await ws.send(call("c2", "make_list", [2_000_000]))
        err, _ = await recv_until(ws, "task_error")
        dt = time.time() - t0
        ok = (err is not None
              and err.get("error", {}).get("code") == "SERIALIZATION_ERROR"
              and "ResultTooLargeError" in str(err.get("error", {}).get("type", "")))
        check("2.7 Budget-Fehler vor Encoding", ok,
              "dt=%.2fs code=%s" % (dt, (err or {}).get("error", {}).get("code")))
        check("2.7 schnelle Antwort (<5s, Encoding waere laenger)", dt < 5.0,
              "dt=%.2fs" % dt)

        # (3) 4.2: Task A in-flight (2s), Task B in der Queue, dann shutdown
        await ws.send(call("a1", "slow", []))
        await ws.send(call("b1", "make_list", [5]))
        await asyncio.sleep(0.3)  # A nimmt Slot 1, B wartet in der Queue
        await ws.send(json.dumps({"v": 2, "type": "shutdown", "id": "s1"}))
        shutdown_seen, collected = await recv_until(ws, "shutdown_ack", timeout=3)
        check("shutdown_ack", shutdown_seen is not None)

        # Danach: Task B muss eine geordnete task_error bekommen (Drain vor
        # dem Close). A kann evtl. nicht mehr antworten (in-flight, Grenze).
        got_b_error = False
        try:
            while True:
                frame = await asyncio.wait_for(ws.recv(), timeout=5)
                if isinstance(frame, str):
                    m = json.loads(frame)
                    if m.get("id") == "b1" and m.get("type") == "task_error":
                        got_b_error = (m.get("error", {}).get("code")
                                       == "CONNECTION_ERROR")
                        break
                    if m.get("id") == "a1":
                        continue  # in-flight: darf auch noch kommen
        except (asyncio.TimeoutError, websockets.ConnectionClosed):
            pass
        check("4.2 geordnete task_error fuer Queue-Job (b1)", got_b_error)
    # ws-Context geschlossen (Server hat close initiiert)


async def scenario_exit_code():
    """4.3: RuntimeError ('websockets fehlt') muss mit Log + Exit 1 enden,
    statt als stummer Exit 0 durchzugehen. Simulation ohne echtes Deinstall:
    ein Fake-Modul auf PYTHONPATH schattiert das echte websockets und wirft
    beim Import - exakt der Pfad, den der Server zu RuntimeError macht."""
    with tempfile.TemporaryDirectory() as shadow_dir:
        (Path(shadow_dir) / "websockets.py").write_text(
            "raise ImportError('simuliert: websockets fehlt')\n")
        env = dict(os.environ)
        env["PYTHONPATH"] = shadow_dir + os.pathsep + env.get("PYTHONPATH", "")
        proc = subprocess.Popen(
            [str(SYS_PY), str(RUN_SERVER), "--bind", "127.0.0.1", "--port", "0",
             "--tmpdir", tempfile.mkdtemp(), "--tag", "exitprobe"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
        try:
            out, _ = proc.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, _ = proc.communicate()
            check("4.3 Prozess endet (!=Timeout)", False, "timeout")
            return
        check("4.3 Exit-Code 1 bei Server-Fehler", proc.returncode == 1,
              "rc=%d" % proc.returncode)
        fatal_lines = [l for l in (out or "").splitlines()
                       if "fatal" in l or "RuntimeError" in l][:1]
        check("4.3 'server fatal' im Log (stderr)", "server fatal" in (out or ""),
              fatal_lines[0] if fatal_lines else "(nichts)")
        check("4.3 'server exits (code=1)' im Log",
              "server exits (code=1)" in (out or ""))


async def main():
    if not VENV_PY.exists():
        print("SKIP: venv nicht gefunden:", VENV_PY)
        return
    # Workspace-Kopie aktualisieren: Der Server laeuft bewusst gegen die
    # Kopie im Workspace (wie im Spiel), nicht gegen die Addon-Quelle.
    import shutil
    BRIDGE_WS_COPY.parent.mkdir(parents=True, exist_ok=True)
    for f in REPO_BRIDGE.glob("*.py"):
        shutil.copy2(f, BRIDGE_WS_COPY / f.name)
    shutil.copy2(REPO / "addons/python_bridge/python/run_server.py",
                 WS / "bridge/run_server.py")
    # --- Szenario 1-3: venv-Server ---
    with tempfile.TemporaryDirectory() as td:
        proc = start_server(VENV_PY, "live27", td)
        try:
            info = wait_port_file(td, "live27")
            print("Server an Port", info["port"])
            await scenario_budget_and_shutdown(info["port"])
        finally:
            try:
                out, _ = proc.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                out, _ = proc.communicate()
        check("4.3 geordnete Beendigung -> Exit 0 nach shutdown",
              proc.returncode == 0, "rc=%s" % proc.returncode)
        check("Log: 'server exits (code=0)'", "server exits (code=0)" in (out or ""),
              "tail=%r" % (out or "")[-160:])

    # --- Szenario 4: Exit-Code bei Fehler ---
    await scenario_exit_code()

    print("\n== Ergebnis: %d PASS, %d FAIL ==" % (
        sum(1 for _, ok, _ in results if ok),
        sum(1 for _, ok, _ in results if not ok)))
    sys.exit(1 if any(not ok for _, ok, _ in results) else 0)


if __name__ == "__main__":
    asyncio.run(main())
