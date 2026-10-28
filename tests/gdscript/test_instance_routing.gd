class_name PBTestInstanceRouting
extends PBTests
## Regressionstests fuer das Nachrichten-Routing der BridgeInstance.
##
## Hintergrund: `_handle_message()` leitet nur eine Whitelist von Typen an die
## Facade weiter. Fehlte dort `MSG_INTROSPECT_RESULT`, verschwand die Antwort im
## "unknown message"-Zweig — `introspect_script()` lief dann in einen Timeout,
## und damit auch die Wrapper-Generierung im Dock. Diese Suite pinnt die
## Whitelist.

func _instance():
	# settings leer: das Routing fuer Resultate braucht keine Konfiguration.
	return BridgeInstance.new(null, "routing-test", {})

func test_introspect_result_reaches_facade() -> void:
	var inst = _instance()
	var seen: Array = []
	inst.message_received.connect(func(_i: String, parsed: Dictionary) -> void:
		seen.append(parsed)
	)
	inst._handle_message({"msg": {
		"type": PythonProtocol.MSG_INTROSPECT_RESULT,
		"id": "introspect-7",
		"status": "ok",
		"functions": [{"name": "alpha"}],
	}})
	assert_eq(seen.size(), 1, "introspect_result muss die Facade erreichen")
	if seen.size() == 1:
		var msg: Dictionary = (seen[0] as Dictionary).get("msg", {})
		assert_eq(str(msg.get("type", "")), PythonProtocol.MSG_INTROSPECT_RESULT)
		assert_eq(str(msg.get("id", "")), "introspect-7")
	inst.free()

func test_task_result_still_reaches_facade() -> void:
	var inst = _instance()
	var seen: Array = []
	inst.message_received.connect(func(_i: String, parsed: Dictionary) -> void:
		seen.append(parsed)
	)
	inst._handle_message({"msg": {
		"type": PythonProtocol.MSG_TASK_RESULT,
		"task_id": "task-1",
	}})
	assert_eq(seen.size(), 1, "Task-Ergebnisse duerfen nicht verloren gehen")
	inst.free()

func test_pending_introspect_result_becomes_success() -> void:
	var bridge = (load("res://addons/python_bridge/core/python_bridge.gd") as GDScript).new()
	var result: PythonBridgeResult = bridge._introspect_result_to_result({
		"ok": true,
		"functions": [{"name": "alpha"}, {"name": "beta"}],
	})
	assert_true(result.is_ok(), "ok=true muss ein Erfolgsergebnis sein")
	assert_eq((result.value as Array).size(), 2)
	bridge.free()

func test_failed_introspect_becomes_error() -> void:
	var bridge = (load("res://addons/python_bridge/core/python_bridge.gd") as GDScript).new()
	var result: PythonBridgeResult = bridge._introspect_result_to_result({
		"ok": false,
		"error": {"code": "BRIDGE_ERROR", "message": "syntax error"},
	})
	assert_true(result.is_error(), "ok=false muss ein Fehlerergebnis sein")
	bridge.free()
