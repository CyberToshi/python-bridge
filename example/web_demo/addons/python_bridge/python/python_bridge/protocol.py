"""Message protocol (Python side), version 2.

Frame types (one WebSocket frame = one message):
  Text:   plain JSON.
  Binary: U32LE(header length) + HeaderJSON(utf8) +
          list of [U32LE(chunk length) + chunk bytes].

Every message has the shape:
  {"v": 2, "type": "<TYPE>", "id": "<id>", ...payload}

Task responses:
  {"v": 2, "type": "task_result", "id": "<task>", "status": "ok",
   "data": <serialized>, "ms": <int>}
  {"v": 2, "type": "task_error", "id": "<task>",
   "error": {code, type, message, traceback}, "ms": <int>}

Batch responses carry per-item results in FIELD_ITEMS; each item's "data"
is serialized into the same chunk stream so binary payloads stay efficient.
"""

import json
import struct

PROTOCOL_VERSION = 2

# --- Message types (must match addons/python_bridge/core/protocol.gd) --------
MSG_HELLO = "hello"
MSG_HELLO_ACK = "hello_ack"
MSG_TASK = "task"
MSG_TASK_RESULT = "task_result"
MSG_TASK_ERROR = "task_error"
MSG_BATCH = "batch"
MSG_BATCH_RESULT = "batch_result"
MSG_CANCEL = "cancel"
MSG_CANCEL_ACK = "cancel_ack"
MSG_PING = "ping"
MSG_PONG = "pong"
MSG_RELOAD = "reload"
MSG_RELOAD_ACK = "reload_ack"
MSG_INTROSPECT = "introspect"
MSG_INTROSPECT_RESULT = "introspect_result"
MSG_DATA_GET = "data_get"          # materialize a DataRef handle
MSG_DATA_RESULT = "data_result"     # response carrying the data
MSG_DATA_RELEASE = "data_release"   # free a DataRef handle
MSG_DATA_ACK = "data_ack"           # release confirmation
MSG_STATUS = "status"
MSG_EVENT = "event"
MSG_SHUTDOWN = "shutdown"
MSG_SHUTDOWN_ACK = "shutdown_ack"

# Task command kinds
CMD_RUN = "run"
CMD_CALL = "call"
CMD_DEFINE = "define"

# Field holding batch items in batch messages (both directions)
FIELD_ITEMS = "items"

# Error categories (mirror core/error_handler.gd)
CATEGORY_BRIDGE_ERROR = "BRIDGE_ERROR"
CATEGORY_PROCESS_ERROR = "PROCESS_ERROR"
CATEGORY_CONNECTION_ERROR = "CONNECTION_ERROR"
CATEGORY_PYTHON_EXCEPTION = "PYTHON_EXCEPTION"
CATEGORY_SERIALIZATION_ERROR = "SERIALIZATION_ERROR"
CATEGORY_TIMEOUT_ERROR = "TIMEOUT_ERROR"
CATEGORY_DEPENDENCY_ERROR = "DEPENDENCY_ERROR"
CATEGORY_PROTOCOL_ERROR = "PROTOCOL_ERROR"
CATEGORY_TASK_ERROR = "TASK_ERROR"


def build_text(message):
    return json.dumps(message)


def build_binary(header, chunks):
    """Header + chunks als ein Binary-Frame.

    Verwendet einen vorab allokierten bytearray anstelle wiederholter
    bytes-Konkatenation (O(n^2) -> O(n)); grosse Payloads erzeugen so keine
    wachsenden Zwischenkopien.
    """
    head = header.encode("utf-8")
    total = 4 + len(head)
    for chunk in chunks:
        total += 4 + len(chunk)
    out = bytearray(total)
    struct.pack_into("<I", out, 0, len(head))
    pos = 4
    out[pos:pos + len(head)] = head
    pos += len(head)
    for chunk in chunks:
        struct.pack_into("<I", out, pos, len(chunk))
        pos += 4
        out[pos:pos + len(chunk)] = chunk
        pos += len(chunk)
    return bytes(out)


def build_response(msg_type, msg_id, status, data=None, error=None, ms=0):
    """Response envelope (task_result / task_error)."""
    msg = {"v": PROTOCOL_VERSION, "type": msg_type, "id": msg_id,
           "status": status, "ms": ms}
    if status == "ok":
        msg["data"] = data
    else:
        msg["error"] = error
    return msg


def parse(raw):
    """Returns (message_dict, decoded_data). Batch item data fields are
    decoded in place into message[FIELD_ITEMS]."""
    if isinstance(raw, str):
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            return {"type": "malformed"}, None
        _decode_in_place(msg, [])
        return msg, msg.get("data")

    if isinstance(raw, (bytes, bytearray)):
        data = memoryview(bytes(raw))
        if len(data) < 4:
            return {"type": "malformed"}, None
        (hlen,) = struct.unpack("<I", data[:4])
        if len(data) < 4 + hlen:
            return {"type": "malformed"}, None
        header = bytes(data[4:4 + hlen]).decode("utf-8")
        try:
            msg = json.loads(header)
        except json.JSONDecodeError:
            return {"type": "malformed"}, None

        chunks = []
        off = 4 + hlen
        m = len(data)
        while off + 4 <= m:
            (clen,) = struct.unpack("<I", data[off:off + 4])
            chunks.append(bytes(data[off + 4:off + 4 + clen]))
            off += 4 + clen

        _decode_in_place(msg, chunks)
        return msg, msg.get("data")

    return {"type": "malformed"}, None


def _decode_in_place(msg, chunks):
    """Decodes the serialized top-level "data" and any batch item "data"
    fields using the shared chunk stream."""
    if not isinstance(msg, dict):
        return
    from . import serializer
    if "data" in msg and msg["data"] is not None:
        msg["data"] = serializer.decode_obj(msg["data"], chunks)
    if FIELD_ITEMS in msg and isinstance(msg[FIELD_ITEMS], list):
        items = msg[FIELD_ITEMS]
        for i, item in enumerate(items):
            if isinstance(item, dict) and "data" in item and item["data"] is not None:
                items[i] = dict(item)
                items[i]["data"] = serializer.decode_obj(item["data"], chunks)