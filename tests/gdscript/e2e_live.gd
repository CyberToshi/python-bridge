extends SceneTree
## End-to-end test: autoload starts a real Python subprocess and executes a
## task over the WebSocket.
##
## NOTE: requires a NATIVE Godot binary and a reachable Python 3.8+ (the
## first run provisions the project venv, 1-3 min). It does NOT work inside
## the flatpak sandbox (subprocesses lose venv/site-packages access).
## Run:
##   godot --headless --path . --script res://tests/gdscript/e2e_live.gd

const SCRIPT_ID := "e2e_math"

func _initialize() -> void:
	print("[E2E] start")
	# Defer to the first frame: the autoload's _process must be running and
	# the SceneTree must exist before wait_ready()/process_frame can work.
	await process_frame
	var bridge := root.get_node_or_null("PythonBridge")
	if bridge == null:
		print("[E2E] FAIL: autoload PythonBridge missing")
		quit(1)
		return

	var script_dir := "res://python_bridge/scripts"
	DirAccess.make_dir_recursive_absolute(script_dir)
	var src := "def add(a, b):\n    return a + b\n"
	var file := FileAccess.open(script_dir + "/e2e_math.py", FileAccess.WRITE)
	file.store_string(src)
	file.close()

	var start: Variant = await bridge.start_instance("default")
	if start.is_error():
		print("[E2E] FAIL: start_instance: ", start.error_message())
		quit(1)
		return
	print("[E2E] instance ready")

	var result: Variant = await bridge.call_script(SCRIPT_ID, "add", [2, 3])
	if result.is_ok():
		print("[E2E] OK: add(2, 3) = ", result.value)
		if int(result.value) == 5:
			print("[E2E] PASS")
			bridge.shutdown_now()
			quit(0)
			return
	print("[E2E] FAIL: result=", result.status, " value=", result.value,
		" err=", result.error_message())
	bridge.shutdown_now()
	quit(1)