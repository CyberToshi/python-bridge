class_name PythonProtocol
extends RefCounted
## Versioniertes Nachrichten-Protokoll.
##
## Frame-Typen (ein WebSocket-Frame = eine Nachricht):
##   Text:   reines JSON.
##   Binary: U32BE(Header-Laenge) + HeaderJSON(utf8) +
##           Liste aus [U32BE(Chunk-Laenge) + Chunk-Bytes].

const PROTOCOL_VERSION := 1

static func build_frame(msg: Dictionary) -> Dictionary:
	var chunks: Array = []
	var enc: Dictionary = msg.duplicate(true)
	if enc.has("data"):
		enc["data"] = PythonBridgeSerializer.encode(enc["data"], chunks)

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

static func parse_frame(pkt: Variant) -> Dictionary:
	if pkt is String:
		var parsed: Variant = JSON.parse_string(pkt)
		var msg: Dictionary = parsed if parsed is Dictionary else {}
		var data: Variant = null
		if msg.has("data"):
			# Auch Text-Frames tragen das getaggte data-Feld und muessen es
			# durch den Serializer zurueckkonvertieren (ohne Binär-Chunks).
			data = PythonBridgeSerializer.decode(msg["data"], [])
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

		var data: Variant = null
		if msg.has("data"):
			data = PythonBridgeSerializer.decode(msg["data"], chunks)
		return {"msg": msg, "data": data}

	return {"msg": {}, "data": null}

static func _u32_bytes(value: int) -> PackedByteArray:
	# Explizit Little-Endian kodieren: Godot 4.7 dekodiert u32-Laengen als
	# Little-Endian (decode_u32 ohne Endian-Parameter) - die Python-Seite
	# schreibt deshalb ebenfalls Little-Endian-Laengen.
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes[0] = value & 0xFF
	bytes[1] = (value >> 8) & 0xFF
	bytes[2] = (value >> 16) & 0xFF
	bytes[3] = (value >> 24) & 0xFF
	return bytes