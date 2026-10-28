extends Node
## Minimalbeispiel — der komplette Umfang.
##
## Kein Python-File, keine Konfiguration, kein Wrapper: die Bridge legt venv
## und Server-Prozess beim ersten start_instance() selbst an und führt danach
## eine Zeile Python aus.
##
## Voraussetzung im Projekt (macht das Plugin beim Aktivieren automatisch):
##   [autoload]
##   PythonBridge="*res://addons/python_bridge/core/python_bridge.gd"

func _ready() -> void:
	var started: PythonBridgeResult = await PythonBridge.start_instance()
	if started.is_error():
		push_error("[minimal] Start fehlgeschlagen: " + started.error_message())
		return
	var result: PythonBridgeResult = await PythonBridge.execute("result = 6 * 7")
	print("[minimal] 6 * 7 = ", result.value)

func _exit_tree() -> void:
	PythonBridge.shutdown()
