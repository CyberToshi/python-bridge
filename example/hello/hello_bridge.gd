extends Node

## Hello-World example for the Python Bridge.
##
## Open example/hello/hello_world.tscn in the editor and press F6, or run the
## main scene. This script:
##   1. syncs example/hello/hello.py into the bridge workspace (once),
##   2. starts the "default" Python instance,
##   3. calls say_hello() and prints the answer,
##   4. sends a small structured payload every 60 frames via execute().
##
## Closing the scene shuts the Python process down cleanly (_exit_tree).

const PYTHON_SCRIPT := "hello"
const PYTHON_INSTANCE := "default"
const EXAMPLE_PY := "res://example/hello/hello.py"

var _python_ready := false
var _frame_counter := 0

func _ready() -> void:
	_sync_example_script()
	var started: PythonBridgeResult = await PythonBridge.start_instance(
		PYTHON_INSTANCE
	)
	if started.is_error():
		push_error("Python Bridge start failed: " + started.error_message())
		return
	_python_ready = true
	await _send_hello()

func _sync_example_script() -> void:
	if PythonBridge.get_script_source(PYTHON_SCRIPT) == "" and FileAccess.file_exists(EXAMPLE_PY):
		var f := FileAccess.open(EXAMPLE_PY, FileAccess.READ)
		var code := f.get_as_text()
		f.close()
		PythonBridge.create_script(PYTHON_SCRIPT, code)

func _send_hello() -> void:
	var result: PythonBridgeResult = await PythonBridge.call_script(
		PYTHON_SCRIPT,
		"say_hello",
		["Hello Python"],
		{},
		PYTHON_INSTANCE,
		30.0
	)
	if result.is_ok():
		print("[hello] Python antwortet: ", result.value)
	else:
		push_error("Python task failed [" + result.error_code() + "]: "
			+ result.error_message())

func _process(_delta: float) -> void:
	if not _python_ready:
		return
	_frame_counter += 1
	if _frame_counter % 60 == 0:
		_send_frame_update()

func _send_frame_update() -> void:
	var payload := {
		"frame": _frame_counter,
		"time_seconds": Time.get_ticks_msec() / 1000.0
	}
	var result: PythonBridgeResult = await PythonBridge.execute(
		"result = {\"python_says\": \"Hello Godot\", \"received\": input}",
		payload,
		PYTHON_INSTANCE,
		5.0
	)
	if result.is_ok():
		print("[hello] Frame-Antwort: ", result.value)
	else:
		push_error("Frame task failed: " + result.error_message())

func _exit_tree() -> void:
	# Beendet den Python-Prozess kontrolliert, wenn die Szene endet.
	PythonBridge.shutdown()
