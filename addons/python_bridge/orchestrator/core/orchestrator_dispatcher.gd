class_name OrchestratorDispatcher
extends RefCounted
## Vergibt Tasks an Server und überwacht sie (Phase 5).
##
## Der Dispatcher verbindet die drei Kernbausteine:
##
##     ServerManager ──┐
##     TaskManager  ───┼──► Dispatcher ──► Router ──► gewählter Server
##     Config       ───┘
##
## Er implementiert **keine** zweite Kommunikationswelt (§24). Der eigentliche
## Transport läuft über Signale: `dispatch_requested` / `cancel_requested` sagt
## logisch „Führe Task X auf Server B aus" – wer das verschickt (bestehende
## Bridge, Cluster-Manager, …), entscheidet die aufrufende Schicht. Die
## Rückmeldungen des Workers kommen über `on_ack`, `on_task_started` und
## `on_task_result` herein.
##
## Enthalten sind:
##   * Zuweisung nach Priorität (§18) und Router-Auswahl (§17),
##   * ACK-System mit Timeout (§8),
##   * Task-Timeout, Retry mit Grenze (§19),
##   * Reassignment bei Server-Ausfall, ohne COMPLETED erneut auszuführen (§9),
##   * Abbruch inkl. Bestätigungs-Signal (§20),
##   * strukturiertes Ereignisprotokoll (§22).

signal dispatch_requested(task_id: String, server_id: String, python_task: String, required_files: Array)
## Vollstaendige Bridge-Payload fuer Transport-Adapter; das alte Signal oben
## bleibt aus Kompatibilitaetsgruenden erhalten.
signal dispatch_payload_requested(task_id: String, server_id: String, payload: Dictionary)
## `attempt` ist die Versuchsnummer, die abgebrochen werden soll. Ein Abbruch
## darf keinen **neueren** Versuch treffen (der Worker prueft das ebenfalls).
signal cancel_requested(task_id: String, server_id: String, attempt: int)
## Eine Aufgabe braucht Eingabedateien, die auf dem Zielrechner fehlen (§11/
## §16). Der Datei-Transfer beginnt; gesendet wird erst nach `notify_files_ready`.
signal data_requested(task_id: String, server_id: String, file_ids: Array)
signal task_files_ready(task_id: String, server_id: String)
signal task_dispatched(task_id: String, server_id: String, attempt: int)
signal task_progress(task_id: String, server_id: String, stage: String, fraction: float, text: String)
signal task_completed(task_id: String, server_id: String, result: Variant)
signal task_failed(task_id: String, server_id: String, error: String, hint: String)
signal server_lost(server_id: String, affected_task_ids: Array)

var cfg: OrchestratorConfig
var servers: OrchestratorServerManager
var tasks: OrchestratorTaskManager
var router: OrchestratorRouter

## Datei-Unterstuetzung aktiv? Nur dann wird eine Aufgabe mit
## `required_files` in WAITING_FOR_DATA gehalten, bis die Dateien liegen.
var file_support: bool = false

var _pending_payload: Dictionary = {}    # task_id -> Auftrag, wartet auf Dateien
var _awaiting_data: Dictionary = {}      # task_id -> server_id
var _ack_deadlines: Dictionary = {}      # task_id -> Ablaufzeit (ms)
var _run_deadlines: Dictionary = {}      # task_id -> Ablaufzeit (ms)
var _retry_after: Dictionary = {}        # task_id -> frühestens wieder einreihen (ms)
var _awaiting_cancel: Dictionary = {}    # task_id -> server_id
var _reserved_by_task: Dictionary = {}   # task_id -> server_id (Kapazitaetsreservierung)
var _events: Array[String] = []
var _max_events := 200


func _init(p_servers: OrchestratorServerManager, p_tasks: OrchestratorTaskManager,
		p_config: OrchestratorConfig = null, p_router: OrchestratorRouter = null) -> void:
	servers = p_servers
	tasks = p_tasks
	cfg = p_config if p_config != null else OrchestratorConfig.defaults()
	router = p_router if p_router != null else OrchestratorRouter.new(servers, cfg)
	servers.server_state_changed.connect(_on_server_state_changed)


# ---------------------------------------------------------------- Aufnahme
## Erzeugt einen neuen Task und reiht ihn ein. Das ist der Weg für eine
## **normale Python-Aufgabe aus dem bestehenden Tool** (§2).
func submit(python_task: String, priority := OrchestratorTask.Priority.NORMAL,
		required_files: Array = [], requirements: Dictionary = {},
		target := "", task_id := "") -> OrchestratorTask:
	var task := tasks.create_task(python_task, priority, required_files, requirements, task_id)
	if task == null:
		_log("Task '%s' abgelehnt (doppelte ID?)" % task_id)
		return null
	task.target = target
	if not tasks.enqueue(task.task_id):
		_log("Task %s konnte nicht eingereiht werden" % task.task_id)
		return null
	_pending_log(task, "erstellt (%s)" % OrchestratorTask.priority_text(priority))
	return task


## Nimmt einen bereits erzeugten (CREATED) Task in die Orchestrierung auf.
func accept_task(task_id: String) -> bool:
	if not tasks.has_task(task_id):
		return false
	if not tasks.enqueue(task_id):
		return false
	_pending_log(tasks.get_task(task_id), "aufgenommen")
	return true


# ---------------------------------------------------------------- Zuweisung
## Verteilt wartende Tasks (nach Priorität) auf geeignete Server.
## Liefert die Zahl der in diesem Durchlauf verschickten Zuweisungen.
func dispatch(now_ms: int = -1) -> int:
	var now := _resolve_now(now_ms)
	_promote_due_retries(now)
	var sent := 0
	for task in tasks.queued_by_priority():
		if sent >= cfg.max_dispatch_per_tick:
			break
		var t := task as OrchestratorTask
		if not _can_dispatch(t):
			# Keine Versuche mehr übrig – sauber scheitern statt hängen bleiben.
			tasks.fail(t.task_id, "maximale Versuche erreicht")
			_log("Task %s → FAILED (maximale Versuche)" % t.task_id)
			continue
		if _awaiting_data.has(t.task_id):
			continue # wartet bereits auf seine Dateien
		var server_id := router.select(t)
		if server_id == "":
			continue
		if _assign_and_send(t, server_id, now):
			sent += 1
	return sent


func _assign_and_send(task: OrchestratorTask, server_id: String, now_ms: int) -> bool:
	# Wichtig: erst zuweisen (das zaehlt den Versuch hoch), DANN die Nachricht
	# bauen. Sonst enthielte der Auftrag eine veraltete Versuchsnummer und der
	# Worker-ACK wuerde als "alter Versuch" verworfen.
	if not tasks.assign(task.task_id, server_id):
		return false
	var payload := build_payload(task)
	# Grosse Projekte pruefen: eine Ablehnung mit klarer Begruendung ist besser
	# als ein Auftrag, der unterwegs stumm scheitert (§6, klare Fehler).
	var size := JSON.stringify(payload).to_utf8_buffer().size()
	if size > cfg.max_payload_bytes:
		var reason := "Projekt zu gross fuer die Direktuebertragung (%.1f MB, Limit %.1f MB)" % [
			size / 1048576.0, cfg.max_payload_bytes / 1048576.0]
		tasks.fail(task.task_id, reason)
		_log("Task %s → FAILED (%s)" % [task.task_id, reason])
		task_failed.emit(task.task_id, server_id, reason,
			"Projekt verkleinern; grosse Eingabedaten folgen mit dem Datei-Transfer.")
		return false
	_reserve(task.task_id, server_id)
	_run_deadlines.erase(task.task_id)
	var server := servers.get_server(server_id)
	var server_name := server.name if server != null else server_id
	# §11/§16: Erst ausfuehren, wenn die Eingabedaten auf dem Zielrechner liegen.
	if file_support and not task.required_files.is_empty():
		if not tasks.await_data(task.task_id):
			_release(task.task_id)
			return false
		_pending_payload[task.task_id] = payload
		_awaiting_data[task.task_id] = server_id
		_ack_deadlines.erase(task.task_id)
		_log("Task %s → WAITING_FOR_DATA auf %s (%d Datei(en))" % [
			task.task_id, server_name, task.required_files.size()])
		data_requested.emit(task.task_id, server_id, task.required_files.duplicate())
		return true
	_ack_deadlines[task.task_id] = now_ms + cfg.ack_timeout_ms
	_log("Task %s assigniert → %s (Versuch %d)" % [task.task_id, server_name, task.attempts])
	task_dispatched.emit(task.task_id, server_id, task.attempts)
	dispatch_requested.emit(task.task_id, server_id, task.python_task, task.required_files.duplicate())
	dispatch_payload_requested.emit(task.task_id, server_id, payload)
	return true


## Die benoetigten Dateien liegen verifiziert auf dem Server (§14): jetzt darf
## der Auftrag rausgehen. Wird vom Datei-Transfer ueber den Manager gerufen.
func notify_files_ready(task_id: String) -> bool:
	if not _awaiting_data.has(task_id):
		return false
	var server_id := str(_awaiting_data[task_id])
	_awaiting_data.erase(task_id)
	var payload: Dictionary = _pending_payload.get(task_id, {})
	_pending_payload.erase(task_id)
	var task := tasks.get_task(task_id)
	if task == null or task.is_terminal():
		return false
	if task.state != OrchestratorTask.State.WAITING_FOR_DATA:
		return false
	if task.assigned_server != server_id:
		return false
	_ack_deadlines[task_id] = _resolve_now(-1) + cfg.ack_timeout_ms
	_log("Task %s Dateien bereit → an %s senden" % [task_id, server_id])
	task_files_ready.emit(task_id, server_id)
	task_dispatched.emit(task_id, server_id, task.attempts)
	dispatch_requested.emit(task_id, server_id, task.python_task, task.required_files.duplicate())
	dispatch_payload_requested.emit(task_id, server_id, payload)
	return true


## Dateien konnten nicht bereitgestellt werden (Transfer-Fehler, Datei zu
## gross, Platte voll, Quelle weg): Aufgabe neu bewerten statt sie zu verlieren.
func on_data_failed(task_id: String, reason: String, now_ms: int = -1) -> bool:
	var was_waiting := _awaiting_data.has(task_id) or _pending_payload.has(task_id)
	_awaiting_data.erase(task_id)
	_pending_payload.erase(task_id)
	if not was_waiting:
		return false
	var task := tasks.get_task(task_id)
	if task == null or task.is_terminal():
		return false
	_log("Task %s Daten fehlgeschlagen: %s" % [task_id, reason])
	return _recover_task(task, reason, now_ms)


## Baut die Draht-Nachricht eines Tasks aus dem Modell (eine Stelle, damit
## Modell und Protokoll nicht auseinanderlaufen).
func build_payload(task: OrchestratorTask) -> Dictionary:
	var payload := {
		"t": "run",
		"task_id": task.task_id,
		"attempt": task.attempts,
		"script": task.python_task,
		"command": str(task.meta.get("command", "run")),
		"input": task.meta.get("input", {}),
		"function": str(task.meta.get("function", "")),
		"args": task.meta.get("args", []),
		"kwargs": task.meta.get("kwargs", {}),
		"source": str(task.meta.get("source", "")),
		"required_files": task.required_files.duplicate(),
	}
	# Eingabedateien: nur logische IDs + Anzeigename. Absolute Pfade des
	# Hauptrechners verlassen diesen Rechner **nie** (§15).
	var input_files: Variant = task.meta.get("input_files", null)
	if input_files is Array and not (input_files as Array).is_empty():
		payload["input_files"] = input_files
	# Projekt-/Build-Angaben nur mitschicken, wenn es sie gibt (schmales Protokoll).
	var files: Variant = task.meta.get("files", null)
	if files is Dictionary and not (files as Dictionary).is_empty():
		payload["files"] = files
		payload["entry"] = str(task.meta.get("entry", ""))
		payload["requirements"] = str(task.meta.get("requirements", ""))
		payload["build"] = str(task.meta.get("build", "auto"))
	return payload


## Bestätigung des Zielrechners (§8). Ohne gültiges ACK bleibt der Task unter
## Kontrolle des Orchestrators (ACK-Timeout → Neu-Zuweisung).
func on_ack(task_id: String, server_id: String, attempt: int = -1) -> bool:
	var task := tasks.get_task(task_id)
	if task == null or server_id == "":
		return false
	if task.assigned_server != server_id:
		return false
	if attempt > 0 and task.attempts != attempt:
		return false # ACK eines veralteten Versuchs
	if task.is_terminal() or task.state not in [OrchestratorTask.State.ASSIGNED, OrchestratorTask.State.WAITING_FOR_DATA]:
		return false
	if not tasks.acknowledge(task_id, server_id):
		return false
	_ack_deadlines.erase(task_id)
	_log("Task %s ACK von %s" % [task_id, server_id])
	return true


## Der Worker meldet, dass er die Ausführung begonnen hat.
func on_task_started(task_id: String, server_id: String, now_ms: int = -1, attempt: int = -1) -> bool:
	var task := tasks.get_task(task_id)
	if task == null or task.assigned_server != server_id:
		return false
	if attempt > 0 and task.attempts != attempt:
		return false
	if task.state not in [OrchestratorTask.State.ASSIGNED, OrchestratorTask.State.WAITING_FOR_DATA]:
		return false
	if not tasks.mark_running(task_id):
		return false
	var now := _resolve_now(now_ms)
	_run_deadlines[task_id] = now + cfg.task_timeout_ms
	_log("Task %s → RUNNING auf %s" % [task_id, server_id])
	return true


## Zwischenmeldung des Workers (Umgebung/Build/Fortschritt). Aendert den
## Zustand nicht, macht aber sichtbar, was gerade passiert (§21/§22).
func on_task_progress(task_id: String, server_id: String, stage: String,
		fraction: float, text := "", attempt: int = -1) -> bool:
	var task := tasks.get_task(task_id)
	if task == null or task.is_terminal():
		return false
	if task.assigned_server != "" and task.assigned_server != server_id:
		return false
	if attempt > 0 and task.attempts != attempt:
		return false
	task.progress = clampf(fraction, 0.0, 1.0)
	task.progress_stage = stage
	task.progress_text = text
	task.updated_at_ms = Time.get_ticks_msec()
	task_progress.emit(task_id, server_id, stage, task.progress, text)
	return true


## Ergebnis eines Tasks vom Worker. Erfolg → COMPLETED, sonst Retry oder FAILED.
func on_task_result(task_id: String, server_id: String, success: bool,
		result: Variant = null, error := "", now_ms: int = -1, attempt: int = -1,
		hint := "", build: Dictionary = {}) -> bool:
	var task := tasks.get_task(task_id)
	if task == null or task.assigned_server != server_id or task.is_terminal():
		return false
	if attempt > 0 and task.attempts != attempt:
		return false # Ergebnis eines alten/reassigned Versuchs
	if task.state not in [OrchestratorTask.State.ASSIGNED, OrchestratorTask.State.WAITING_FOR_DATA, OrchestratorTask.State.RUNNING]:
		return false
	task.error_hint = hint
	if not build.is_empty():
		task.build = build
	_ack_deadlines.erase(task_id)
	_run_deadlines.erase(task_id)
	_release(task_id)
	if success:
		_ensure_running(task)
		if not tasks.complete(task_id, result):
			return false
		_log("Task %s → COMPLETED auf %s" % [task_id, server_id])
		task_completed.emit(task_id, server_id, result)
		return true
	# Fehler: nur wiederholen, solange Versuche übrig sind (§19).
	# Hinweis des Workers mitloggen: der Benutzer soll nicht im Terminal suchen.
	if hint != "":
		_log("Task %s Hinweis: %s" % [task_id, hint])
	_log("Task %s Fehler auf %s: %s" % [task_id, server_id, error if error != "" else "unbekannt"])
	return _recover_task(task, error if error != "" else "Python-Ausführung fehlgeschlagen", now_ms)


# ---------------------------------------------------------------- Abbruch
## Bricht einen Task ab und bittet den Worker um Bestätigung (§20).
func cancel(task_id: String) -> bool:
	var task := tasks.get_task(task_id)
	if task == null or task.is_terminal():
		return false
	var server_id := task.assigned_server
	_ack_deadlines.erase(task_id)
	_run_deadlines.erase(task_id)
	_retry_after.erase(task_id)
	_awaiting_data.erase(task_id)
	_pending_payload.erase(task_id)
	_release(task_id)
	if server_id != "":
		_awaiting_cancel[task_id] = server_id
		cancel_requested.emit(task_id, server_id, task.attempts)
	if not tasks.cancel(task_id):
		return false
	_log("Task %s → CANCELLED%s" % [task_id, " (Abbruch angefordert bei %s)" % server_id if server_id != "" else ""])
	return true


## Bestätigung des Workers, dass der Abbruch angekommen ist.
func on_cancel_ack(task_id: String, server_id: String) -> bool:
	if _awaiting_cancel.get(task_id, "") != server_id:
		return false
	_awaiting_cancel.erase(task_id)
	_log("Task %s Abbruch von %s bestätigt" % [task_id, server_id])
	return true


func is_awaiting_cancel_ack(task_id: String) -> bool:
	return _awaiting_cancel.has(task_id)


# ---------------------------------------------------------------- Ausfall / Reassignment
## Ein Server ist ausgefallen: betroffene, **nicht sicher abgeschlossene** Tasks
## werden neu bewertet (§9). COMPLETED bleibt unangetastet.
func on_server_lost(server_id: String) -> Array:
	var affected: Array = []
	for task in tasks.tasks():
		var t := task as OrchestratorTask
		if t.assigned_server != server_id:
			continue
		if t.state in [OrchestratorTask.State.ASSIGNED, OrchestratorTask.State.WAITING_FOR_DATA, OrchestratorTask.State.RUNNING]:
			affected.append(t.task_id)
	if affected.is_empty():
		return affected
	server_lost.emit(server_id, affected.duplicate())
	for task_id in affected:
		var task := tasks.get_task(task_id)
		if task != null:
			_recover_task(task, "Server '%s' ausgefallen" % server_id)
	return affected


func _on_server_state_changed(server_id: String, old_state: int, new_state: int) -> void:
	if new_state == OrchestratorServer.NodeState.DISCONNECTED \
			and old_state != OrchestratorServer.NodeState.DISCONNECTED:
		on_server_lost(server_id)


# ---------------------------------------------------------------- Tick / Timeouts
## Pro Frame aufrufen: Server bewerten, Retries freigeben, Timeouts erkennen.
func tick(now_ms: int = -1) -> void:
	var now := _resolve_now(now_ms)
	servers.tick(now)
	_promote_due_retries(now)
	_expire_ack_deadlines(now)
	_expire_run_deadlines(now)


## Bequemer Schritt für Tests/Demo: tick + dispatch.
func step(now_ms: int = -1) -> int:
	tick(now_ms)
	return dispatch(now_ms)


func _promote_due_retries(now_ms: int) -> void:
	if _retry_after.is_empty():
		return
	for task_id in _retry_after.keys():
		if now_ms < int(_retry_after[task_id]):
			continue
		_retry_after.erase(task_id)
		var task := tasks.get_task(task_id)
		if task != null and task.state == OrchestratorTask.State.RETRYING:
			tasks.transition(task_id, OrchestratorTask.State.QUEUED)
			_log("Task %s wieder in der Queue" % task_id)


func _expire_ack_deadlines(now_ms: int) -> void:
	for task_id in _ack_deadlines.keys():
		if now_ms < int(_ack_deadlines[task_id]):
			continue
		_ack_deadlines.erase(task_id)
		var task := tasks.get_task(task_id)
		if task == null or task.is_terminal():
			continue
		if task.state in [OrchestratorTask.State.ASSIGNED, OrchestratorTask.State.WAITING_FOR_DATA]:
			_log("Task %s kein ACK innerhalb %d ms" % [task_id, cfg.ack_timeout_ms])
			_recover_task(task, "ACK-Timeout (%d ms)" % cfg.ack_timeout_ms, now_ms)


func _expire_run_deadlines(now_ms: int) -> void:
	for task_id in _run_deadlines.keys():
		if now_ms < int(_run_deadlines[task_id]):
			continue
		_run_deadlines.erase(task_id)
		var task := tasks.get_task(task_id)
		if task == null or task.state != OrchestratorTask.State.RUNNING:
			continue
		_log("Task %s Timeout nach %d ms" % [task_id, cfg.task_timeout_ms])
		_recover_task(task, "Task-Timeout (%d ms)" % cfg.task_timeout_ms, now_ms)


# ---------------------------------------------------------------- Intern
## Rettet einen nicht abgeschlossenen Task: retry, wenn Versuche übrig sind,
## sonst FAILED. Kein Task geht stillschweigend verloren.
func _recover_task(task: OrchestratorTask, reason: String, now_ms: int = -1) -> bool:
	var now := _resolve_now(now_ms)
	var was_active := task.assigned_server != "" and task.state \
			in [OrchestratorTask.State.ASSIGNED, OrchestratorTask.State.WAITING_FOR_DATA,
				OrchestratorTask.State.RUNNING]
	_ack_deadlines.erase(task.task_id)
	_run_deadlines.erase(task.task_id)
	_awaiting_data.erase(task.task_id)
	_pending_payload.erase(task.task_id)
	_release(task.task_id)
	task.error = reason
	if was_active:
		# §20-Lücke geschlossen: der bisherige Worker kann den Task ggf. noch
		# ausführen (z. B. ACK kam nie an, oder Server war nur langsam). Ohne
		# Abbruchbefehl liefen alte und neue Versuche parallel → Doppelausführung.
		# Bei einem wirklich toten Worker ist das Senden ein No-op (Transport
		# verwirft es still). Die Versuchsnummer verhindert, dass ein spaeter
		# eintreffender Abbruch den **neuen** Versuch mit abwuergt.
		cancel_requested.emit(task.task_id, task.assigned_server, task.attempts)
	if _can_retry(task) and tasks.retry(task.task_id):
		_retry_after[task.task_id] = now + cfg.retry_delay_ms
		_log("Task %s → RETRYING (%s)" % [task.task_id, reason])
		return true
	if tasks.fail(task.task_id, reason):
		_log("Task %s → FAILED (%s)" % [task.task_id, reason])
		task_failed.emit(task.task_id, task.assigned_server, reason, task.error_hint)
	return false


## Ob noch ein weiterer Versuch erlaubt ist (analog zu TaskManager.retry()).
func _can_retry(task: OrchestratorTask) -> bool:
	return task.attempts < task.max_retries + 1


func _can_dispatch(task: OrchestratorTask) -> bool:
	return task.attempts < task.max_retries + 1


## Reserviert einen Queue-Platz beim Zielserver. Ohne das koennte der
## Orchestrator zwischen zwei Heartbeats ueber die Kapazitaet hinaus zuweisen.
func _reserve(task_id: String, server_id: String) -> void:
	_release(task_id)
	var server := servers.get_server(server_id)
	if server == null:
		return
	server.reserved += 1
	_reserved_by_task[task_id] = server_id


## Gibt die Reservierung eines Tasks wieder frei (Abschluss, Fehler, Abbruch).
func _release(task_id: String) -> void:
	var server_id := str(_reserved_by_task.get(task_id, ""))
	if server_id == "":
		return
	_reserved_by_task.erase(task_id)
	var server := servers.get_server(server_id)
	if server != null and server.reserved > 0:
		server.reserved -= 1


func _ensure_running(task: OrchestratorTask) -> void:
	if task.state in [OrchestratorTask.State.ASSIGNED, OrchestratorTask.State.WAITING_FOR_DATA]:
		tasks.mark_running(task.task_id)


# ---------------------------------------------------------------- Abfragen
func pending_ack_count() -> int:
	return _ack_deadlines.size()


func pending_retry_count() -> int:
	return _retry_after.size()


func has_pending_ack(task_id: String) -> bool:
	return _ack_deadlines.has(task_id)


func is_waiting_for_data(task_id: String) -> bool:
	return _awaiting_data.has(task_id)


func stats() -> Dictionary:
	var running := 0
	var queued := 0
	var waiting := 0
	var completed := 0
	var failed := 0
	var cancelled := 0
	var retrying := 0
	var assigned := 0
	for task in tasks.tasks():
		match (task as OrchestratorTask).state:
			OrchestratorTask.State.QUEUED:
				queued += 1
			OrchestratorTask.State.ASSIGNED:
				assigned += 1
			OrchestratorTask.State.WAITING_FOR_DATA:
				waiting += 1
			OrchestratorTask.State.RUNNING:
				running += 1
			OrchestratorTask.State.COMPLETED:
				completed += 1
			OrchestratorTask.State.FAILED:
				failed += 1
			OrchestratorTask.State.CANCELLED:
				cancelled += 1
			OrchestratorTask.State.RETRYING:
				retrying += 1
	return {
		"tasks": tasks.task_count(),
		"queued": queued,
		"assigned": assigned,
		"waiting_for_data": waiting,
		"running": running,
		"completed": completed,
		"failed": failed,
		"cancelled": cancelled,
		"retrying": retrying,		"pending_ack": _ack_deadlines.size(),
		"pending_retry": _retry_after.size(),
		"waiting_for_files": _awaiting_data.size(),
			"building": _count_stage(tasks, "build"),
			"preparing": _count_stage(tasks, "env") + _count_stage(tasks, "deps"),
		"reserved_slots": _reserved_by_task.size(),
		"available_servers": servers.available_servers().size(),
	}


## Strukturiertes Ereignisprotokoll (§22), neueste zuletzt.
func event_log() -> Array[String]:
	return _events.duplicate()


func _pending_log(task: OrchestratorTask, what: String) -> void:
	if task != null:
		_log("Task %s %s" % [task.task_id, what])


func _log(text: String) -> void:
	_events.append(text)
	if _events.size() > _max_events:
		_events = _events.slice(_events.size() - _max_events)


## Zaehlt Aufgaben, die gerade in einer bestimmten Build-/Umgebungsphase sind.
static func _count_stage(task_manager: OrchestratorTaskManager, stage: String) -> int:
	var n := 0
	for task in task_manager.tasks():
		var t := task as OrchestratorTask
		if t.progress_stage == stage and not t.is_terminal():
			n += 1
	return n


static func _resolve_now(now_ms: int) -> int:
	return now_ms if now_ms >= 0 else Time.get_ticks_msec()
