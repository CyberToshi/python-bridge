class_name PythonProtocol
extends RefCounted
## Versioned message protocol (v2).
##
## Frame types (one WebSocket frame = one message):
##   Text:   plain JSON.
##   Binary: U32LE(header length) + HeaderJSON(utf8) +
##           list of [U32LE(chunk length) + chunk bytes].
##
## Every message has the shape:
##   { "v": 2, "type": "<TYPE>", "id": "<id>", ...payload }
##
## Response envelopes (task / batch):
##   { "v": 2, "type": "task_result", "id": "<task>", "status": "ok",
##     "data": <serialized>, "ms": <int> }
##   { "v": 2, "type": "task_error",  "id": "<task>",
##     "error": {code, type, message, traceback}, "ms": <int> }
##
## Large binary payloads never travel inside the JSON header: the serializer
## appends them to `chunks`, which are carried after the header in binary
## frames (see PythonBridgeSerializer / type_mapper.gd).

const PROTOCOL_VERSION := 2

# --- Message types -----------------------------------------------------------
const MSG_HELLO := "hello"
const MSG_HELLO_ACK := "hello_ack"
const MSG_TASK := "task"                # single task (command: run|call|define)
const MSG_TASK_RESULT := "task_result"
const MSG_TASK_ERROR := "task_error"
const MSG_BATCH := "batch"              # multiple tasks in one frame
const MSG_BATCH_RESULT := "batch_result"
const MSG_CANCEL := "cancel"
const MSG_CANCEL_ACK := "cancel_ack"
const MSG_PING := "ping"
const MSG_PONG := "pong"
const MSG_RELOAD := "reload"
const MSG_RELOAD_ACK := "reload_ack"
const MSG_INTROSPECT := "introspect"
const MSG_INTROSPECT_RESULT := "introspect_result"
const MSG_DATA_GET := "data_get"          # materialize a DataRef handle
const MSG_DATA_RESULT := "data_result"     # response carrying the data
const MSG_DATA_RELEASE := "data_release"   # free a DataRef handle
const MSG_DATA_ACK := "data_ack"           # release confirmation
const MSG_STATUS := "status"
const MSG_EVENT := "event"
const MSG_SHUTDOWN := "shutdown"
const MSG_SHUTDOWN_ACK := "shutdown_ack"

# Task command kinds inside MSG_TASK / MSG_BATCH items
const CMD_RUN := "run"
const CMD_CALL := "call"
const CMD_DEFINE := "define"

# Field holding the items list for batch messages. Both directions use this
# field; each item carries its own "id" plus command-specific payload.
const FIELD_ITEMS := "items"

## Builds a complete frame for a message dictionary. Serializes `data` (and
## any nested batch item data) through the type mapper, collecting binary
## chunks. Returns {"text": String} or {"binary": PackedByteArray}.
static func build_frame(msg: Dictionary, external_chunks: Array = []) -> Dictionary:
	var chunks: Array = []
	chunks.append_array(external_chunks)
	var enc: Dictionary = msg.duplicate(true)
	if enc.has("data"):
		# Callers may pass raw values (encoded here) or already-encoded,
		# tagged values (e.g. from PythonBridgeSerializer.encode + external
		# chunk collection). Re-encoding a tagged value would wrap it in a
		# {"$pb":"dict"} and orphan the chunk reference - so skip it.
		if not _is_tagged(enc["data"]):
			enc["data"] = PythonBridgeSerializer.encode(enc["data"], chunks)
	if enc.has(FIELD_ITEMS) and enc[FIELD_ITEMS] is Array:
		var items: Array = []
		for item in enc[FIELD_ITEMS]:
			var it: Dictionary = (item as Dictionary).duplicate(true)
			if it.has("data") and not _is_tagged(it["data"]):
				it["data"] = PythonBridgeSerializer.encode(it["data"], chunks)
			items.append(it)
		enc[FIELD_ITEMS] = items

	if chunks.is_empty():
		return {"text": JSON.stringify(enc)}

	var header: PackedByteArray = JSON.stringify(enc).to_utf8_buffer()
	var out := PackedByteArray()
	out.append_array(_u32_bytes(header.size()))
	out.append_array(header)
	for chunk: PackedByteArray in chunks:
		out.append_array(_u32_bytes(chunk.size()))
		out.append_array(chunk)
	return {"binary": out}

## True when `v` is a dictionary already carrying a type tag ($pb), i.e. it
## went through PythonBridgeSerializer.encode (or came from the Python side)
## and must not be encoded again.
static func _is_tagged(v: Variant) -> bool:
	return v is Dictionary and (v as Dictionary).has(PythonBridgeSerializer.TAG)

## Parses a frame (String or PackedByteArray). Returns
## {"msg": Dictionary, "data": Variant}; batch items are decoded in place
## into msg[FIELD_ITEMS]. Malformed input yields an empty msg.
static func parse_frame(pkt: Variant) -> Dictionary:
	if pkt is String:
		var parsed: Variant = JSON.parse_string(pkt)
		var msg: Dictionary = parsed if parsed is Dictionary else {}
		_decode_data_in_place(msg, [])
		var data: Variant = msg.get("data", null)
		return {"msg": msg, "data": data}

	if pkt is PackedByteArray:
		var bytes: PackedByteArray = pkt
		if bytes.size() < 4:
			return {"msg": {}, "data": null}
		var header_len := bytes.decode_u32(0)
		if bytes.size() < 4 + header_len:
			return {"msg": {}, "data": null}
		var header_bytes: PackedByteArray = bytes.slice(4, 4 + header_len)
		var parsed2: Variant = JSON.parse_string(header_bytes.get_string_from_utf8())
		var msg: Dictionary = parsed2 if parsed2 is Dictionary else {}

		var chunks: Array = []
		var offset := 4 + header_len
		while offset + 4 <= bytes.size():
			var chunk_len := bytes.decode_u32(offset)
			chunks.append(bytes.slice(offset + 4, offset + 4 + chunk_len))
			offset += 4 + chunk_len

		_decode_data_in_place(msg, chunks)
		var data: Variant = msg.get("data", null)
		return {"msg": msg, "data": data}

	return {"msg": {}, "data": null}

## Decodes the serialized `data` field (and batch item data fields) in place.
static func _decode_data_in_place(msg: Dictionary, chunks: Array) -> void:
	if msg.has("data") and msg["data"] != null:
		msg["data"] = PythonBridgeSerializer.decode(msg["data"], chunks)
	if msg.has(FIELD_ITEMS) and msg[FIELD_ITEMS] is Array:
		var items: Array = msg[FIELD_ITEMS]
		for i in items.size():
			var item: Dictionary = items[i] as Dictionary
			if item != null and item.has("data") and item["data"] != null:
				items[i] = item.duplicate(true)
				items[i]["data"] = PythonBridgeSerializer.decode(item["data"], chunks)

## Convenience: builds a task_result / task_error response envelope.
static func response_envelope(msg_type: String, id: String, status: String, data: Variant = null, error: Dictionary = {}, ms: int = 0) -> Dictionary:
	var msg := {
		"v": PROTOCOL_VERSION,
		"type": msg_type,
		"id": id,
		"status": status,
		"ms": ms,
	}
	if status == "ok":
		msg["data"] = data
	else:
		msg["error"] = error
	return msg

static func _u32_bytes(value: int) -> PackedByteArray:
	# Explicit little-endian: Godot's decode_u32 reads little-endian and the
	# Python side writes little-endian as well (struct.pack "<I").
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes[0] = value & 0xFF
	bytes[1] = (value >> 8) & 0xFF
	bytes[2] = (value >> 16) & 0xFF
	bytes[3] = (value >> 24) & 0xFF
	return bytes