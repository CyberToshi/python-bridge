"""Tests fuer die Review-Fixes 2.7 / 4.2 / 4.3.

2.7: Result-Budget-Vorabpruefung (_estimated_size + _ref_or_encode +
     _job_fn-Uebersetzung in strukturierte SERIALIZATION_ERROR-Antworten,
     single und batch).
4.2: Consumer drainiert die Queue bei Shutdown und antwortet geordnet
     (getestet ueber die importierbare Helper-Funktion).
4.3: _exit_code_for ordnet Exceptions den Exit-Codes zu.
"""

import asyncio
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "addons", "python_bridge", "python"))

from python_bridge import protocol, server  # noqa: E402


def _task_message(msg_id, result):
    return {"v": protocol.PROTOCOL_VERSION, "type": protocol.MSG_TASK,
            "id": msg_id, "script": "s.py", "function": "f", "args": [],
            "result": result}


class _FakeStore:
    """DataStore-Ersatz: macht nie Auto-Ref (nur fuer Budget-Pfade)."""

    def maybe_ref(self, value):
        return None


class _FakeHost:
    """Host-Ersatz: liefert ein vorgegebenes Ergebnis als ok-Body."""

    def __init__(self, data):
        self._data = data

    def acquire_contexts(self, names):
        import contextlib
        return contextlib.nullcontext()

    def unique_contexts(self, message):
        return []

    def execute_job(self, message):
        return {"status": "ok", "data": self._data, "ms": 1,
                "stdout": "", "stderr": "",
                "stdout_truncated": False, "stderr_truncated": False}


class TestEstimatedSize(unittest.TestCase):
    def test_ndarray_exact(self):
        np = server._try_numpy()
        if np is None:
            self.skipTest("numpy nicht installiert")
        arr = np.zeros((10, 10), dtype=np.float64)  # 800 bytes
        est = server._estimated_size(arr)
        self.assertGreaterEqual(est, 800)

    def test_scalars_and_strings(self):
        # Kleine Werte bleiben unter jedem realen Budget
        est = server._estimated_size({"a": 1, "b": ["x", "y"]})
        self.assertGreater(est, 0)
        self.assertLess(est, 100_000)

    def test_large_list_exceeds_budget(self):
        budget = 1 * 1024 * 1024  # 1 MB
        big = list(range(500_000))  # ~4+ MB als Python-Liste
        self.assertGreater(server._estimated_size(big), budget)

    def test_cyclic_dict_no_hang(self):
        d = {"a": 1}
        d["self"] = d  # Zyklus: naive Rekursion wuerde hier abstuerzen/haengen
        # Muss terminieren (Knoten-Budget) und einen endlichen Wert liefern
        est = server._estimated_size(d)
        self.assertGreater(est, 0)

    def test_deep_nesting_no_recursion_error(self):
        deep = cur = {}
        for _ in range(50_000):
            cur["n"] = {}
            cur = cur["n"]
        est = server._estimated_size(deep)
        self.assertGreater(est, 0)


class TestRefOrEncodeBudget(unittest.TestCase):
    def test_ref_wins_over_budget(self):
        """DataRef-Auslagerung bleibt die bessere Antwort: grosse ndarrays
        mit aktivem Store werden ausgelagert, bevor das Budget greift."""
        np = server._try_numpy()
        if np is None:
            self.skipTest("numpy nicht installiert")
        from python_bridge.data_registry import DataStore

        class RefStore(_FakeStore):
            def maybe_ref(self, value):
                return {"$pb": "data_ref", "ref_id": "r1"}

        arr = np.zeros(1000, dtype=np.float64)
        chunks = []
        out = server._ref_or_encode(arr, RefStore(), chunks, result_budget=1024)
        self.assertEqual(out.get("$pb"), "data_ref")
        self.assertEqual(chunks, [])

    def test_budget_refuses_before_encoding(self):
        big = list(range(500_000))
        with self.assertRaises(server.ResultTooLargeError):
            server._ref_or_encode(big, _FakeStore(), [], result_budget=64_000)

    def test_no_budget_encodes_normally(self):
        from python_bridge.serializer import decode_obj
        chunks = []
        out = server._ref_or_encode([1, 2, 3], _FakeStore(), chunks)
        # Listen werden getaggt kodiert - Rueckweg muss den Originalwert
        # rekonstruieren (echter Roundtrip statt Direktvergleich).
        self.assertEqual(decode_obj(out, chunks), [1, 2, 3])


class TestJobFnBudget(unittest.TestCase):
    def test_single_task_translated_error(self):
        msg = _task_message("t1", result=None)
        host = _FakeHost(list(range(500_000)))
        result = server._job_fn(host, _FakeStore(), msg, max_result_bytes=64_000)
        body = result["body"]
        self.assertEqual(body["status"], "error")
        self.assertEqual(body["error"]["code"],
                         protocol.CATEGORY_SERIALIZATION_ERROR)
        self.assertIn("ResultTooLargeError", body["error"]["type"])

    def test_batch_item_translated_error(self):
        np = server._try_numpy()
        if np is None:
            self.skipTest("numpy nicht installiert")
        msg = {"v": protocol.PROTOCOL_VERSION, "type": protocol.MSG_BATCH,
               "id": "b1", "items": [
                   _task_message("i1", result=None),
                   _task_message("i2", result=None)]}
        host = _FakeHost(np.zeros(2000, dtype=np.float64))
        result = server._job_fn(host, _FakeStore(), msg, max_result_bytes=1024)
        self.assertTrue(result["batch"])
        statuses = [item["status"] for item in result["items"]]
        self.assertEqual(statuses, ["error", "error"])
        for item in result["items"]:
            self.assertEqual(item["error"]["code"],
                             protocol.CATEGORY_SERIALIZATION_ERROR)

    def test_normal_result_unaffected(self):
        msg = _task_message("t1", result=None)
        host = _FakeHost({"answer": 42})
        result = server._job_fn(host, _FakeStore(), msg, max_result_bytes=1_000_000)
        self.assertEqual(result["body"]["status"], "ok")

    def test_budget_disabled_by_default(self):
        """Legacy-Signatur (kein max_result_bytes) bleibt ausgehfähig."""
        msg = _task_message("t1", result=None)
        host = _FakeHost(list(range(500_000)))
        result = server._job_fn(host, _FakeStore(), msg)
        self.assertEqual(result["body"]["status"], "ok")


class TestShutdownDrain(unittest.TestCase):
    """4.2: Der Drain-Helfer antwortet geordnet auf verbleibende Jobs."""

    def test_drain_responds_to_pending_jobs(self):
        messages = []
        queue = asyncio.Queue()
        pending = [{"id": "a"}, {"id": "b"}, {"id": "c"}]
        for m in pending:
            queue.put_nowait(m)

        async def scenario():
            await server._drain_queue_for_shutdown(queue, messages.append)

        asyncio.run(scenario())
        self.assertEqual(len(messages), 3)
        for m in messages:
            self.assertEqual(m["type"], protocol.MSG_TASK_ERROR)
            self.assertEqual(m["error"]["code"],
                             protocol.CATEGORY_CONNECTION_ERROR)
        self.assertTrue(queue.empty())

    def test_drain_survives_failing_sender(self):
        """Send-Fehler (bereits geschlossene Verbindung) duerfen den Drain
        nicht abbrechen - best effort, alle Jobs werden geleert."""
        failures = []

        def failing_send(body):
            failures.append(body)
            raise RuntimeError("connection closed")

        queue = asyncio.Queue()
        for m in ({"id": "x"}, {"id": "y"}):
            queue.put_nowait(m)

        async def scenario():
            await server._drain_queue_for_shutdown(queue, failing_send)

        asyncio.run(scenario())
        self.assertEqual(len(failures), 2)
        self.assertTrue(queue.empty())

    def test_drain_empty_queue(self):
        messages = []
        queue = asyncio.Queue()

        async def scenario():
            await server._drain_queue_for_shutdown(queue, messages.append)

        asyncio.run(scenario())
        self.assertEqual(messages, [])


class TestExitCode(unittest.TestCase):
    def test_clean_exits(self):
        self.assertEqual(server._exit_code_for(None), 0)
        self.assertEqual(server._exit_code_for(SystemExit(0)), 0)
        self.assertEqual(server._exit_code_for(KeyboardInterrupt()), 0)
        self.assertEqual(server._exit_code_for(asyncio.CancelledError()), 0)

    def test_error_exit(self):
        self.assertEqual(server._exit_code_for(RuntimeError("websockets fehlt")), 1)
        try:
            raise ValueError("boom")
        except ValueError as exc:
            self.assertEqual(server._exit_code_for(exc), 1)


if __name__ == "__main__":
    unittest.main()
