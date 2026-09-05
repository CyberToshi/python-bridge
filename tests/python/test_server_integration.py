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
import websockets.exceptions

PY_DIR = os.path.join(os.path.dirname(__file__),
                      "..", "..", "addons", "python_bridge", "python")
sys.path.insert(0, PY_DIR)
from python_bridge import protocol  # noqa: E402


def _start_server(tmpdir, tag="test", extra=()):
    proc = subprocess.Popen(
        [sys.executable, os.path.join(PY_DIR, "run_server.py"),
         "--bind", "127.0.0.1", "--port", "0",
         "--tmpdir", tmpdir, "--tag", tag] + list(extra),
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

    def _start_with_threshold(self, threshold):
        return _start_server(
            self._tmpdir, tag="ref",
            extra=["--data-ref-threshold-bytes", str(threshold)])

    async def _recv_head(self, ws):
        """Raw message header (no value decoding). Descriptor-only frames are
        text; anything chunked falls back to protocol.parse."""
        raw = await ws.recv()
        if isinstance(raw, str):
            import json
            return json.loads(raw)
        msg, _data = protocol.parse(raw)
        return msg

    def test_data_ref_large_ndarray_lifecycle(self):
        """Auto-DataRef oberhalb der Schwelle: Descriptor statt Chunk, mehrfache
        Materialisierung, explizite Freigabe, stale-Handle nach Release."""
        try:
            import numpy as np
        except ImportError:  # pragma: no cover
            self.skipTest("numpy not available")

        # Separate server with its own threshold config.
        import shutil
        import tempfile
        tmp = tempfile.mkdtemp(prefix="pb_ref_")
        proc, info = self._start_with_threshold(32)
        port = info["port"]

        async def run():
            async with websockets.connect(
                    "ws://127.0.0.1:%d" % port,
                    subprotocols=["pybridge-v2"],
                    max_size=512 * 1024 * 1024) as ws:
                src = (
                    "import numpy as np\n"
                    "result = np.arange(64, dtype=np.float32)\n"
                )
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "d1",
                    "command": "run", "context": "refctx",
                    "source": src, "data": {"input": None}}))
                msg = await self._recv_head(ws)
                self.assertEqual(msg["type"], protocol.MSG_TASK_RESULT)
                self.assertEqual(msg["status"], "ok")
                # The result is a lightweight handle, not a giant chunk.
                desc = msg["data"]
                self.assertEqual(desc.get("$pb"), "data_ref")
                self.assertEqual(desc["dtype"], "float32")
                self.assertEqual(desc["shape"], [64])
                self.assertEqual(desc["nbytes"], 256)
                ref_id = desc["id"]

                # Reusable: materialize twice with identical content.
                for n in (1, 2):
                    await ws.send(protocol.build_text({
                        "v": 2, "type": protocol.MSG_DATA_GET,
                        "id": "g%d" % n, "ref_id": ref_id}))
                    msg, data = await self._recv(ws)
                    self.assertEqual(msg["type"], protocol.MSG_DATA_RESULT)
                    self.assertEqual(msg["status"], "ok")
                    self.assertTrue(np.array_equal(
                        data, np.arange(64, dtype=np.float32)))

                # Explicit release frees the backing store.
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_DATA_RELEASE,
                    "id": "r1", "ref_id": ref_id}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_DATA_ACK)
                self.assertEqual(msg["freed"], True)

                # Materializing a released handle is a structured error.
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_DATA_GET,
                    "id": "g3", "ref_id": ref_id}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_DATA_RESULT)
                self.assertEqual(msg["status"], "error")
                self.assertIn("stale", msg["error"]["message"])

        try:
            import asyncio
            asyncio.run(run())
        finally:
            try:
                proc.kill()
                proc.wait(timeout=5)
            except Exception:
                pass
            shutil.rmtree(tmp, ignore_errors=True)

    def test_small_ndarray_stays_direct(self):
        """Unterhalb der Schwelle bleibt das numpy-Ergebnis ein normaler,
        direkt uebertragener Wert (kein Handle)."""
        try:
            import numpy as np
        except ImportError:  # pragma: no cover
            self.skipTest("numpy not available")
        tmp_proc, info = self._start_with_threshold(1024)
        port = info["port"]

        async def run():
            async with websockets.connect(
                    "ws://127.0.0.1:%d" % port,
                    subprotocols=["pybridge-v2"],
                    max_size=512 * 1024 * 1024) as ws:
                src = (
                    "import numpy as np\n"
                    "result = np.arange(8, dtype=np.float32)\n"  # 32 bytes
                )
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "d2",
                    "command": "run", "context": "refctx2",
                    "source": src, "data": {"input": None}}))
                msg, data = await self._recv(ws)
                self.assertEqual(msg["type"], protocol.MSG_TASK_RESULT)
                self.assertEqual(msg["status"], "ok")
                self.assertFalse(isinstance(data, dict) and
                                 data.get("$pb") == "data_ref")
                self.assertTrue(np.array_equal(
                    data, np.arange(8, dtype=np.float32)))

        try:
            import asyncio
            asyncio.run(run())
        finally:
            try:
                tmp_proc.kill()
                tmp_proc.wait(timeout=5)
            except Exception:
                pass

    def _spawn(self, extra, tag="w"):
        """Separate Server-Prozess mit zusaetzlichen CLI-Argumenten."""
        proc, info = _start_server(self._tmpdir, tag=tag, extra=extra)
        return proc, info["port"]

    @staticmethod
    def _timestamps(msg):
        out = {}
        for line in str(msg.get("stdout", "")).splitlines():
            parts = line.split()
            if len(parts) == 2:
                out[parts[0]] = float(parts[1])
        return out

    def test_workers_parallel_across_contexts(self):
        """workers=2: unabhaengige Contexts laufen parallel (ueberlappende
        Ausfuehrungszeit), nicht seriell nacheinander."""
        proc, port = self._spawn(["--workers", "2"], tag="wp")

        async def run():
            async with websockets.connect(
                    "ws://127.0.0.1:%d" % port,
                    subprotocols=["pybridge-v2"],
                    max_size=512 * 1024 * 1024) as ws:
                src_a = ("import time\n"
                         "print('A_START', time.time(), flush=True)\n"
                         "time.sleep(0.8)\n"
                         "print('A_END', time.time(), flush=True)\n"
                         "result = 1\n")
                src_b = ("import time\n"
                         "print('B_START', time.time(), flush=True)\n"
                         "time.sleep(0.05)\n"
                         "result = 2\n")
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "pa",
                    "command": "run", "context": "ca", "source": src_a,
                    "data": {"input": None}}))
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "pb",
                    "command": "run", "context": "cb", "source": src_b,
                    "data": {"input": None}}))
                msgs = {}
                for _ in range(2):
                    msg, _data = await self._recv(ws)
                    msgs[msg["id"]] = msg
                ts_a = self._timestamps(msgs["pa"])
                ts_b = self._timestamps(msgs["pb"])
                self.assertEqual(msgs["pa"]["status"], "ok")
                self.assertEqual(msgs["pb"]["status"], "ok")
                self.assertLess(
                    ts_b["B_START"], ts_a["A_END"] - 0.1,
                    "independent context B started while A was still running")

        try:
            import asyncio
            asyncio.run(run())
        finally:
            proc.kill()
            proc.wait(timeout=5)

    def test_same_context_stays_serialized_with_workers(self):
        """workers=2: Tasks desselben Contexts laufen nie parallel."""
        proc, port = self._spawn(["--workers", "2"], tag="ws")

        async def run():
            async with websockets.connect(
                    "ws://127.0.0.1:%d" % port,
                    subprotocols=["pybridge-v2"],
                    max_size=512 * 1024 * 1024) as ws:
                src_a = ("import time\n"
                         "print('A_START', time.time(), flush=True)\n"
                         "time.sleep(0.5)\n"
                         "print('A_END', time.time(), flush=True)\n"
                         "result = 1\n")
                src_b = ("import time\n"
                         "print('B_START', time.time(), flush=True)\n"
                         "result = 2\n")
                for i, (ctx, src) in enumerate([("sx", src_a), ("sx", src_b)]):
                    await ws.send(protocol.build_text({
                        "v": 2, "type": protocol.MSG_TASK, "id": "s%d" % i,
                        "command": "run", "context": ctx, "source": src,
                        "data": {"input": None}}))
                msgs = {}
                for _ in range(2):
                    msg, _ = await self._recv(ws)
                    msgs[msg["id"]] = msg
                ts_a = self._timestamps(msgs["s0"])
                ts_b = self._timestamps(msgs["s1"])
                self.assertGreaterEqual(
                    ts_b["B_START"], ts_a["A_END"] - 0.02,
                    "same context must not overlap (context lock)")

        try:
            import asyncio
            asyncio.run(run())
        finally:
            proc.kill()
            proc.wait(timeout=5)

    def test_runaway_does_not_block_independent_context(self):
        """Ein blockierter (timeout-ueberschrittener) Task belegt nur seinen
        Slot: ein unabhaengiger Context laeuft mit workers=2 trotzdem durch."""
        proc, port = self._spawn(["--workers", "2"], tag="wr")

        async def run():
            async with websockets.connect(
                    "ws://127.0.0.1:%d" % port,
                    subprotocols=["pybridge-v2"],
                    max_size=512 * 1024 * 1024) as ws:
                src_a = "import time; time.sleep(5); result = 1"
                src_b = "result = 42"
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "ra",
                    "command": "run", "context": "ra", "source": src_a,
                    "timeout_ms": 250, "data": {"input": None}}))
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "rb",
                    "command": "run", "context": "rb", "source": src_b,
                    "data": {"input": None}}))
                msgs = {}
                for _ in range(2):
                    msg, data = await self._recv(ws)
                    msgs[msg["id"]] = (msg, data)
                msg_a, _ = msgs["ra"]
                msg_b, data_b = msgs["rb"]
                self.assertEqual(msg_a["status"], "error")
                self.assertEqual(msg_a["error"]["code"],
                                 protocol.CATEGORY_TIMEOUT_ERROR)
                self.assertEqual(msg_b["status"], "ok",
                                 "independent context must not wait for the runaway")
                self.assertEqual(data_b, 42)

        try:
            import asyncio
            asyncio.run(run())
        finally:
            proc.kill()
            proc.wait(timeout=5)

    def test_kill_on_runaway_after_grace(self):
        """Watchdog: laeuft ein timeout-ueberschrittener Job nach der
        Grace-Frist weiter, beendet der Prozess sich selbst (kein Zombie)."""
        import time as _time
        proc, port = self._spawn(
            ["--workers", "1", "--runaway-grace-ms", "600"], tag="wk")

        async def run():
            async with websockets.connect(
                    "ws://127.0.0.1:%d" % port,
                    subprotocols=["pybridge-v2"],
                    max_size=512 * 1024 * 1024) as ws:
                src = "import time; time.sleep(60); result = 1"
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "k1",
                    "command": "run", "context": "kk", "source": src,
                    "timeout_ms": 200, "data": {"input": None}}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["status"], "error")
                self.assertEqual(msg["error"]["code"],
                                 protocol.CATEGORY_TIMEOUT_ERROR)
                # Watchdog beendet den Prozess nach der Grace-Frist -> die
                # Verbindung schliesst sich von selbst.
                closed = False
                try:
                    await ws.recv()
                except websockets.exceptions.ConnectionClosed:
                    closed = True
                self.assertTrue(closed, "watchdog must terminate the connection")

        try:
            import asyncio
            asyncio.run(run())
        finally:
            # Prozess muss sich selbst beendet haben (kein Zombie).
            deadline = _time.time() + 4.0
            while _time.time() < deadline and proc.poll() is None:
                _time.sleep(0.05)
            self.assertIsNotNone(proc.poll(), "runaway process must exit itself")
            if proc.poll() is None:  # pragma: no cover - safety
                proc.kill()
                proc.wait(timeout=5)

    def test_file_backed_materialization(self):
        """DATA_GET mit want=file: Godot erhaelt einen Datei-Descriptor statt
        der Rohdaten; Release loescht die Datei; fehlende Datei -> Fallback."""
        try:
            import numpy as np
        except ImportError:  # pragma: no cover
            self.skipTest("numpy not available")
        import os
        proc, port = self._spawn(["--data-ref-threshold-bytes", "32"], tag="fw")

        async def run():
            async with websockets.connect(
                    "ws://127.0.0.1:%d" % port,
                    subprotocols=["pybridge-v2"],
                    max_size=512 * 1024 * 1024) as ws:
                src = ("import numpy as np\n"
                       "result = np.arange(64, dtype=np.float32)\n")
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "fd1",
                    "command": "run", "context": "filectx",
                    "source": src, "data": {"input": None}}))
                msg = await self._recv_head(ws)
                desc = msg["data"]
                self.assertEqual(desc.get("$pb"), "data_ref")
                ref_id = desc["id"]

                # File transport: descriptor only, no data over the socket.
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_DATA_GET,
                    "id": "fg1", "ref_id": ref_id, "want": "file"}))
                msg = await self._recv_head(ws)
                self.assertEqual(msg["type"], protocol.MSG_DATA_RESULT)
                self.assertEqual(msg["status"], "ok")
                finfo = msg["data"]
                self.assertEqual(finfo["transport"], "file")
                self.assertTrue(os.path.exists(finfo["path"]),
                                "file transport points at a real file")
                self.assertEqual(finfo["nbytes"], 256)
                self.assertEqual(finfo["dtype"], "float32")
                with open(finfo["path"], "rb") as f:
                    raw = f.read()
                import hashlib
                self.assertEqual(
                    finfo["sha256"], hashlib.sha256(raw).hexdigest())
                self.assertTrue(np.array_equal(
                    np.frombuffer(raw, dtype=np.float32),
                    np.arange(64, dtype=np.float32)))

                # Release loescht die Datei.
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_DATA_RELEASE,
                    "id": "fr1", "ref_id": ref_id}))
                msg, _ = await self._recv(ws)
                self.assertEqual(msg["freed"], True)
                self.assertFalse(os.path.exists(finfo["path"]),
                                 "release deletes the data file")

        try:
            import asyncio
            asyncio.run(run())
        finally:
            proc.kill()
            proc.wait(timeout=5)

    def test_file_transport_falls_back_when_file_missing(self):
        """Fehlt die Datei (extern entfernt), liefert want=file transparent den
        normalen (chunked) Transfer - kein Fehler, keine tote Referenz."""
        try:
            import numpy as np
        except ImportError:  # pragma: no cover
            self.skipTest("numpy not available")
        import os
        proc, port = self._spawn(["--data-ref-threshold-bytes", "32"], tag="fb")

        async def run():
            async with websockets.connect(
                    "ws://127.0.0.1:%d" % port,
                    subprotocols=["pybridge-v2"],
                    max_size=512 * 1024 * 1024) as ws:
                src = ("import numpy as np\n"
                       "result = np.arange(64, dtype=np.float32)\n")
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_TASK, "id": "fd2",
                    "command": "run", "context": "fctx2",
                    "source": src, "data": {"input": None}}))
                msg = await self._recv_head(ws)
                ref_id = msg["data"]["id"]
                # Datei hinter dem Server entfernen, dann Datei-Transfer anfordern.
                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_DATA_GET,
                    "id": "fg2", "ref_id": ref_id, "want": "file"}))
                fmsg = await self._recv_head(ws)
                file_path = fmsg["data"]["path"]
                os.remove(file_path)

                await ws.send(protocol.build_text({
                    "v": 2, "type": protocol.MSG_DATA_GET,
                    "id": "fg3", "ref_id": ref_id, "want": "file"}))
                msg, data = await self._recv(ws)
                self.assertEqual(msg["status"], "ok")
                self.assertFalse(
                    isinstance(data, dict) and data.get("transport") == "file",
                    "fallback must deliver the real data")
                self.assertTrue(np.array_equal(
                    data, np.arange(64, dtype=np.float32)))

        try:
            import asyncio
            asyncio.run(run())
        finally:
            proc.kill()
            proc.wait(timeout=5)

    def test_orphan_data_files_cleaned_on_server_start(self):
        """Crash-Cleanup: verwaiste Daten-Dateien der Instanz werden beim
        Serverstart entfernt (kein Muelle-Sammeln ueber Prozessgrenzen)."""
        import os
        data_dir = os.path.join(self._tmpdir, "data")
        os.makedirs(data_dir, exist_ok=True)
        stale = os.path.join(data_dir, "data-fb-orphan-99.bin")
        with open(stale, "wb") as f:
            f.write(b"\x00" * 128)
        proc, port = self._spawn([], tag="fb")
        try:
            self.assertFalse(
                os.path.exists(stale),
                "server start must remove orphaned data files")
        finally:
            proc.kill()
            proc.wait(timeout=5)

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