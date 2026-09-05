extends Node
## Demo: Fehlerbehandlung
##
## Python-Exceptions kommen strukturiert zurück: Fehlercode (Taxonomie),
## Exception-Typ, Message, Traceback, Task-ID und Instanz-ID.

signal logged(line: String)

const SCRIPT_ID := "demo_skript"

func run() -> void:
	logged.emit("=== DemoErrors: Strukturierte Fehlerbehandlung ===")
	logged.emit("")

	if PythonBridge.get_script_source(SCRIPT_ID) == "":
		logged.emit("[FEHLER] Skript nicht im Workspace. Erst 'Bridge starten'.")
		return

	# 1) Python-Exception (boom wirft ValueError).
	var r1: PythonBridgeResult = await PythonBridge.call_script(
		SCRIPT_ID, "boom", [])
	if r1.is_error():
		logged.emit("Python-Exception sauber empfangen:")
		logged.emit("  code     = " + r1.error_code())
		logged.emit("  type     = " + str(r1.error.get("type", "(kein Typ)")))
		logged.emit("  message  = " + str(r1.error.get("message", "")))
		logged.emit("  task_id  = " + str(r1.error.get("task_id", "")))
		logged.emit("  instance = " + str(r1.error.get("instance_id", "")))
		var tb: Variant = r1.error.get("traceback", "")
		if tb is String and tb != "":
			var erste_zeile: String = tb.split("\n")[0] if tb != "" else ""
			logged.emit("  traceback(1. Zeile) = " + erste_zeile)
	else:
		logged.emit("[WARNUNG] boom() hätte fehlschlagen müssen!")

	# 2) Timeout: Python antwortet zu spät -> TIMEOUT_ERROR.
	var r2: PythonBridgeResult = await PythonBridge.call_script(
		SCRIPT_ID, "slow", [2.0], {}, "default", 0.4)
	if r2.is_error():
		logged.emit("Timeout korrekt erkannt: code=" + r2.error_code() +
			" status=" + r2.status)

	# 3) Unbekanntes Skript -> BRIDGE_ERROR (Skript nicht gefunden).
	var r3: PythonBridgeResult = await PythonBridge.call_script(
		"gibt_es_nicht", "foo", [])
	if r3.is_error():
		logged.emit("Unbekanntes Skript -> " + r3.error_code() + ": " +
			r3.error_message())

	logged.emit("")
	logged.emit("DemoErrors fertig.")