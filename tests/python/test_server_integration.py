"""Integration tests: full server process over WebSocket.

Spawns the real run_server.py as a subprocess, connects with a websockets
client and exercises the protocol: hello, task (run/call), batch, exception,
cancel, reload, introspect and shutdown. Covers the accepted scenarios
1-3, 5, 8, 11 of the master prompt at the protocol level.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

import websockets

PY_DIR = os.path.join(os.path.dirname(__file__),
                      "..", "..", "addons", "python_bridge", "python")
sys.path.insert(0, PY_DIR)
from python_bridge import protocol  # noqa: E402


def _start_server(tmpdir, tag="test"):
    proc = subprocess.Popen(
        [sys.executable, os.path.join(PY_DIR, "run_server.py"),
         "--bind", "127.0.0.1", "--port", "0",
         "--tmpdir", tmpdir, "--tag", tag],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    tmp_file = os.path.join(tmpdir, "%s.json" % tag)
    for _ in range(200):
        if os.path.exists(tmp_file):
            try:
                with open(tmp_file) as f:
                    info = json.load(f)
                if info.get("port"):
                    return proc, info
            except (ValueError, KeyError):
                pass
        time.sleep(0.05)
    raise RuntimeError("server did not start: %s" % proc.stderr.read())


class ServerIntegrationTest(unittest.TestCase):

    def setUp(self):
        # Fresh server per test so SHUTDOWN/timeout tests cannot poison
        # later tests (each instance process is independent).
        self._tmpdir = tempfile.mkdtemp(prefix="pb_test_")
        self._proc, self._info = _start_server(self._tmpdir)
        self._port = self._info["port"]

    def tearDown(self):
        try:
            self._proc.kill()
            self._proc.wait(timeout=5)
        except Exception:
            pass
        try:
            import shutil
            shutil.rmtree(self._tmpdir, ignore_errors=True)
        except Exception:
            pass

    def _connect(self):
        return websockets.connect(
            "ws://127.0.0.1:%d" % self._port,
            subprotocols=["pybridge-v2"],
            max_size=512 * 1024 * 1024)

    async def _recv(self, ws):
        raw = await ws.recv()
        msg, data = protocol.parse(raw)
        return msg, data

    # --- helpers to avoid duplicating asyncio.run in every test ---------------
    def _run(self, coro):
        import asyncio
        asyncio.run(coro)

    def test_hello(self):
        async def run():
            async with self._connect() as ws:
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_HELLO, "id": "h1"}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_HELLO_ACK)
                self.assertGreater(int(msg.get("pid", 0)), 0)
        import asyncio
        asyncio.run(run())

    def test_ping_pong(self):
        async def run():
            async with self._connect() as ws:
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_PING, "id": "p1"}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_PONG)
        import asyncio
        asyncio.run(run())

    def test_run_task(self):
        async def run():
            async with self._connect() as ws:
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "t1",
                    "command": "run", "context": "c1",
                    "source": "result = input['x'] * 2",
                    "data": {"input": {"x": 21}}}))
                msg, data = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_TASK_RESULT)
                self.assertEqual(msg["status"], "ok")
                self.assertEqual(data, 42)
        import asyncio
        asyncio.run(run())

    def test_call_task_and_state(self):
        async def run():
            async with self._connect() as ws:
                src = "counter = 0\ndef inc():\n    global counter\n    counter += 1\n    return counter\n"
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "c1",
                    "command": "call", "context": "state",
                    "source": src, "function": "inc",
                    "data": {"args": [], "kwargs": {}}}))
                msg, data = await self._recv(ws)
                self.assertEqual(data, 1)
                # second call reuses context (state preserved)
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "c2",
                    "command": "call", "context": "state",
                    "source": src, "function": "inc",
                    "data": {"args": [], "kwargs": {}}}))
                msg, data = await self._recv(ws)
                self.assertEqual(data, 2)
        import asyncio
        asyncio.run(run())

    def test_exception_structured(self):
        async def run():
            async with self._connect() as ws:
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "e1",
                    "command": "run", "context": "ec",
                    "source": "raise ValueError('kaputt')",
                    "data": {"input": None}}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_TASK_ERROR)
                err = msg["error"]
                self.assertEqual(err["code"], protocol.CATEGORY_PYTHON_EXCEPTION)
                self.assertEqual(err["type"], "ValueError")
                self.assertIn("kaputt", err["message"])
                self.assertIn("ValueError", err["traceback"])
        import asyncio
        asyncio.run(run())

    def test_batch_ordering_and_errors(self):
        async def run():
            async with self._connect() as ws:
                items = [
                    {"id": "b1", "command": "run", "context": "bc",
                     "source": "result = 1", "data": {"input": None}},
                    {"id": "b2", "command": "run", "context": "bc",
                     "source": "result = 2", "data": {"input": None}},
                    {"id": "b3", "command": "run", "context": "bc",
                     "source": "raise RuntimeError('x')", "data": {"input": None}},
                    {"id": "b4", "command": "run", "context": "bc",
                     "source": "result = 4", "data": {"input": None}},
                ]
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_BATCH, "id": "bat",
                    "items": items}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_BATCH_RESULT)
                results = msg[protocol.FIELD_ITEMS]
                self.assertEqual([r["id"] for r in results],
                                 ["b1", "b2", "b3", "b4"])
                self.assertEqual(results[0]["data"], 1)
                self.assertEqual(results[1]["data"], 2)
                self.assertEqual(results[2]["status"], "error")
                self.assertEqual(results[2]["error"]["type"], "RuntimeError")
                self.assertEqual(results[3]["data"], 4)
        import asyncio
        asyncio.run(run())

    def test_cancel_before_start(self):
        async def run():
            async with self._connect() as ws:
                # cancel a task id that never ran; executor consumes the marker
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_CANCEL, "id": "ca",
                    "target_id": "zz"}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_CANCEL_ACK)
        import asyncio
        asyncio.run(run())

    def test_reload_context(self):
        async def run():
            async with self._connect() as ws:
                v1 = "def f():\n    return 1\n"
                v2 = "def f():\n    return 2\n"
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "r1",
                    "command": "call", "context": "rc", "source": v1,
                    "function": "f", "data": {"args": [], "kwargs": {}}}))
                msg, data = await self._recv(ws)
                self.assertEqual(data, 1)
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_RELOAD, "id": "rl",
                    "context": "rc", "source": v2}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_RELOAD_ACK)
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "r2",
                    "command": "call", "context": "rc", "source": v2,
                    "function": "f", "data": {"args": [], "kwargs": {}}}))
                msg, data = await self._recv(ws)
                self.assertEqual(data, 2)
        import asyncio
        asyncio.run(run())

    def test_introspect(self):
        async def run():
            async with self._connect() as ws:
                src = "def calc(a: int, b: int = 2) -> int:\n    return a + b\n"
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_INTROSPECT, "id": "i1",
                    "source": src}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_INTROSPECT_RESULT)
                self.assertEqual(msg["status"], "ok")
                funcs = msg["functions"]
                self.assertEqual(funcs[0]["name"], "calc")
                self.assertEqual(funcs[0]["params"][0]["annotation"], "int")
        import asyncio
        asyncio.run(run())

    def test_timeout(self):
        async def run():
            async with self._connect() as ws:
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "to",
                    "command": "run", "context": "tc",
                    "source": "import time; time.sleep(5); result = 1",
                    "timeout_ms": 300, "data": {"input": None}}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_TASK_ERROR)
                self.assertEqual(msg["error"]["code"], protocol.CATEGORY_TIMEOUT_ERROR)
        import asyncio
        asyncio.run(run())

    def test_shutdown_ack(self):
        async def run():
            async with self._connect() as ws:
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_SHUTDOWN, "id": "sd"}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_SHUTDOWN_ACK)
        import asyncio
        asyncio.run(run())


if __name__ == "__main__":
    unittest.main()