"""Nachrichten-Protokoll (Python-Seite).

Frame-Typen (ein WebSocket-Frame = eine Nachricht):
  Text: reines JSON.
  Binary: U32LE(Header-Länge) + HeaderJSON(utf8) +
          Liste aus [U32LE(Chunk-Länge) + Chunk-Bytes].
"""
import json
import struct

PROTOCOL_VERSION = 1


def build_text(message):
    return json.dumps(message)


def build_binary(header, chunks):
    head = header.encode("utf-8")
    out = struct.pack("<I", len(head)) + head
    for chunk in chunks:
        out += struct.pack("<I", len(chunk)) + chunk
    return out


def parse(raw):
    """Liefert (message_dict, decoded_data)."""
    if isinstance(raw, str):
        try:
            return json.loads(raw), None
        except json.JSONDecodeError:
            return {"type": "malformed"}, None

    if isinstance(raw, (bytes, bytearray)):
        data = memoryview(bytes(raw))
        if len(data) < 4:
            return {"type": "malformed"}, None
        (hlen,) = struct.unpack("<I", data[:4])
        if len(data) < 4 + hlen:
            return {"type": "malformed"}, None
        header = bytes(data[4:4 + hlen]).decode("utf-8")
        try:
            message = json.loads(header)
        except json.JSONDecodeError:
            return {"type": "malformed"}, None

        from . import serializer

        chunks = []
        off = 4 + hlen
        m = len(data)
        while off + 4 <= m:
            (clen,) = struct.unpack("<I", data[off:off + 4])
            chunks.append(bytes(data[off + 4:off + 4 + clen]))
            off += 4 + clen

        value = message.get("data")
        decoded = serializer.decode_obj(value, chunks) if value is not None else None
        return message, decoded

    return {"type": "malformed"}, None