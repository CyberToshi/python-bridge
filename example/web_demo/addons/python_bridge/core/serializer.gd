class_name PythonBridgeSerializer
extends RefCounted
## Zentraler, transparenter und erweiterbarer Serializer/Deserializer.
##
## Skalare (null/bool/int/float/string) bleiben lesbare JSON-Werte.
## Strukturierte Werte werden als getaggte Objekte `{"$pb": "<tag>", ...}` kodiert.
## Große Binär-Blobs (PackedByteArrays, ndarray-Daten, Bilder) werden in den
## `chunks`-Puffer der Nachricht gelegt statt als base64 in den JSON-Header.
##
## Unbekannte Tags werden an die PythonBridgeTypeMapper-Registry delegiert,
## sodass benutzerdefinierte Typen ohne Kernänderung ergänzt werden können.

const TAG := "$pb"
const INLINE_LIMIT := 512

## Godot -> typisierte Darstellung. Hängt große Blobs an `chunks` an.
static func encode(v: Variant, chunks: Array) -> Variant:
	match typeof(v):
		TYPE_NIL:
			return {TAG: "null"}
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		TYPE_VECTOR2:
			return {TAG: "vec2", "v": [v.x, v.y]}
		TYPE_VECTOR3:
			return {TAG: "vec3", "v": [v.x, v.y, v.z]}
		TYPE_VECTOR4:
			return {TAG: "vec4", "v": [v.x, v.y, v.z, v.w]}
		TYPE_COLOR:
			return {TAG: "color", "v": [v.r, v.g, v.b, v.a]}
		TYPE_TRANSFORM3D:
			return {TAG: "transform3d", "v": [
				v.basis.x.x, v.basis.x.y, v.basis.x.z,
				v.basis.y.x, v.basis.y.y, v.basis.y.z,
				v.basis.z.x, v.basis.z.y, v.basis.z.z,
				v.origin.x, v.origin.y, v.origin.z]}
		TYPE_ARRAY:
			var out: Array = []
			for x in v:
				out.append(encode(x, chunks))
			return {TAG: "arr", "v": out}
		TYPE_DICTIONARY:
			var out: Dictionary = {}
			for k in v:
				out[str(k)] = encode(v[k], chunks)
			return {TAG: "dict", "v": out}
		TYPE_PACKED_BYTE_ARRAY:
			return _encode_blob(v, chunks, "bytes")
		TYPE_PACKED_INT32_ARRAY:
			return _encode_numeric_chunk_or(v, chunks, "i32", "s32", 4)
		TYPE_PACKED_INT64_ARRAY:
			return _encode_numeric_chunk_or(v, chunks, "i64", "s64", 8)
		TYPE_PACKED_FLOAT32_ARRAY:
			return _encode_numeric_chunk_or(v, chunks, "f32", "float", 4)
		TYPE_PACKED_FLOAT64_ARRAY:
			return _encode_numeric_chunk_or(v, chunks, "f64", "double", 8)
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			var arr: Array = []
			for x in v:
				arr.append(encode(x, chunks))
			return {TAG: "arr", "v": arr}
	if v is Image:
		return _encode_image(v, chunks)
	# Custom registered types (Object subclasses): route by registered class.
	if v is Object:
		var custom_tag := PythonBridgeTypeMapper.tag_for_value(v)
		if custom_tag != "":
			var enc: Callable = PythonBridgeTypeMapper.custom_encode(custom_tag)
			if enc.is_valid():
				return enc.call(v, chunks)
	return {TAG: "unsupported", "type": type_string(typeof(v))}

## Numeric packed arrays: kleine Arrays bleiben JSON-Zahlenlisten (legacy),
## groessere wandern als Little-Endian-Rohbytes in den Binary-Chunk-Stream.
## Damit laufen grosse Float-/Int-Arrays nicht als JSON-Zahlenliste (D1).
static func _encode_numeric_chunk_or(v: Variant, chunks: Array, tag: String, codec: String, item_size: int) -> Variant:
	if v.size() * item_size <= INLINE_LIMIT:
		return {TAG: tag, "v": v}
	var raw := PackedByteArray()
	raw.resize(v.size() * item_size)
	for i in v.size():
		match codec:
			"s32": raw.encode_s32(i * item_size, v[i])
			"s64": raw.encode_s64(i * item_size, v[i])
			"float": raw.encode_float(i * item_size, v[i])
			"double": raw.encode_double(i * item_size, v[i])
	return _numeric_chunk(raw, chunks, tag)

## Descriptor fuer einen numerischen Rohbyte-Block. `nbytes` ist die
## deklarierte Groesse zur Validierung auf der Gegenseite; die Daten liegen
## im Chunk-Stream, nicht im JSON-Header.
static func _numeric_chunk(raw: PackedByteArray, chunks: Array, tag: String) -> Dictionary:
	var desc := {TAG: tag, "nbytes": raw.size(), "chunk": chunks.size()}
	chunks.append(raw)
	return desc

static func _encode_blob(v: PackedByteArray, chunks: Array, tag: String) -> Dictionary:
	var desc := {TAG: tag}
	if v.size() <= INLINE_LIMIT:
		desc["b"] = Marshalls.raw_to_base64(v)
	else:
		desc["chunk"] = chunks.size()
		chunks.append(v)
	return desc

static func _encode_image(img: Image, chunks: Array) -> Dictionary:
	var data: PackedByteArray = img.get_data()
	var desc := {TAG: "image", "w": img.get_width(), "h": img.get_height(),
		"format": img.get_format(), "mipmaps": img.has_mipmaps()}
	if data.size() <= INLINE_LIMIT:
		desc["b"] = Marshalls.raw_to_base64(data)
	else:
		desc["chunk"] = chunks.size()
		chunks.append(data)
	return desc

## typisierte Darstellung -> Godot. `chunks` = Binär-Puffer der Nachricht.
static func decode(v: Variant, chunks: Array) -> Variant:
	if v is Dictionary and v.has(TAG):
		var t: String = v[TAG]
		match t:
			"null":
				return null
			"vec2":
				return Vector2(v["v"][0], v["v"][1])
			"vec3":
				return Vector3(v["v"][0], v["v"][1], v["v"][2])
			"vec4":
				return Vector4(v["v"][0], v["v"][1], v["v"][2], v["v"][3])
			"color":
				return Color(v["v"][0], v["v"][1], v["v"][2], v["v"][3])
			"transform3d":
				var a: Array = v["v"]
				return Transform3D(
					Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8])),
					Vector3(a[9], a[10], a[11]))
			"bytes":
				return _decode_blob(v, chunks)
			"arr":
				var out: Array = []
				for x in v["v"]:
					out.append(decode(x, chunks))
				return out
			"dict":
				var out: Dictionary = {}
				for k in v["v"]:
					out[k] = decode(v["v"][k], chunks)
				return out
			"tuple", "set":
				var out2: Array = []
				for x in v["v"]:
					out2.append(decode(x, chunks))
				return out2
			"i8":
				return _decode_s8(v, chunks)
			"u8":
				return _decode_blob(v, chunks)
			"i16":
				return _decode_s16(v, chunks)
			"u16":
				return _decode_u16(v, chunks)
			"i32":
				if v.has("chunk"):
					return _decode_numeric_chunk(v, chunks, "int32")
				return PackedInt32Array(Array(v["v"]))
			"u32", "u64":
				return PackedInt64Array(Array(v["v"]))
			"i64":
				if v.has("chunk"):
					return _decode_numeric_chunk(v, chunks, "int64")
				return PackedInt64Array(Array(v["v"]))
			"i16":
				if v.has("chunk"):
					return _decode_numeric_chunk(v, chunks, "int16")
				return _decode_s16(v, chunks)
			"u16":
				if v.has("chunk"):
					return _decode_numeric_chunk(v, chunks, "uint16")
				return _decode_u16(v, chunks)
			"f32":
				if v.has("chunk"):
					return _decode_numeric_chunk(v, chunks, "float32")
				return PackedFloat32Array(Array(v["v"]))
			"f64":
				if v.has("chunk"):
					return _decode_numeric_chunk(v, chunks, "float64")
				return PackedFloat64Array(Array(v["v"]))
			"ndarray":
				return _decode_ndarray(v, chunks)
			"image":
				return _decode_image(v, chunks)
			"pyobject":
				return str(v.get("text", "<pyobject>"))
			"unsupported":
				return null
			"data_ref":
				return PythonBridgeDataRef.from_descriptor(v)
			_: # Custom registered tags
				var dec: Callable = PythonBridgeTypeMapper.custom_decode(t)
				if dec.is_valid():
					return dec.call(v, chunks)
				return null
	if v is Array:
		var out3: Array = []
		for x in v:
			out3.append(decode(x, chunks))
		return out3
	if v is Dictionary:
		var out4: Dictionary = {}
		for k in v:
			out4[k] = decode(v[k], chunks)
		return out4
	return v

static func _decode_blob(v: Dictionary, chunks: Array) -> PackedByteArray:
	if v.has("chunk"):
		return chunks[int(v["chunk"])]
	return Marshalls.base64_to_raw(v.get("b", ""))

## Chunk-Form numerischer Tags: Rohbytes + deklarierte nbytes. Validiert die
## Groesse gegen den Descriptor (Korruptionserkennung) und materialisiert in
## den passenden Packed-Typ. Kleine Arrays kommen weiterhin als "v"-Liste.
static func _decode_numeric_chunk(v: Dictionary, chunks: Array, dtype: String) -> Variant:
	var data := _decode_blob(v, chunks)
	var bpe := _bytes_per_element(dtype)
	if data.size() % maxi(bpe, 1) != 0:
		push_error("[PythonBridge] Numeric chunk size %d not aligned to %s (%d bytes/elem)" % [data.size(), dtype, bpe])
		return _empty_packed(dtype)
	if v.has("nbytes") and int(v["nbytes"]) != data.size():
		push_error("[PythonBridge] Numeric chunk descriptor mismatch: declared %d bytes, got %d" % [int(v["nbytes"]), data.size()])
		return _empty_packed(dtype)
	return _packed_from(dtype, data, data.size() / maxi(bpe, 1))

static func _empty_packed(dtype: String) -> Variant:
	match dtype:
		"float32": return PackedFloat32Array()
		"float64": return PackedFloat64Array()
		"int32": return PackedInt32Array()
		"int64": return PackedInt64Array()
		"int16", "uint16": return PackedInt32Array()
	return PackedByteArray()

## NumPy-ndarray: Shape 1 -> PackedArray; >1 -> Array von Zeilen (shape[0]).
static func _decode_ndarray(v: Dictionary, chunks: Array) -> Variant:
	var data := _decode_blob(v, chunks)
	var dtype: String = str(v.get("dtype", "float64"))
	var shape: Array = v.get("shape", [])
	var bpe := _bytes_per_element(dtype)
	# Validierung (Dtype-/Shape-/nbytes-Konsistenz) vor der Materialisierung:
	# ein verwaister/verfaelschter Chunk darf keine falschen Typed Arrays
	# erzeugen.
	var declared := int(v.get("nbytes", 0))
	if declared > 0 and declared != data.size():
		push_error("[PythonBridge] ndarray descriptor mismatch: declared %d bytes, chunk has %d" % [declared, data.size()])
		return _empty_packed(dtype)
	var count := data.size() / maxi(bpe, 1)
	if shape.size() == 1:
		return _packed_from(dtype, data, int(shape[0]))
	if shape.size() > 1:
		var row_count := int(shape[0])
		var row_elems := int(shape[1]) if shape.size() > 1 else 1
		if shape.size() > 2:
			row_elems = 1
			for i in range(1, shape.size()):
				row_elems *= int(shape[i])
		var rows: Array = []
		for r in row_count:
			var off := r * row_elems * bpe
			rows.append(_packed_from(dtype, data.slice(off, off + row_elems * bpe), row_elems))
		return rows
	return _packed_from(dtype, data, count)

static func _packed_from(dtype: String, data: PackedByteArray, count: int) -> Variant:
	match dtype:
		"float32":
			return data.to_float32_array()
		"float64":
			return data.to_float64_array()
		"int32":
			return data.to_int32_array()
		"int64":
			return data.to_int64_array()
		"uint8":
			return data
		"int8":
			return data
		"int16":
			return _decode_s16_raw(data, count)
		"uint16":
			return _decode_u16_raw(data, count)
	return data.to_float64_array()

static func _bytes_per_element(dtype: String) -> int:
	match dtype:
		"float32", "int32", "uint32":
			return 4
		"float64", "int64", "uint64":
			return 8
		"int16", "uint16":
			return 2
	return 1

static func _decode_s16_raw(b: PackedByteArray, count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(0, mini(count, b.size() / 2) * 2, 2):
		out.append(b.decode_s16(i))
	return out

static func _decode_u16_raw(b: PackedByteArray, count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(0, mini(count, b.size() / 2) * 2, 2):
		out.append(b.decode_u16(i))
	return out

static func _decode_s8(v: Dictionary, chunks: Array) -> PackedByteArray:
	return _decode_blob(v, chunks)

static func _decode_s16(v: Dictionary, chunks: Array) -> PackedInt32Array:
	var data := _decode_blob(v, chunks)
	return _decode_s16_raw(data, data.size() / 2)

static func _decode_u16(v: Dictionary, chunks: Array) -> PackedInt32Array:
	var data := _decode_blob(v, chunks)
	return _decode_u16_raw(data, data.size() / 2)

static func _decode_image(v: Dictionary, chunks: Array) -> Image:
	var data := _decode_blob(v, chunks)
	return Image.create_from_data(int(v["w"]), int(v["h"]),
		bool(v.get("mipmaps", false)),
		int(v["format"]) as Image.Format, data)

