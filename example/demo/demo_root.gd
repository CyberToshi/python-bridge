extends Node
## Wurzel der Python-Bridge-Demo-Szene.
##
## Die Szene besteht aus mehreren Nodes, jedes mit einem eigenen Skript:
##   - DemoRoot      : orchestriert Bridge-Start, Workspace-Sync und Shutdown
##   - DemoBasic     : call_script / execute_script / define_script
##   - DemoTasks     : Task-API (submit, Signal 'done', cancel)
##   - DemoBatch     : Task-Batching (mehrere schnelle Aufrufe in einem Paket)
##   - DemoErrors    : Fehlerbehandlung (Python-Exception, Timeout)
##   - DemoMulti     : mehrere Python-Instanzen parallel
##
## Bedienung: Im Editor öffnen (example/demo_scene.tscn) und F6 drücken,
## dann die Buttons im Panel anklicken.

signal log_line(line: String)

const DEMO_SCRIPT_ID := "demo_skript"
const CRASH_SCRIPT_ID := "crash_skript"

var _bridge_started := false

func _ready() -> void:
	# Logs aller Demo-Nodes in das UI-Panel leiten.
	for node in get_children():
		if node.has_signal("logged"):
			node.logged.connect(_on_demo_logged)
	%Log.clear()
	_log("Python Bridge Demo gestartet.")
	_log("Klicke 'Bridge starten', danach die einzelnen Demos.")
	_connect_buttons()


func _connect_buttons() -> void:
	%BtnStart.pressed.connect(_on_start_pressed)
	%BtnBasic.pressed.connect(_on_basic_pressed)
	%BtnTasks.pressed.connect(_on_tasks_pressed)
	%BtnBatch.pressed.connect(_on_batch_pressed)
	%BtnErrors.pressed.connect(_on_errors_pressed)
	%BtnMulti.pressed.connect(_on_multi_pressed)
	%BtnShutdown.pressed.connect(_on_shutdown_pressed)


# ------------------------------------------------------------------ Logging

func _log(line: String) -> void:
	log_line.emit(line)
	print("[demo] ", line)


func _on_demo_logged(line: String) -> void:
	_log(line)


# ------------------------------------------------------------------ Bridge

func _sync_workspace_scripts() -> void:
	## Beispiel-Skripte einmalig in den Bridge-Workspace kopieren
	## (res://python_bridge/scripts/, Default-Workspace der Bridge).
	for entry: Array in [
		[DEMO_SCRIPT_ID, "res://example/scripts/demo_skript.py"],
		[CRASH_SCRIPT_ID, "res://example/scripts/crash_skript.py"],
	]:
		var script_id: String = entry[0]
		var src_path: String = entry[1]
		if PythonBridge.get_script_source(script_id) == "" and FileAccess.file_exists(src_path):
			var f := FileAccess.open(src_path, FileAccess.READ)
			var code := f.get_as_text()
			f.close()
			var res: PythonBridgeResult = PythonBridge.create_script(script_id, code)
			if res.is_ok():
				_log("Skript in Workspace synchronisiert: " + script_id)
			else:
				_log("[FEHLER] Sync " + script_id + ": " + res.error_message())


func _on_start_pressed() -> void:
	if _bridge_started:
		_log("Bridge läuft bereits.")
		return
	_log("Starte Python-Runtime (Instanz 'default') ...")
	_sync_workspace_scripts()
	var res: PythonBridgeResult = await PythonBridge.start_instance("default")
	if res.is_ok():
		_bridge_started = true
		_log("Python-Runtime bereit. Demo-Nodes können nun ausgeführt werden.")
	else:
		_log("[FEHLER] Start fehlgeschlagen: " + res.error_message())


func _on_shutdown_pressed() -> void:
	_log("Fahre Bridge herunter (shutdown) ...")
	PythonBridge.shutdown()
	_bridge_started = false
	_log("Bridge gestoppt.")


# ------------------------------------------------------------------ Demos

func _on_basic_pressed() -> void:
	await $DemoBasic.run()


func _on_tasks_pressed() -> void:
	await $DemoTasks.run()


func _on_batch_pressed() -> void:
	await $DemoBatch.run()


func _on_errors_pressed() -> void:
	await $DemoErrors.run()


func _on_multi_pressed() -> void:
	await $DemoMulti.run()


func _exit_tree() -> void:
	# Beim Beenden der Szene die Bridge kontrolliert herunterfahren.
	PythonBridge.shutdown()