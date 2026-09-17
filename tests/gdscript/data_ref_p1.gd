extends SceneTree
## P1 end-to-end verification of the DataRef / binary-chunk data plane.
##
## Mirrors the proven e2e_live.gd structure: SceneTree script, autoload read
## from root, quit(code) at the end.
##
## Run: godot --headless --path . --script res://tests/gdscript/data_ref_p1.gd
##
## The result payload is a numpy float32 array large enough to exceed the
## default data_ref_threshold_bytes (16 MiB), so the server returns a
## lightweight `data_ref` descriptor instead of the raw chunk.

const INSTANCE_NAME := "default"
const LARGE_ELEMS := 4200000   # 4200000 * 4 bytes = 16.8 MiB > 16 MiB threshold

var _ok := true
var _checks := 0

func _initialize() -> void:
	print("[P1] start")
	await process_frame
	var bridge := root.get_node_or_null("PythonBridge")
	if bridge == null:
		print("[P1] FAIL: autoload PythonBridge missing")
		quit(1)
		return
	await _run_large_handle_lifecycle(bridge)
	await _run_small_direct_path(bridge)
	_finish()

func _finish() -> void:
	print("[P1] RESULT: %s (%d checks)" % ["PASS" if _ok else "FAIL", _checks])
	quit(0 if _ok else 1)

func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[P1] OK: " + what)
	else:
		print("[P1] FAIL: " + what)
		_ok = false

func _run_large_handle_lifecycle(bridge: Node) -> void:
	var started: Variant = await bridge.start_instance(INSTANCE_NAME)
	if started.is_error():
		_check(false, "start_instance: " + started.error_message())
		return
	print("[P1] instance ready")

	var src := "import numpy as np\nresult = np.arange(%d, dtype=np.float32)\nresult = result * 0.5\n" % LARGE_ELEMS
	var run_res: Variant = await bridge.execute(src, null, INSTANCE_NAME, 30.0)
	if run_res.is_error():
		_check(false, "large execute(): " + run_res.error_message())
		return

	# The serializer auto-decodes a data_ref descriptor into a typed handle;
	# submit_task tracks it and assigns the instance that produced it.
	_check(run_res.value is PythonBridgeDataRef, "large result is a PythonBridgeDataRef handle")
	if not (run_res.value is PythonBridgeDataRef):
		return
	var ref: PythonBridgeDataRef = run_res.value
	_check(str(ref.data_id) != "", "handle has non-empty id")
	_check(ref.dtype == "float32", "handle dtype float32")
	_check(ref.nbytes == LARGE_ELEMS * 4, "handle nbytes correct")
	_check(ref.shape.size() == 1 and int(ref.shape[0]) == LARGE_ELEMS, "handle shape correct")
	_check(ref.instance_name == INSTANCE_NAME, "handle instance auto-assigned")

	var dres: Variant = await bridge.describe_data(ref)
	_check(dres.is_ok(), "describe_data ok")
	if dres.is_ok():
		var d: Dictionary = dres.value
		_check(str(d.get("id", "")) == str(ref.data_id), "describe_data id matches")
		_check(str(d.get("dtype", "")) == "float32", "describe_data dtype matches")
		_check(int(d.get("nbytes", 0)) == LARGE_ELEMS * 4, "describe_data nbytes matches")
		_check(not d.get("stale", true), "describe_data not stale before release")

	# File-backed transport: the server stores the bytes as
	# data-<tag>-<data_id>.bin under the instance tmp dir and Godot reads
	# that file chunk-wise (no WebSocket transfer). Prove it exists while
	# the handle is alive.
	var data_dir := ProjectSettings.globalize_path(str(bridge.workspace_dir())) + "/tmp/data"
	var backing_file := data_dir + "/data-" + INSTANCE_NAME + "-" + ref.data_id + ".bin"

	# Materialize twice: identical content each time.
	var prev_last: float = -1.0
	for i in [1, 2]:
		var mres: Variant = await bridge.materialize_data(ref, 5.0)
		if mres.is_error():
			_check(false, "materialize_data #" + str(i) + ": " + mres.error_message())
			return
		_check(mres.value is PackedFloat32Array, "materialize_data #" + str(i) + " is PackedFloat32Array")
		var arr: PackedFloat32Array = mres.value
		_check(arr.size() == LARGE_ELEMS, "materialize_data #" + str(i) + " size correct")
		_check(arr[0] == 0.0, "materialize_data #" + str(i) + " first value 0")
		_check(arr[arr.size() - 1] > 0.0, "materialize_data #" + str(i) + " last value > 0")
		# Exact values: result[k] = k * 0.5, exactly representable in float32.
		_check(arr[100000] == 50000.0, "materialize_data #" + str(i) + " exact value arr[100000]")
		_check(arr[1234567] == 617283.5, "materialize_data #" + str(i) + " exact value arr[1234567]")
		_check(FileAccess.file_exists(backing_file),
			"materialize_data #" + str(i) + " backing file exists (file transport)")
		if i == 1:
			prev_last = arr[arr.size() - 1]
		else:
			_check(arr[arr.size() - 1] == prev_last, "materialize_data #2 matches #1")
			_check(arr[100000] == 50000.0, "materialize_data #2 exact value matches #1")

	var rel: Variant = await bridge.release_data(ref, 5.0)
	_check(rel.is_ok(), "release_data ok")
	if rel.is_ok():
		_check(bool((rel.value as Dictionary).get("released", false)), "release_data released=true")
	_check(ref.is_stale(), "handle stale after release")
	_check(not FileAccess.file_exists(backing_file),
		"release removes the backing file")

	var stale: Variant = await bridge.materialize_data(ref, 5.0)
	_check(stale.is_error(), "materialize after release is error")
	if stale.is_error():
		_check(str(stale.error_message()).to_lower().contains("stale"), "error mentions stale")

func _run_small_direct_path(bridge: Node) -> void:
	print("[P1] small execute() -> expect direct PackedFloat32Array")
	var src := "import numpy as np\nresult = np.arange(8, dtype=np.float32)\n"
	var res: Variant = await bridge.execute(src, null, INSTANCE_NAME, 30.0)
	if res.is_error():
		_check(false, "small execute(): " + res.error_message())
		return
	_check(res.value is PackedFloat32Array, "small result is PackedFloat32Array")
	if res.value is PackedFloat32Array:
		var arr: PackedFloat32Array = res.value
		_check(arr.size() == 8, "small result size 8")
		_check(arr[0] == 0.0 and arr[7] == 7.0, "small result values 0..7")

func _exit_tree() -> void:
	var bridge := root.get_node_or_null("PythonBridge")
	if bridge:
		bridge.shutdown()
