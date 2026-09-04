extends Node
## Minimal-Beispiel, wie die Python Bridge aus GDScript benutzt wird.
## Voraussetzung: Plugin aktiviert, Autoload "PythonBridge" vorhanden.
## Die Skripte liegen unter res://python_bridge/scripts/ (Default-Workspace);
## dieses Beispiel liest sie aus dem Projekt-Workspace.

const SCRIPT_ID := "mein_skript"

var _bereit := false

func _ready() -> void:
	# Skript in den Standard-Workspace kopieren (einmalig).
	_sync_example_script()
	await _python_starten()
	await _python_aufrufen()

func _exit_tree() -> void:
	PythonBridge.shutdown()

func _sync_example_script() -> void:
	# Das Beispielskript liegt in example/scripts/; die Bridge arbeitet mit
	# res://python_bridge/scripts/. Hier einmalig kopieren.
	var src_path := "res://example/scripts/mein_skript.py"
	if PythonBridge.get_script_source(SCRIPT_ID) == "" and FileAccess.file_exists(src_path):
		var f := FileAccess.open(src_path, FileAccess.READ)
		var code := f.get_as_text()
		f.close()
		PythonBridge.create_script(SCRIPT_ID, code)

func _python_starten() -> void:
	var start := await PythonBridge.start_instance("default")
	if start.is_error():
		push_error("Python-Start fehlgeschlagen: " + start.error_message())
		return
	_bereit = true
	print("[demo] Python bereit")

func _python_aufrufen() -> void:
	if not _bereit:
		return
	var result := await PythonBridge.call_script(SCRIPT_ID, "calculate", [3.0], {"b": 4.0})
	if result.is_ok():
		print("[demo] calculate(3, 4) = ", result.value)
	else:
		push_error("[demo] " + result.error_message())

	var greet := await PythonBridge.call_script(SCRIPT_ID, "greet", ["Godot"], {"prefix": "Hallo"})
	if greet.is_ok():
		print("[demo] ", greet.value)

	var fib := await PythonBridge.call_script(SCRIPT_ID, "fibonacci", [8])
	if fib.is_ok():
		print("[demo] fibonacci(8) = ", fib.value)

	# Task-API direkt (kein await auf Convenience-Funktion):
	var task := PythonBridgeTask.make_call(
		"demo-task-1", "script:" + SCRIPT_ID,
		PythonBridge.get_script_source(SCRIPT_ID), "greet", ["Welt"], {"prefix": "Servus"}, 30000)
	var submitted := PythonBridge.submit_task(task)
	if submitted.is_ok():
		var res := await task.done
		print("[demo] task-API greet = ", res.value)
	else:
		push_error("[demo] submit fehlgeschlagen: " + submitted.error_message())