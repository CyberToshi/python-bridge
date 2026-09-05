"""Unit tests: protocol frames (text + binary chunks, batch items)."""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "addons", "python_bridge", "python"))

from python_bridge import protocol, serializer


class ProtocolTest(unittest.TestCase):

    def test_text_roundtrip(self):
        msg = {"v": 2, "type": protocol.MSG_TASK, "id": "t1",
               "command": "call", "data": {"args": [1, "x"]}}
        back, data = protocol.parse(protocol.build_text(msg))
        self.assertEqual(back["id"], "t1")
        self.assertEqual(back["type"], protocol.MSG_TASK)
        self.assertEqual(back["data"]["args"], [1, "x"])

    def test_binary_chunk_roundtrip(self):
        chunks = []
        enc = serializer.encode_obj({"blob": bytes(4096)}, chunks)
        self.assertTrue(chunks, "large blob must be chunked")
        head = {"v": 2, "type": protocol.MSG_TASK_RESULT, "id": "t1",
                "status": "ok", "data": enc}
        frame = protocol.build_binary(json.dumps(head), chunks)
        back, _ = protocol.parse(frame)
        self.assertEqual(len(back["data"]["blob"]), 4096)

    def test_small_blob_inline(self):
        chunks = []
        enc = serializer.encode_obj({"b": bytes(10)}, chunks)
        self.assertFalse(chunks, "small blob stays inline")
        # enc == {$pb: dict, v: {b: {$pb: bytes, b: base64}}}
        self.assertIn("b", enc["v"]["b"])

    def test_batch_items_decoded(self):
        items = [
            {"id": "a", "status": "ok", "data": serializer.encode_obj(42, [])},
            {"id": "b", "status": "error",
             "error": {"code": protocol.CATEGORY_PYTHON_EXCEPTION,
                       "type": "ValueError", "message": "boom", "traceback": ""}},
        ]
        head = {"v": 2, "type": protocol.MSG_BATCH_RESULT, "id": "b1",
                "items": items}
        back, _ = protocol.parse(protocol.build_text(head))
        self.assertEqual(back[protocol.FIELD_ITEMS][0]["data"], 42)
        self.assertEqual(back[protocol.FIELD_ITEMS][1]["error"]["type"], "ValueError")

    def test_malformed(self):
        msg, _ = protocol.parse("not json {")
        self.assertEqual(msg.get("type"), "malformed")
        msg2, _ = protocol.parse(b"\x01\x02")
        self.assertEqual(msg2.get("type"), "malformed")

    def test_build_binary_matches_legacy_layout(self):
        """Der bytearray-basierte Builder muss byte-identisch zum alten
        Layout sein (U32LE(header_len) + header + je U32LE(chunk_len)+chunk)."""
        head = json.dumps({"v": 2, "type": "task_result", "id": "x"})
        chunks = [bytes(i) for i in range(7)] + [bytes(4096)]
        out = protocol.build_binary(head, chunks)
        import struct
        (hlen,) = struct.unpack("<I", out[:4])
        self.assertEqual(out[4:4 + hlen].decode("utf-8"), head)
        off = 4 + hlen
        idx = 0
        while off + 4 <= len(out):
            (clen,) = struct.unpack("<I", out[off:off + 4])
            self.assertEqual(out[off + 4:off + 4 + clen], chunks[idx])
            off += 4 + clen
            idx += 1
        self.assertEqual(idx, len(chunks))
        self.assertEqual(off, len(out))

    def test_build_binary_empty_chunks(self):
        head = json.dumps({"v": 2, "type": "ping", "id": "p"})
        out = protocol.build_binary(head, [])
        # build_binary erzeugt immer den U32LE(header_len)-Rahmen; der
        # Header-Bereich muss exakt dem JSON-String entsprechen.
        import struct
        (hlen,) = struct.unpack("<I", out[:4])
        self.assertEqual(hlen, len(head))
        self.assertEqual(out[4:4 + hlen].decode("utf-8"), head)
        self.assertEqual(len(out), 4 + len(head))


if __name__ == "__main__":
    unittest.main()