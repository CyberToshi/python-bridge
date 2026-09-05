extends Node
## Demo: call_script / execute_script / define_script
##
## Zeigt, wie GDScript-Daten an Python übergeben und strukturierte
## Ergebnisse zurückgeholt werden (Typkonvertierung über die Bridge).

signal logged(line: String)

const SCRIPT_ID := "demo_skript"

func run() -> void:
	logged.emit("=== DemoBasic: call_script / execute_script / define_script ===")
	logged.emit("")

	if PythonBridge.get_script_source(SCRIPT_ID) == "":
		logged.emit("[FEHLER] Skript nicht im Workspace. Erst 'Bridge starten'.")
		return

	# 1) call_script: Funktionsaufruf mit Args + Kwargs.
	var r1: PythonBridgeResult = await PythonBridge.call_script(
		SCRIPT_ID, "calculate", [3.0], {"b": 4.0})
	if r1.is_ok():
		logged.emit("call_script calculate(3, b=4) = " + str(r1.value))
	else:
		logged.emit("[FEHLER] " + r1.error_message())

	var r2: PythonBridgeResult = await PythonBridge.call_script(
		SCRIPT_ID, "greet", ["Welt"], {"prefix": "Hallo"})
	if r2.is_ok():
		logged.emit("call_script greet('Welt', prefix='Hallo') = " + str(r2.value))

	# 2) Liste + Dict (strukturierte Daten) aus Python.
	var r3: PythonBridgeResult = await PythonBridge.call_script(
		SCRIPT_ID, "vector_list", [4])
	if r3.is_ok():
		logged.emit("call_script vector_list(4) = " + str(r3.value))
		if r3.value is Array:
			logged.emit("  -> Typ: Array mit " + str(r3.value.size()) + " Einträgen")

	# 3) fibonacci: int -> Array.
	var r4: PythonBridgeResult = await PythonBridge.call_script(
		SCRIPT_ID, "fibonacci", [8])
	if r4.is_ok():
		logged.emit("call_script fibonacci(8) = " + str(r4.value))

	# 4) execute_script: komplettes Skript mit 'input'-Variable ausführen.
	#    Das Beispielskript antwortet mit result = {"received": input}.
	var r5: PythonBridgeResult = await PythonBridge.execute_script(
		SCRIPT_ID, {"text": "Hallo aus Godot", "zahl": 42})
	if r5.is_ok():
		logged.emit("execute_script(input) = " + str(r5.value))

	# 5) define_script: Skript einmalig im Python-Prozess registrieren.
	var r6: PythonBridgeResult = await PythonBridge.define_script(SCRIPT_ID)
	if r6.is_ok():
		logged.emit("define_script ok (Kontext im Python-Prozess registriert)")
	else:
		logged.emit("[FEHLER] define_script: " + r6.error_message())

	logged.emit("")
	logged.emit("DemoBasic fertig.")