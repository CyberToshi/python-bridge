extends Node
## Demo: Task-Batching
##
## Mehrere sehr kurz aufeinanderfolgende Aufrufe werden vom Task-Manager
## zu einem Paket zusammengefasst (max_batch_size / max_batch_delay_ms).
## Das demonstriert die Frame-Synchronisation: Python antwortet mit einem
## Batch, Godot verteilt die Einzelergebnisse kontrolliert im Main Thread.

signal logged(line: String)

const SCRIPT_ID := "demo_skript"
const COUNT := 8

func run() -> void:
	logged.emit("=== DemoBatch: " + str(COUNT) + " schnelle Aufrufe -> Batching ===")
	logged.emit("")

	var src: String = PythonBridge.get_script_source(SCRIPT_ID)
	if src == "":
		logged.emit("[FEHLER] Skript nicht im Workspace. Erst 'Bridge starten'.")
		return

	# Alle Tasks fast gleichzeitig einreichen (ohne await dazwischen),
	# damit der Batch-Window sie zusammenfasst.
	var tasks: Array[PythonBridgeTask] = []
	for i in range(COUNT):
		var task: PythonBridgeTask = PythonBridgeTask.make_call(
			"batch-" + str(i), "script:" + SCRIPT_ID, src,
			"calculate", [float(i + 1), 2.0], {}, 30000)
		var submitted: PythonBridgeResult = PythonBridge.submit_task(task)
		if submitted.is_ok():
			tasks.append(task)
		else:
			logged.emit("[FEHLER] submit " + str(i) + ": " + submitted.error_message())

	logged.emit(str(tasks.size()) + " Tasks eingereicht, warte auf Ergebnisse ...")

	# Auf alle warten. Die Reihenfolge der Einzelergebnisse bleibt erhalten.
	var values: Array = []
	for task in tasks:
		var result: PythonBridgeResult = await task.done
		if result.is_ok():
			values.append(result.value)
		else:
			values.append("ERR:" + result.error_code())

	logged.emit("Ergebnisse (Reihenfolge erhalten): " + str(values))
	logged.emit("Summe der Ergebnisse: " + str(_sum(values)))

	logged.emit("")
	logged.emit("DemoBatch fertig.")


func _sum(values: Array) -> float:
	var total := 0.0
	for v in values:
		if v is float or v is int:
			total += float(v)
	return total