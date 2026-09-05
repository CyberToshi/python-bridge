"""Unit tests: per-connection DataStore (DataRef handles)."""

import hashlib
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "addons", "python_bridge", "python"))

from python_bridge.data_registry import (  # noqa: E402
    DataStore,
    cleanup_orphan_files,
)

TAG = "$pb"


class DataFileBackingTest(unittest.TestCase):
    """Phase 4: Datei-basierte DataRefs (FileAccess-Gegenstueck)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="pb_datafile_")
        self.store = DataStore(threshold_bytes=64, file_dir=self.tmp, tag="instA")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_store_writes_file_with_metadata(self):
        np = self._numpy()
        arr = np.arange(100, dtype=np.float64)  # 800 bytes
        desc = self.store.maybe_ref(arr)
        self.assertIsNotNone(desc)
        path = os.path.join(self.tmp, "data-instA-%s.bin" % desc["id"])
        self.assertTrue(os.path.exists(path), "file-backed ref writes a file")
        raw = open(path, "rb").read()
        self.assertEqual(len(raw), 800)
        self.assertEqual(desc["nbytes"], 800)

        info = self.store.file_info(desc["id"])
        self.assertIsNotNone(info)
        self.assertEqual(info["size"], 800)
        self.assertEqual(info["dtype"], "float64")
        self.assertEqual(info["shape"], [100])
        self.assertEqual(
            info["sha256"], hashlib.sha256(raw).hexdigest(),
            "descriptor carries the checksum")

    def test_release_deletes_file(self):
        np = self._numpy()
        desc = self.store.maybe_ref(np.zeros(100, dtype=np.float32))
        path = os.path.join(self.tmp, "data-instA-%s.bin" % desc["id"])
        self.assertTrue(os.path.exists(path))
        self.assertTrue(self.store.release(desc["id"]))
        self.assertFalse(os.path.exists(path), "release must delete the file")
        self.assertIsNone(self.store.file_info(desc["id"]))

    def test_clear_deletes_all_files(self):
        np = self._numpy()
        ids = []
        for i in range(3):
            desc = self.store.maybe_ref(np.zeros(100, dtype=np.float32))
            ids.append(desc["id"])
        self.assertEqual(len(os.listdir(self.tmp)), 3)
        self.store.clear()
        self.assertEqual(os.listdir(self.tmp), [], "clear removes all data files")

    def test_without_file_dir_no_files_are_written(self):
        mem_store = DataStore(threshold_bytes=64)
        np = self._numpy()
        desc = mem_store.maybe_ref(np.zeros(100, dtype=np.float32))
        self.assertIsNotNone(desc)
        self.assertIsNone(mem_store.file_info(desc["id"]))

    def test_file_info_absent_when_file_deleted_externally(self):
        np = self._numpy()
        desc = self.store.maybe_ref(np.zeros(100, dtype=np.float32))
        path = os.path.join(self.tmp, "data-instA-%s.bin" % desc["id"])
        os.remove(path)
        self.assertIsNone(self.store.file_info(desc["id"]),
                          "missing file disables the file transport")

    def test_cleanup_orphan_files_only_own_tag(self):
        # Verwaiste Dateien der eigenen Instanz werden entfernt, fremde
        # Instanzen (parallele Prozesse) bleiben unberuehrt.
        stale = os.path.join(self.tmp, "data-instA-dead-1.bin")
        foreign = os.path.join(self.tmp, "data-instB-live-2.bin")
        with open(stale, "wb") as f:
            f.write(b"x" * 16)
        with open(foreign, "wb") as f:
            f.write(b"y" * 16)
        removed = cleanup_orphan_files(self.tmp, "instA")
        self.assertEqual(removed, 1)
        self.assertFalse(os.path.exists(stale))
        self.assertTrue(os.path.exists(foreign))

    def _numpy(self):
        try:
            import numpy as np
            return np
        except ImportError:  # pragma: no cover
            self.skipTest("numpy not available")


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
