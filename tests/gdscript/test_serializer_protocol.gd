class_name PBTestSerializerProtocol
extends PBTests
## Round-trip tests for the type mapper / serializer / protocol frames.

func test_scalars() -> void:
	var chunks: Array = []
	var enc: Variant = PythonBridgeSerializer.encode(42, chunks)
	assert_eq(PythonBridgeSerializer.decode(enc, chunks), 42)
	assert_eq(PythonBridgeSerializer.decode(PythonBridgeSerializer.encode("hi", chunks), chunks), "hi")
	assert_null(PythonBridgeSerializer.decode(PythonBridgeSerializer.encode(null, chunks), chunks))

func test_vectors_and_color() -> void:
	var chunks: Array = []
	var v3 := Vector3(1, 2, 3)
	var decoded: Variant = PythonBridgeSerializer.decode(
		PythonBridgeSerializer.encode(v3, chunks), chunks)
	assert_eq(decoded, v3)
	var col := Color(0.1, 0.2, 0.3, 0.4)
	assert_eq(PythonBridgeSerializer.decode(PythonBridgeSerializer.encode(col, chunks), chunks), col)

func test_nested_container() -> void:
	var chunks: Array = []
	var value := {"list": [1, 2.5, "x"], "nested": {"a": Vector2(3, 4)}}
	var decoded: Variant = PythonBridgeSerializer.decode(
		PythonBridgeSerializer.encode(value, chunks), chunks)
	assert_true(decoded is Dictionary)
	assert_eq((decoded as Dictionary)["list"][0], 1)
	assert_eq((decoded as Dictionary)["nested"]["a"], Vector2(3, 4))

func test_binary_chunk_roundtrip() -> void:
	var chunks: Array = []
	var big := PackedByteArray()
	big.resize(4096)
	big[0] = 1
	big[4095] = 255
	var enc: Variant = PythonBridgeSerializer.encode(big, chunks)
	assert_eq(chunks.size(), 1, "large blob becomes a chunk")
	var back: Variant = PythonBridgeSerializer.decode(enc, chunks)
	assert_eq((back as PackedByteArray).size(), 4096)
	assert_eq((back as PackedByteArray)[4095], 255)

func test_text_frame_roundtrip() -> void:
	var msg := {
		"v": PythonProtocol.PROTOCOL_VERSION,
		"type": PythonProtocol.MSG_TASK,
		"id": "t1",
		"command": PythonProtocol.CMD_CALL,
		"data": {"args": [1, 2.5, "x"]},
	}
	var frame: Dictionary = PythonProtocol.build_frame(msg)
	assert_true(frame.has("text"))
	var parsed: Dictionary = PythonProtocol.parse_frame(frame["text"])
	var parsed_msg: Dictionary = parsed["msg"]
	assert_eq(parsed_msg["id"], "t1")
	assert_eq(parsed["data"]["args"][0], 1)
	assert_eq(parsed["data"]["args"][2], "x")

func test_large_float32_array_uses_binary_chunk() -> void:
	var chunks: Array = []
	var arr := PackedFloat32Array()
	arr.resize(1024)   # 4096 bytes > INLINE_LIMIT (512)
	for i in arr.size():
		arr[i] = float(i) * 0.5
	var enc: Variant = PythonBridgeSerializer.encode(arr, chunks)
	assert_eq(chunks.size(), 1, "large numeric array becomes one binary chunk")
	assert_true(enc is Dictionary)
	assert_eq((enc as Dictionary)[PythonBridgeSerializer.TAG], "f32")
	assert_eq((enc as Dictionary)["nbytes"], 4096)
	assert_true((enc as Dictionary).has("chunk"), "descriptor references chunk stream")
	assert_false((enc as Dictionary).has("v"), "no JSON number list for large arrays")
	var back: Variant = PythonBridgeSerializer.decode(enc, chunks)
	assert_true(back is PackedFloat32Array)
	assert_eq((back as PackedFloat32Array).size(), 1024)
	assert_eq((back as PackedFloat32Array)[7], 3.5)
	assert_eq((back as PackedFloat32Array)[1023], 511.5)

func test_small_numeric_array_stays_inline() -> void:
	var chunks: Array = []
	var small := PackedFloat32Array([1.0, 2.5, -3.0])
	var enc: Variant = PythonBridgeSerializer.encode(small, chunks)
	assert_eq(chunks.size(), 0, "small array stays in the JSON header")
	var back: Variant = PythonBridgeSerializer.decode(enc, chunks)
	assert_true(back is PackedFloat32Array)
	assert_eq((back as PackedFloat32Array)[1], 2.5)

func test_large_int32_chunk_roundtrip() -> void:
	var chunks: Array = []
	var arr := PackedInt32Array()
	arr.resize(600)
	for i in arr.size():
		arr[i] = i - 300
	var enc: Variant = PythonBridgeSerializer.encode(arr, chunks)
	assert_eq(chunks.size(), 1)
	assert_eq((enc as Dictionary)["nbytes"], 2400)
	var back: Variant = PythonBridgeSerializer.decode(enc, chunks)
	assert_true(back is PackedInt32Array)
	assert_eq((back as PackedInt32Array)[0], -300)
	assert_eq((back as PackedInt32Array)[599], 299)

func test_numeric_chunk_size_mismatch_is_detected() -> void:
	var chunks: Array = []
	# Descriptor claims 4096 bytes but the chunk only carries 8 -> detection.
	var wrong := PackedByteArray()
	wrong.resize(8)
	chunks.append(wrong)
	var enc := {PythonBridgeSerializer.TAG: "f32", "nbytes": 4096, "chunk": 0}
	var back: Variant = PythonBridgeSerializer.decode(enc, chunks)
	assert_true(back is PackedFloat32Array)
	assert_eq((back as PackedFloat32Array).size(), 0,
		"corrupt chunk materializes empty, not garbage")

func test_ndarray_nbytes_validation() -> void:
	var chunks: Array = []
	var wrong := PackedByteArray()
	wrong.resize(8)
	chunks.append(wrong)
	var desc := {PythonBridgeSerializer.TAG: "ndarray", "dtype": "float32",
		"shape": [100], "nbytes": 400, "chunk": 0}
	var back: Variant = PythonBridgeSerializer.decode(desc, chunks)
	assert_true(back is PackedFloat32Array)
	assert_eq((back as PackedFloat32Array).size(), 0)

func test_binary_frame_roundtrip() -> void:
	var chunks: Array = []
	var big := PackedByteArray()
	big.resize(1024)
	var msg := {
		"v": PythonProtocol.PROTOCOL_VERSION,
		"type": PythonProtocol.MSG_TASK_RESULT,
		"id": "r1",
		"status": "ok",
		"data": PythonBridgeSerializer.encode(big, chunks),
	}
	# The caller already collected the binary chunk via encode(); the frame
	# must carry it, so the frame becomes binary, not text.
	var frame: Dictionary = PythonProtocol.build_frame(msg, chunks)
	assert_true(frame.has("binary"))
	var parsed: Dictionary = PythonProtocol.parse_frame(frame["binary"])
	assert_eq((parsed["data"] as PackedByteArray).size(), 1024)

func test_batch_frame_items() -> void:
	var msg := {
		"v": PythonProtocol.PROTOCOL_VERSION,
		"type": PythonProtocol.MSG_BATCH,
		"id": "b1",
		PythonProtocol.FIELD_ITEMS: [
			{"id": "i1", "command": "run", "data": {"input": 5}},
			{"id": "i2", "command": "call", "data": {"args": [Vector3(1, 2, 3)]}},
		],
	}
	var frame: Dictionary = PythonProtocol.build_frame(msg)
	var parsed: Dictionary = PythonProtocol.parse_frame(frame["text"])
	var items: Array = parsed["msg"][PythonProtocol.FIELD_ITEMS]
	assert_eq(items.size(), 2)
	assert_eq(items[0]["data"]["input"], 5)
	assert_eq(items[1]["data"]["args"][0], Vector3(1, 2, 3))

func test_response_envelope() -> void:
	var ok: Dictionary = PythonProtocol.response_envelope(
		PythonProtocol.MSG_TASK_RESULT, "t1", "ok", 42, {}, 12)
	assert_eq(ok["status"], "ok")
	assert_eq(ok["ms"], 12)
	var err: Dictionary = PythonProtocol.response_envelope(
		PythonProtocol.MSG_TASK_ERROR, "t1", "error", null,
		{"code": "PYTHON_EXCEPTION"}, 5)
	assert_eq(err["error"]["code"], "PYTHON_EXCEPTION")