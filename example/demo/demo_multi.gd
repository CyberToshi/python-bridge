extends Node
## Demo: Mehrere Python-Instanzen parallel
##
## Startet eine zweite Instanz ('worker') neben der Standard-Instanz,
## verteilt Tasks auf beide und zeigt Statusabfragen. Godot fungiert als
## Vermittler zwischen den Instanzen.

signal logged(line: String)

const SCRIPT_ID := "demo_skript"
const WORKER := "worker"

func run() -> void:
	logged.emit("=== DemoMulti: Zwei Python-Instanzen parallel ===")
	logged.emit("")

	var src: String = PythonBridge.get_script_source(SCRIPT_ID)
	if src == "":
		logged.emit("[FEHLER] Skript nicht im Workspace. Erst 'Bridge starten'.")
		return

	# 1) Zweite Instanz starten.
	logged.emit("Starte zweite Instanz '" + WORKER + "' ...")
	var start: PythonBridgeResult = await PythonBridge.start_instance(WORKER)
	if start.is_error():
		logged.emit("[FEHLER] Worker-Instanz: " + start.error_message())
		return
	logged.emit("Instanz '" + WORKER + "' bereit.")

	# 2) Status beider Instanzen abfragen.
	logged.emit("Status default: " + PythonBridge.instance_status("default") +
		" | worker: " + PythonBridge.instance_status(WORKER))

	# 3) Tasks parallel auf beide Instanzen verteilen (Godot als Vermittler).
	var t_default: PythonBridgeTask = PythonBridgeTask.make_call(
		"multi-default", "script:" + SCRIPT_ID, src,
		"greet", ["Godot-Hauptinstanz"], {"prefix": "Hallo"}, 30000)
	var t_worker: PythonBridgeTask = PythonBridgeTask.make_call(
		"multi-worker", "script:" + SCRIPT_ID, src,
		"greet", ["Worker-Instanz"], {"prefix": "Servus"}, 30000)

	# Explizite Zuordnung zu den Instanzen.
	t_default.instance_id = "default"
	t_worker.instance_id = WORKER
	PythonBridge.submit_task(t_default)
	PythonBridge.submit_task(t_worker)

	var r_def: PythonBridgeResult = await t_default.done
	var r_work: PythonBridgeResult = await t_worker.done

	if r_def.is_ok():
		logged.emit("default -> " + str(r_def.value))
	else:
		logged.emit("[FEHLER] default: " + r_def.error_message())
	if r_work.is_ok():
		logged.emit("worker  -> " + str(r_work.value))
	else:
		logged.emit("[FEHLER] worker: " + r_work.error_message())

	# 4) Worker-Instanz wieder beenden.
	logged.emit("Beende Worker-Instanz ...")
	PythonBridge.stop_instance(WORKER)
	logged.emit("Status worker nach Stop: " + PythonBridge.instance_status(WORKER))

	logged.emit("")
	logged.emit("DemoMulti fertig.")