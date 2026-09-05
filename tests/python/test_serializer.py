"""Unit tests: serializer type mapping and numeric-array transport."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "addons", "python_bridge", "python"))

from python_bridge import serializer  # noqa: E402

TAG = serializer.TAG


class SerializerTest(unittest.TestCase):

    def _numpy(self):
        np = serializer._try_numpy()
        if np is None:
            self.skipTest("numpy not available")
        return np

    # ------------------------------------------------------------ legacy inline
    def test_godot_inline_numeric_list_form(self):
        # Small Godot PackedFloat32Array arrives as a JSON list under "v".
        enc = {TAG: "f32", "v": [1.0, 2.5, -3.0]}
        out = serializer.decode_obj(enc, [])
        self.assertEqual(out, [1.0, 2.5, -3.0])

    def test_godot_inline_int_list_form(self):
        enc = {TAG: "i32", "v": [1, 2, 3]}
        self.assertEqual(serializer.decode_obj(enc, []), [1, 2, 3])

    # ---------------------------------------------------------- binary chunks
    def test_godot_numeric_chunk_decodes_to_ndarray(self):
        np = self._numpy()
        raw = np.arange(6, dtype=np.float32).tobytes()
        enc = {TAG: "f32", "nbytes": len(raw), "chunk": 0}
        out = serializer.decode_obj(enc, [raw])
        self.assertIsInstance(out, np.ndarray)
        self.assertEqual(out.dtype, np.dtype("float32"))
        self.assertEqual(out.tolist(), [0.0, 1.0, 2.0, 3.0, 4.0, 5.0])

    def test_godot_int64_chunk_decodes_to_ndarray(self):
        np = self._numpy()
        raw = np.array([10, 20, 30], dtype=np.int64).tobytes()
        enc = {TAG: "i64", "nbytes": len(raw), "chunk": 0}
        out = serializer.decode_obj(enc, [raw])
        self.assertEqual(out.dtype, np.dtype("int64"))
        self.assertEqual(out.tolist(), [10, 20, 30])

    def test_numeric_chunk_mismatch_falls_back_to_raw(self):
        # Descriptor declares 24 bytes but the chunk carries only 8 -> the
        # decoder must not silently materialize garbage (raw fallback).
        enc = {TAG: "f32", "nbytes": 24, "chunk": 0}
        out = serializer.decode_obj(enc, [bytes(8)])
        self.assertEqual(out, bytes(8))

    # ------------------------------------------------------------ ndarray
    def test_ndarray_roundtrip_small(self):
        np = self._numpy()
        chunks = []
        arr = np.array([[1.0, 2.0], [3.0, 4.0]], dtype=np.float64)
        enc = serializer.encode_obj(arr, chunks)
        self.assertFalse(chunks)  # 32 bytes <= INLINE_LIMIT? base64 inline
        back = serializer.decode_obj(enc, chunks)
        self.assertTrue(np.array_equal(back, arr))

    def test_ndarray_large_uses_chunk_and_validates_nbytes(self):
        np = self._numpy()
        chunks = []
        arr = np.arange(2048, dtype=np.float32)  # 8192 bytes -> chunk
        enc = serializer.encode_obj(arr, chunks)
        self.assertTrue(chunks)
        self.assertEqual(enc["nbytes"], 8192)
        back = serializer.decode_obj(enc, chunks)
        self.assertTrue(np.array_equal(back, arr))

        # Corrupt descriptor: declared nbytes disagrees -> no silent garbage.
        raw = chunks[0][:100]
        bad = dict(enc, nbytes=8192, chunk=0)
        out = serializer.decode_obj(bad, [raw])
        self.assertEqual(out, raw, "mismatch falls back to raw bytes")

    def test_bytes_blob_roundtrip(self):
        chunks = []
        enc = serializer.encode_obj({"payload": bytes(4096)}, chunks)
        self.assertTrue(chunks)
        back = serializer.decode_obj(enc, chunks)
        self.assertEqual(len(back["payload"]), 4096)

    def test_dict_with_numeric_keys_coerced(self):
        enc = serializer.encode_obj({1: "a", 2.5: "b"}, [])
        # Keys are coerced to str so JSON stays safe.
        self.assertEqual(enc["v"], {"1": "a", "2.5": "b"})


if __name__ == "__main__":
    unittest.main()
