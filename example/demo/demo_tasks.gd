extends Node
## Demo: Task-API (niedrige Ebene)
##
## Zeigt PythonBridgeTask.make_call, submit_task und das 'done'-Signal.
## Tasks erhalten eindeutige IDs und durchlaufen die Zustandsmaschine
## QUEUED -> RUNNING -> COMPLETED / FAILED / TIMEOUT / CANCELLED.

signal logged(line: String)

const SCRIPT_ID := "demo_skript"

func run() -> void:
	logged.emit("=== DemoTasks: Task-API (submit_task, Signal done, cancel) ===")
	logged.emit("")

	var src: String = PythonBridge.get_script_source(SCRIPT_ID)
	if src == "":
		logged.emit("[FEHLER] Skript nicht im Workspace. Erst 'Bridge starten'.")
		return

	# 1) Task erzeugen (low-level) und einreichen.
	var task: PythonBridgeTask = PythonBridgeTask.make_call(
		"demo-task-1", "script:" + SCRIPT_ID, src,
		"greet", ["Task-API"], {"prefix": "Hi"}, 30000)
	var submitted: PythonBridgeResult = PythonBridge.submit_task(task)
	if submitted.is_error():
		logged.emit("[FEHLER] submit_task: " + submitted.error_message())
		return
	logged.emit("Task eingereicht: id=" + task.id + " state=" + task.state_text())

	# 2) Auf das Ergebnis warten (Signal 'done').
	var result: PythonBridgeResult = await task.done
	if result.is_ok():
		logged.emit("Task 'done': greet = " + str(result.value) + " (state=" + task.state_text() + ")")
	else:
		logged.emit("[FEHLER] Task: " + result.error_message())

	# 3) Prioritäten: Task mit hoher Priorität (0 = höchste).
	var task_p: PythonBridgeTask = PythonBridgeTask.make_call(
		"demo-task-prio", "script:" + SCRIPT_ID, src,
		"calculate", [5.0, 2.0], {}, 30000, 0)
	PythonBridge.submit_task(task_p)
	var res_p: PythonBridgeResult = await task_p.done
	if res_p.is_ok():
		logged.emit("Prioritäts-Task: calculate(5, 2) = " + str(res_p.value))

	# 4) Timeout: Task, der nie antworten kann (zu kurzer Timeout).
	var task_t: PythonBridgeTask = PythonBridgeTask.make_call(
		"demo-task-timeout", "script:" + SCRIPT_ID, src,
		"slow", [2.0], {}, 300)  # 300 ms Timeout, Python schläft 2 s
	PythonBridge.submit_task(task_t)
	var res_t: PythonBridgeResult = await task_t.done
	if res_t.is_error():
		logged.emit("Timeout-Task korrekt abgebrochen: code=" + res_t.error_code() +
			" status=" + res_t.status)

	# 5) Cancel: Task einreichen und sofort abbrechen.
	var task_c: PythonBridgeTask = PythonBridgeTask.make_call(
		"demo-task-cancel", "script:" + SCRIPT_ID, src,
		"slow", [5.0], {}, 60000)
	PythonBridge.submit_task(task_c)
	logged.emit("Cancelle Task " + task_c.id + " ...")
	var cancelled: bool = PythonBridge.cancel_task(task_c.id)
	logged.emit("cancel_task -> " + str(cancelled))
	var res_c: PythonBridgeResult = await task_c.done
	logged.emit("Cancel-Ergebnis: status=" + res_c.status)

	logged.emit("")
	logged.emit("DemoTasks fertig.")