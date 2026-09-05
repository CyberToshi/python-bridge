"""Unit tests: per-connection DataStore (DataRef handles)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "addons", "python_bridge", "python"))

from python_bridge.data_registry import DataStore  # noqa: E402

TAG = "$pb"


class DataRegistryTest(unittest.TestCase):

    def _numpy(self):
        try:
            import numpy as np
            return np
        except ImportError:  # pragma: no cover
            self.skipTest("numpy not available")

    def test_threshold_zero_disables_refs(self):
        store = DataStore(threshold_bytes=0)
        np = self._numpy()
        arr = np.arange(10**6, dtype=np.float32)
        self.assertIsNone(store.maybe_ref(arr))
        self.assertEqual(store.count(), 0)

    def test_below_threshold_stays_direct(self):
        store = DataStore(threshold_bytes=1024)
        np = self._numpy()
        small = np.arange(8, dtype=np.float32)  # 32 bytes
        self.assertIsNone(store.maybe_ref(small))
        self.assertEqual(store.count(), 0)

    def test_above_threshold_stored_as_ref(self):
        store = DataStore(threshold_bytes=64)
        np = self._numpy()
        arr = np.arange(100, dtype=np.float64)  # 800 bytes
        desc = store.maybe_ref(arr)
        self.assertIsNotNone(desc)
        self.assertEqual(desc[TAG], "data_ref")
        self.assertEqual(desc["kind"], "ndarray")
        self.assertEqual(desc["dtype"], "float64")
        self.assertEqual(desc["shape"], [100])
        self.assertEqual(desc["nbytes"], 800)
        self.assertTrue(desc["readonly"])
        self.assertEqual(store.count(), 1)

        # Multiple materializations return the same values.
        value, meta = store.get(desc["id"])
        self.assertIs(value, arr)
        self.assertIsNotNone(meta)
        value2, _ = store.get(desc["id"])
        self.assertIs(value2, arr)

    def test_unsupported_kinds_never_stored(self):
        store = DataStore(threshold_bytes=1)
        self.assertIsNone(store.maybe_ref([1, 2, 3], kind="ndarray"))
        self.assertEqual(store.count(), 0)

    def test_release_and_stale(self):
        store = DataStore(threshold_bytes=64)
        np = self._numpy()
        arr = np.zeros(100, dtype=np.float32)
        desc = store.maybe_ref(arr)
        self.assertIsNotNone(desc)
        self.assertTrue(store.release(desc["id"]))
        self.assertFalse(store.release(desc["id"]), "double release is a no-op")
        self.assertEqual(store.get(desc["id"]), (None, None))
        self.assertIsNone(store.describe(desc["id"]))

    def test_clear_releases_everything(self):
        store = DataStore(threshold_bytes=64)
        np = self._numpy()
        for i in range(3):
            store.maybe_ref(np.zeros(100, dtype=np.float32))
        self.assertEqual(store.count(), 3)
        store.clear()
        self.assertEqual(store.count(), 0)

    def test_non_contiguous_input_is_handled(self):
        store = DataStore(threshold_bytes=16)
        np = self._numpy()
        base = np.zeros((10, 10), dtype=np.float32)
        view = base[::2, ::2]  # non-contiguous slice
        desc = store.maybe_ref(view)
        self.assertIsNotNone(desc)
        self.assertEqual(desc["shape"], list(view.shape))
        self.assertEqual(desc["nbytes"], int(view.nbytes))
        value, _ = store.get(desc["id"])
        self.assertTrue(np.array_equal(value, np.ascontiguousarray(view)))


if __name__ == "__main__":
    unittest.main()
