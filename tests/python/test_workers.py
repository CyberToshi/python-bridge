"""Unit tests: Phase 3 - Kontext-Locks, kooperative Cancellation."""

import os
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "addons", "python_bridge", "python"))

from python_bridge import executor, protocol  # noqa: E402


class ContextLockTest(unittest.TestCase):

    def setUp(self):
        self.host = executor.ScriptHost()

    def test_same_context_is_serialized(self):
        holder = []
        with self.host.acquire_contexts(["a"]):
            def worker():
                with self.host.acquire_contexts(["a"]):
                    holder.append("entered")
            t = threading.Thread(target=worker)
            t.start()
            time.sleep(0.15)
            self.assertEqual(holder, [], "same context must block while held")
        t.join(2.0)
        self.assertEqual(holder, ["entered"])

    def test_different_contexts_do_not_block(self):
        with self.host.acquire_contexts(["a"]):
            holder = []

            def worker():
                with self.host.acquire_contexts(["b"]):
                    holder.append("entered")

            t = threading.Thread(target=worker)
            t.start()
            t.join(1.0)
            self.assertEqual(holder, ["entered"],
                             "independent contexts may run in parallel")

    def test_multi_context_acquire_is_deadlock_free_by_ordering(self):
        # Zwei Threads sperren dieselben Contexts in unterschiedlicher
        # Eingabe-Reihenfolge. Intern wird sortiert -> kein Deadlock,
        # Ausfuehrung strikt serialisiert.
        import threading as _th
        order = []
        release = _th.Event()

        def first():
            with self.host.acquire_contexts(["b", "a"]):
                order.append(1)
                release.wait(2.0)

        def second():
            with self.host.acquire_contexts(["a", "b"]):
                order.append(2)

        t1 = _th.Thread(target=first)
        t2 = _th.Thread(target=second)
        t1.start()
        time.sleep(0.1)
        t2.start()
        time.sleep(0.2)
        self.assertEqual(order, [1], "second must wait for the shared context")
        release.set()
        t1.join(2.0)
        t2.join(2.0)
        self.assertEqual(order, [1, 2])

    def test_context_created_on_demand(self):
        with self.host.acquire_contexts(["fresh"]):
            pass


class CooperativeCancelTest(unittest.TestCase):

    def setUp(self):
        self.host = executor.ScriptHost()

    def test_checkpoint_aborts_mid_run(self):
        src = ("import time\n"
               "for i in range(200000):\n"
               "    __bridge__.checkpoint()\n"
               "    if i % 400 == 0:\n"
               "        time.sleep(0.002)\n"
               "result = 'done'\n")
        message = {"v": protocol.PROTOCOL_VERSION, "id": "mid1",
                   "command": protocol.CMD_RUN, "context": "cc",
                   "source": src, "data": {"input": None}}
        out = []

        def run_job():
            out.append(self.host.execute_job(message))

        t = threading.Thread(target=run_job)
        t.start()
        time.sleep(0.2)
        self.host.mark_cancelled("mid1")
        t.join(5.0)
        body = out[0]
        self.assertEqual(body["status"], "cancelled",
                         "checkpoint must abort with status=cancelled")
        self.assertEqual(body["error"]["type"], "CancelledError")

    def test_cancel_requested_is_sticky(self):
        # Das Flag bleibt fuer die Laufzeit des Jobs bestehen: Muster wie
        # `while not cancel_requested()` oder `if cancel_requested():
        # checkpoint()` bleiben sonst nach dem ersten Lesen blind. Erst
        # consume_cancelled() beim Job-Start raeumt das Set auf.
        _ = executor._local
        executor._local.job_id = "j1"
        try:
            self.host.mark_cancelled("j1")
            self.assertTrue(self.host.cancel_requested_for_current())
            self.assertTrue(self.host.cancel_requested_for_current(),
                            "flag is sticky within the same job")
        finally:
            executor._local.job_id = None

    def test_no_cancel_without_job(self):
        self.assertFalse(self.host.cancel_requested_for_current())

    def test_cancel_before_start_returns_cancelled(self):
        src = "result = 1\n"
        message = {"v": protocol.PROTOCOL_VERSION, "id": "pre1",
                   "command": protocol.CMD_RUN, "context": "cc2",
                   "source": src, "data": {"input": None}}
        self.host.mark_cancelled("pre1")
        body = self.host.execute_job(message)
        self.assertEqual(body["status"], "cancelled")
        self.assertFalse("data" in body)

    def test_bridge_helper_injected_into_context(self):
        src = "marker = __bridge__ is not None\nresult = marker\n"
        result, err = self.host.run("helper_ctx", src, None)
        self.assertIsNone(err)
        self.assertIs(result, True)


if __name__ == "__main__":
    unittest.main()
