"""Unit tests: ScriptHost executor semantics."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "addons", "python_bridge", "python"))

from python_bridge import executor, protocol


class ExecutorTest(unittest.TestCase):

    def setUp(self):
        self.host = executor.ScriptHost()

    def test_define_then_call(self):
        src = "def add(a, b):\n    return a + b\n"
        _, err = self.host.define("ctx", src)
        self.assertIsNone(err)
        result, err = self.host.call("ctx", src, "add", [2, 3], {})
        self.assertIsNone(err)
        self.assertEqual(result, 5)

    def test_call_source_change_redefines(self):
        v1 = "def add(a, b):\n    return a + b\n"
        v2 = "def add(a, b):\n    return a * b\n"
        self.host.call("ctx", v1, "add", [2, 3], {})
        result, err = self.host.call("ctx", v2, "add", [2, 3], {})
        self.assertIsNone(err)
        self.assertEqual(result, 6)

    def test_missing_function(self):
        result, err = self.host.call("ctx", "x = 1\n", "nope", [], {})
        self.assertIsNone(result)
        self.assertEqual(err["code"], protocol.CATEGORY_PYTHON_EXCEPTION)
        self.assertEqual(err["type"], "AttributeError")

    def test_exception_structured(self):
        src = "def boom():\n    raise ValueError('kaputt')\n"
        result, err = self.host.call("ctx", src, "boom", [], {})
        self.assertIsNone(result)
        self.assertEqual(err["code"], protocol.CATEGORY_PYTHON_EXCEPTION)
        self.assertEqual(err["type"], "ValueError")
        self.assertIn("kaputt", err["message"])
        self.assertIn("ValueError", err["traceback"])

    def test_syntax_error(self):
        result, err = self.host.run("ctx", "def broken(:\n", {})
        self.assertIsNone(result)
        self.assertEqual(err["type"], "SyntaxError")

    def test_run_input_result(self):
        result, err = self.host.run("ctx", "result = input['x'] * 2", {"x": 21})
        self.assertIsNone(err)
        self.assertEqual(result, 42)

    def test_contexts_isolated(self):
        self.host.run("a", "shared = 1\nresult = shared", {})
        result, _ = self.host.run("b", "result = 'ok'", {})
        self.assertEqual(result, "ok")
        # context a still has its state
        result, _ = self.host.run("a", "result = shared", {})
        self.assertEqual(result, 1)

    def test_reload_context(self):
        v1 = "def f():\n    return 1\n"
        v2 = "def f():\n    return 2\n"
        self.host.call("ctx", v1, "f", [], {})
        _, err = self.host.reload_context("ctx", v2)
        self.assertIsNone(err)
        result, err = self.host.call("ctx", v2, "f", [], {})
        self.assertEqual(result, 2)

    def test_job_stdout_capture(self):
        job = {"id": "j1", "command": "run", "context": "c",
               "source": "print('hi')\nresult = 1", "data": {}}
        body = self.host.execute_job(job)
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["stdout"], "hi\n")
        self.assertEqual(body["data"], 1)

    def test_job_cancel_checked(self):
        self.host.mark_cancelled("j9")
        job = {"id": "j9", "command": "run", "context": "c",
               "source": "result = 1", "data": {}}
        body = self.host.execute_job(job)
        self.assertEqual(body["status"], "cancelled")
        # second call consumes the cancel marker
        body = self.host.execute_job(job)
        self.assertEqual(body["status"], "ok")

    def test_kwargs_call(self):
        src = "def greet(greeting, name):\n    return greeting + ' ' + name\n"
        result, err = self.host.call("ctx", src, "greet", [],
                                     {"greeting": "hi", "name": "x"})
        self.assertIsNone(err)
        self.assertEqual(result, "hi x")

    def test_stdout_truncated_at_cap(self):
        host = executor.ScriptHost(max_stdout_bytes=16, max_stderr_bytes=16)
        job = {"id": "jcap", "command": "run", "context": "c",
               "source": "print('x' * 100)\nresult = 1", "data": {}}
        body = host.execute_job(job)
        self.assertEqual(body["status"], "ok")
        self.assertEqual(len(body["stdout"]), 16)
        self.assertTrue(body["stdout_truncated"])
        self.assertFalse(body["stderr_truncated"])

    def test_configure_caps(self):
        host = executor.ScriptHost()
        host.configure(max_stdout_bytes=8, max_stderr_bytes=8)
        job = {"id": "jcap2", "command": "run", "context": "c",
               "source": "print('abcdefghij')\nresult = 1", "data": {}}
        body = host.execute_job(job)
        self.assertEqual(body["stdout"], "abcdefgh")
        self.assertTrue(body["stdout_truncated"])


if __name__ == "__main__":
    unittest.main()