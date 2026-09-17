"""Unit tests for the Pyodide browser host (platform-independent parts).

These tests run browser_host.py in CPython: the message semantics, envelope
shapes and error taxonomy must be byte-compatible with the desktop server,
which is exactly what these tests pin down. The Pyodide-specific parts
(WASM wheels, MEMFS, package loading) are covered by tools/test_web_runtime.mjs
and are documented separately.
"""

import base64
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "addons", "python_bridge", "python"))

from python_bridge import browser_host, protocol  # noqa: E402


def _dispatch(host, msg):
    """Dispatches a message dict through the host and returns parsed replies."""
    frames = host.handle_message(json.dumps(msg))
    return [_parse_frame(f) for f in frames]


def _parse_frame(frame):
    if "text" in frame:
        return json.loads(frame["text"])
    raw = base64.b64decode(frame["b64"])
    msg, _ = protocol.parse(raw)
    return msg


class BrowserHostTest(unittest.TestCase):

    def setUp(self):
        self.host = browser_host.BrowserHost({})

    def test_hello_returns_bridge_version_and_platform(self):
        replies = _dispatch(self.host, {"v": 2, "type": "hello", "id": "h1"})
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0]["type"], "hello_ack")
        self.assertEqual(replies[0]["id"], "h1")
        self.assertEqual(replies[0]["platform"], "web")
        self.assertIn("bridge_version", replies[0])

    def test_ping_pong(self):
        replies = _dispatch(self.host, {"v": 2, "type": "ping", "id": "p1"})
        self.assertEqual(replies[0]["type"], "pong")
        self.assertEqual(replies[0]["id"], "p1")

    def test_run_returns_result(self):
        msg = {"v": 2, "type": "task", "id": "t1", "command": "run",
               "context": "c1", "source": "result = input * 2",
               "data": {"input": 21}}
        replies = _dispatch(self.host, msg)
        self.assertEqual(replies[0]["type"], "task_result")
        self.assertEqual(replies[0]["status"], "ok")
        self.assertEqual(replies[0]["data"], 42)
        self.assertIn("ms", replies[0])

    def test_call_persistent_context(self):
        src = "def add(a, b):\n    return a + b\n"
        msg = {"v": 2, "type": "task", "id": "c1", "command": "call",
               "context": "ctx", "source": src, "function": "add",
               "data": {"args": [2, 3]}}
        replies = _dispatch(self.host, msg)
        self.assertEqual(replies[0]["status"], "ok")
        self.assertEqual(replies[0]["data"], 5)

    def test_python_error_is_structured(self):
        msg = {"v": 2, "type": "task", "id": "e1", "command": "run",
               "context": "ce", "source": "raise ValueError('kaputt')",
               "data": {"input": None}}
        replies = _dispatch(self.host, msg)
        self.assertEqual(replies[0]["type"], "task_error")
        err = replies[0]["error"]
        self.assertEqual(err["type"], "ValueError")
        self.assertIn("kaputt", err["message"])
        self.assertIn("traceback", err)

    def test_syntax_error_is_structured(self):
        msg = {"v": 2, "type": "task", "id": "s1", "command": "run",
               "context": "cs", "source": "def broken(:\n", "data": {}}
        replies = _dispatch(self.host, msg)
        self.assertEqual(replies[0]["type"], "task_error")
        self.assertEqual(replies[0]["error"]["type"], "SyntaxError")

    def test_stdout_is_captured(self):
        msg = {"v": 2, "type": "task", "id": "o1", "command": "run",
               "context": "co", "source": "print('hallo')\nresult = 1",
               "data": {"input": None}}
        replies = _dispatch(self.host, msg)
        self.assertEqual(replies[0]["stdout"].strip(), "hallo")

    def test_binary_frame_roundtrip(self):
        # Big ndarray results travel as a binary frame (chunks appended),
        # exactly like the desktop server; small ones stay inline (text).
        try:
            import numpy as np
        except ImportError:  # pragma: no cover
            self.skipTest("numpy not installed")
        src = ("import numpy as np\n"
               "def make():\n"
               "    return np.zeros(131072, dtype=np.float64)\n")  # 1 MB
        call = {"v": 2, "type": "task", "id": "b1", "command": "call",
                "context": "cb", "source": src, "function": "make", "data": {}}
        frames = self.host.handle_message(json.dumps(call))
        self.assertEqual(len(frames), 1)
        self.assertIn("binary", frames[0])
        msg, data = protocol.parse(frames[0]["binary"])
        self.assertEqual(msg["status"], "ok")
        # Full roundtrip: the decoded payload is a real numpy array again.
        self.assertIsInstance(data, np.ndarray)
        self.assertEqual(str(data.dtype), "float64")
        self.assertEqual(tuple(data.shape), (131072,))
        self.assertEqual(data.sum(), 0.0)

    def test_small_ndarray_stays_inline(self):
        try:
            import numpy as np
        except ImportError:  # pragma: no cover
            self.skipTest("numpy not installed")
        src = ("import numpy as np\n"
               "def make():\n"
               "    return np.array([1.0, 2.0, 3.0], dtype=np.float32)\n")
        call = {"v": 2, "type": "task", "id": "b2", "command": "call",
                "context": "cb2", "source": src, "function": "make", "data": {}}
        frames = self.host.handle_message(json.dumps(call))
        self.assertEqual(len(frames), 1)
        msg = json.loads(frames[0]["text"])
        self.assertEqual(msg["status"], "ok")
        self.assertEqual(msg["data"]["$pb"], "ndarray")
        self.assertEqual(msg["data"]["dtype"], "float32")

    def test_batch_items(self):
        msg = {"v": 2, "type": "batch", "id": "ba1",
               "items": [
                   {"id": "i1", "command": "run", "context": "x1",
                    "source": "result = input + 1", "data": {"input": 1}},
                   {"id": "i2", "command": "run", "context": "x2",
                    "source": "result = input + 2", "data": {"input": 1}},
               ]}
        replies = _dispatch(self.host, msg)
        self.assertEqual(replies[0]["type"], "batch_result")
        self.assertEqual(replies[0]["items"][0]["data"], 2)
        self.assertEqual(replies[0]["items"][1]["data"], 3)

    def test_cancel_then_task_reports_cancelled(self):
        self.host.handle_message(json.dumps(
            {"v": 2, "type": "cancel", "id": "k0", "target_id": "k1"}))
        msg = {"v": 2, "type": "task", "id": "k1", "command": "run",
               "context": "ck", "source": "result = 1", "data": {}}
        replies = _dispatch(self.host, msg)
        # Desktop parity: a consumed cancel arrives as task_error carrying
        # the CancelledError object (the client-side task layer maps it).
        self.assertEqual(replies[0]["type"], "task_error")
        self.assertEqual(replies[0]["error"]["type"], "CancelledError")

    def test_reload_ack(self):
        self.host.handle_message(json.dumps(
            {"v": 2, "type": "task", "id": "r0", "command": "run",
             "context": "cr", "source": "result = 1", "data": {}}))
        replies = _dispatch(self.host,
                            {"v": 2, "type": "reload", "id": "r1",
                             "context": "cr", "source": "result = 2"})
        self.assertEqual(replies[0]["type"], "reload_ack")
        self.assertEqual(replies[0]["status"], "ok")

    def test_introspect(self):
        src = "def fn(a, b=1):\n    '''doc'''\n    return a\n"
        replies = _dispatch(self.host,
                            {"v": 2, "type": "introspect", "id": "in1",
                             "source": src})
        self.assertEqual(replies[0]["status"], "ok")
        self.assertEqual(replies[0]["functions"][0]["name"], "fn")

    def test_unknown_type_is_protocol_error(self):
        replies = _dispatch(self.host, {"v": 2, "type": "nonsense", "id": "u1"})
        self.assertEqual(replies[0]["type"], "task_error")
        self.assertEqual(replies[0]["error"]["code"], "PROTOCOL_ERROR")

    def test_malformed_frame_does_not_crash(self):
        frames = self.host.handle_message("not json at all")
        self.assertEqual(len(frames), 1)
        msg = json.loads(frames[0]["text"])
        self.assertEqual(msg["type"], "task_error")

    def test_dataref_memory_only(self):
        # Big arrays above the threshold become DataRef handles; DATA_GET
        # materializes them (no file transport in the browser).
        try:
            import numpy as np
        except ImportError:  # pragma: no cover
            self.skipTest("numpy not installed")
        host = browser_host.BrowserHost({"data_ref_threshold_bytes": 8})
        src = ("import numpy as np\n"
               "def big():\n"
               "    return np.zeros(4, dtype=np.int64)\n")
        call = {"v": 2, "type": "task", "id": "d0", "command": "call",
                "context": "cd", "source": src, "function": "big", "data": {}}
        msg = _parse_frame(host.handle_message(json.dumps(call))[0])
        self.assertEqual(msg["data"]["$pb"], "data_ref")
        ref_id = msg["data"]["id"]
        get = {"v": 2, "type": "data_get", "id": "d1", "ref_id": ref_id,
               "want": "file"}
        got = _parse_frame(host.handle_message(json.dumps(get))[0])
        self.assertEqual(got["status"], "ok")
        self.assertEqual(got["data"]["$pb"], "ndarray")
        self.assertEqual(list(got["data"]["shape"]), [4])
        # release
        rel = {"v": 2, "type": "data_release", "id": "d2", "ref_id": ref_id}
        ack = _parse_frame(host.handle_message(json.dumps(rel))[0])
        self.assertEqual(ack["type"], "data_ack")
        self.assertTrue(ack["freed"])

    def test_shutdown_ack(self):
        replies = _dispatch(self.host, {"v": 2, "type": "shutdown", "id": "sd1"})
        self.assertEqual(replies[0]["type"], "shutdown_ack")
        self.assertTrue(self.host.shutdown_requested)

    def test_js_init_and_dispatch_module_api(self):
        status = json.loads(browser_host.js_init("{}"))
        self.assertEqual(status["platform"], "web")
        self.assertIn("python", status)
        out = json.loads(browser_host.js_dispatch(
            raw_text=json.dumps({"v": 2, "type": "ping", "id": "j1"})))
        self.assertEqual(out[0]["text"] and json.loads(out[0]["text"])["type"],
                         "pong")
        # Binary path via base64
        frame = protocol.build_binary(json.dumps(
            {"v": 2, "type": "ping", "id": "j2"}), [])
        out2 = json.loads(browser_host.js_dispatch(raw_b64=base64.b64encode(frame).decode()))
        self.assertEqual(json.loads(out2[0]["text"])["id"], "j2")


if __name__ == "__main__":
    unittest.main()
