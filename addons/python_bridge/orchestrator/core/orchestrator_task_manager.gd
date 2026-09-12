class_name OrchestratorTaskManager
extends RefCounted
## Führt Task-Registry und Zustandsautomat (Phase 3).
##
## Jede Zustandsänderung läuft über `transition()` und wird gegen den
## erlaubten Übergangsgraphen validiert – ungültige Übergänge werden
## abgelehnt statt still den Zustand zu verbiegen. Damit ist jederzeit
## nachvollziehbar, welchem Server ein Task zugewiesen ist und in welchem
## Stadium er sich befindet (siehe Auftrag §7).

signal task_added(task_id: String)
signal task_removed(task_id: String)
signal task_state_changed(task_id: String, old_state: int, new_state: int)
signal task_assigned(task_id: String, server_id: String)

var cfg: OrchestratorConfig

var _tasks: Dictionary = {}       # id -> OrchestratorTask
var _order: Array[String] = []    # Erstellungsreihenfolge


func _init(config: OrchestratorConfig = null) -> void:
	cfg = config if config != null else OrchestratorConfig.defaults()


# ---------------------------------------------------------------- Zustandsgraph
## Erlaubte Übergänge des Task-Zustandsautomaten.
static func allowed_transition(from_state: int, to_state: int) -> bool:
	if from_state == to_state:
		return false
	match from_state:
		OrchestratorTask.State.CREATED:
			return to_state in [OrchestratorTask.State.QUEUED, OrchestratorTask.State.ASSIGNED, OrchestratorTask.State.CANCELLED, OrchestratorTask.State.FAILED]
		OrchestratorTask.State.QUEUED:
			return to_state in [OrchestratorTask.State.ASSIGNED, OrchestratorTask.State.RETRYING, OrchestratorTask.State.CANCELLED, OrchestratorTask.State.FAILED]
		OrchestratorTask.State.ASSIGNED:
			return to_state in [OrchestratorTask.State.WAITING_FOR_DATA, OrchestratorTask.State.RUNNING, OrchestratorTask.State.QUEUED, OrchestratorTask.State.RETRYING, OrchestratorTask.State.CANCELLED, OrchestratorTask.State.FAILED]
		OrchestratorTask.State.WAITING_FOR_DATA:
			return to_state in [OrchestratorTask.State.RUNNING, OrchestratorTask.State.QUEUED, OrchestratorTask.State.RETRYING, OrchestratorTask.State.CANCELLED, OrchestratorTask.State.FAILED]
		OrchestratorTask.State.RUNNING:
			return to_state in [OrchestratorTask.State.COMPLETED, OrchestratorTask.State.FAILED, OrchestratorTask.State.RETRYING, OrchestratorTask.State.CANCELLED]
		OrchestratorTask.State.RETRYING:
			return to_state in [OrchestratorTask.State.QUEUED, OrchestratorTask.State.ASSIGNED, OrchestratorTask.State.CANCELLED, OrchestratorTask.State.FAILED]
		OrchestratorTask.State.FAILED:
			return to_state in [OrchestratorTask.State.RETRYING]
		# COMPLETED und CANCELLED sind terminal.
	return false


# ---------------------------------------------------------------- Erzeugen
func create_task(python_task: String, priority := OrchestratorTask.Priority.NORMAL,
		required_files: Array = [], requirements: Dictionary = {},
		task_id: String = "") -> OrchestratorTask:
	var task := OrchestratorTask.make(python_task, priority, required_files, requirements, task_id)
	if _tasks.has(task.task_id):
		return null    # doppelte ID niemals still überschreiben
	task.max_retries = cfg.max_retries
	_tasks[task.task_id] = task
	_order.append(task.task_id)
	task_added.emit(task.task_id)
	return task


func get_task(task_id: String) -> OrchestratorTask:
	return _tasks.get(task_id, null) as OrchestratorTask


func has_task(task_id: String) -> bool:
	return _tasks.has(task_id)


func task_count() -> int:
	return _tasks.size()


func ids() -> Array[String]:
	return _order.duplicate()


func tasks() -> Array:
	var out: Array = []
	for id in _order:
		var t := get_task(id)
		if t != null:
			out.append(t)
	return out


## Entfernt einen Task aus der Registry (z. B. nach erfolgreichem Abschluss
## und Anzeige). Terminale Tasks bleiben standardmäßig erhalten.
func remove_task(task_id: String) -> bool:
	if not _tasks.has(task_id):
		return false
	_tasks.erase(task_id)
	_order.erase(task_id)
	task_removed.emit(task_id)
	return true


# ---------------------------------------------------------------- Übergänge
## Generischer, validierter Übergang. Aktualisiert den Zeitstempel und meldet
## die Änderung. Liefert false bei unbekanntem Task oder unerlaubtem Übergang.
func transition(task_id: String, to_state: int) -> bool:
	var task := get_task(task_id)
	if task == null:
		return false
	if task.is_terminal() and task.state != OrchestratorTask.State.FAILED:
		return false
	if not allowed_transition(task.state, to_state):
		return false
	var previous := task.state
	task.state = to_state
	task.updated_at_ms = Time.get_ticks_msec()
	task_state_changed.emit(task_id, previous, to_state)
	return true


## CREATED → QUEUED
func enqueue(task_id: String) -> bool:
	return transition(task_id, OrchestratorTask.State.QUEUED)


## * → ASSIGNED (setzt Server + Versuchszähler, löscht altes ACK).
func assign(task_id: String, server_id: String) -> bool:
	var task := get_task(task_id)
	if task == null or server_id == "":
		return false
	if not transition(task_id, OrchestratorTask.State.ASSIGNED):
		return false
	task.assigned_server = server_id
	task.attempts += 1
	task.ack_received = false
	task.error = ""
	task_assigned.emit(task_id, server_id)
	return true


## ASSIGNED → WAITING_FOR_DATA (benötigte Dateien fehlen noch).
func await_data(task_id: String) -> bool:
	return transition(task_id, OrchestratorTask.State.WAITING_FOR_DATA)


## ASSIGNED/WAITING_FOR_DATA → RUNNING
func mark_running(task_id: String) -> bool:
	return transition(task_id, OrchestratorTask.State.RUNNING)


## Bestätigung des Zielrechners (ACK-System, §8). Nur der zugewiesene Server
## darf bestätigen; ohne gültiges ACK bleibt der Task unter Kontrolle des
## Orchestrators.
func acknowledge(task_id: String, server_id: String) -> bool:
	var task := get_task(task_id)
	if task == null or server_id == "":
		return false
	if task.assigned_server != server_id:
		return false
	if task.is_terminal():
		return false
	task.ack_received = true
	task.updated_at_ms = Time.get_ticks_msec()
	return true


func is_acknowledged(task_id: String) -> bool:
	var task := get_task(task_id)
	return task != null and task.ack_received


## RUNNING → COMPLETED
func complete(task_id: String, result: Variant = null) -> bool:
	if not transition(task_id, OrchestratorTask.State.COMPLETED):
		return false
	var task := get_task(task_id)
	if task != null:
		task.result = result
	return true


## * → FAILED (mit Fehlertext).
func fail(task_id: String, error := "") -> bool:
	if not transition(task_id, OrchestratorTask.State.FAILED):
		return false
	var task := get_task(task_id)
	if task != null:
		task.error = error
	return true


## * → CANCELLED (nicht-terminal).
func cancel(task_id: String) -> bool:
	return transition(task_id, OrchestratorTask.State.CANCELLED)


## RUNNING/ASSIGNED/FAILED → RETRYING, sofern noch Versuche übrig sind.
func retry(task_id: String) -> bool:
	var task := get_task(task_id)
	if task == null:
		return false
	if task.attempts >= task.max_retries + 1:
		return false
	return transition(task_id, OrchestratorTask.State.RETRYING)


## Reassignment (§9): einen noch nicht sicher abgeschlossenen Task erneut
## einem (anderen) Server zuweisen. COMPLETED wird nie erneut ausgeführt.
##
## ASSIGNED → ASSIGNED ist kein gültiger Übergang, daher läuft eine laufende
## Zuweisung zuerst über die Queue (bzw. FAILED über RETRYING). Bereits
## laufende Tasks werden dadurch **neu bewertet**, nicht stillschweigend
## verworfen – die Doppelausführungs-Sicherheit liegt bei den eindeutigen
## Task-IDs (§10), die der Worker wiedererkennt.
func reassign(task_id: String, server_id: String) -> bool:
	var task := get_task(task_id)
	if task == null or server_id == "":
		return false
	if task.state == OrchestratorTask.State.COMPLETED:
		return false
	if task.state == OrchestratorTask.State.CANCELLED:
		return false
	# Zurück in die Queue, damit `assign` wieder ein gültiger Übergang ist.
	match task.state:
		OrchestratorTask.State.RUNNING:
			# RUNNING → QUEUED ist nicht erlaubt, daher über RETRYING.
			if not transition(task_id, OrchestratorTask.State.RETRYING):
				return false
			if not transition(task_id, OrchestratorTask.State.QUEUED):
				return false
		OrchestratorTask.State.ASSIGNED, OrchestratorTask.State.WAITING_FOR_DATA, \
		OrchestratorTask.State.RETRYING:
			if not transition(task_id, OrchestratorTask.State.QUEUED):
				return false
		OrchestratorTask.State.CREATED:
			if not enqueue(task_id):
				return false
		OrchestratorTask.State.FAILED:
			if not transition(task_id, OrchestratorTask.State.RETRYING):
				return false
			if not transition(task_id, OrchestratorTask.State.QUEUED):
				return false
	return assign(task_id, server_id)


# ---------------------------------------------------------------- Abfragen
func tasks_in_state(state: int) -> Array:
	var out: Array = []
	for task in tasks():
		if (task as OrchestratorTask).state == state:
			out.append(task)
	return out


## Wartende Tasks nach Priorität (HIGH zuerst), dann nach Erstellzeit.
func queued_by_priority() -> Array:
	var queued := tasks_in_state(OrchestratorTask.State.QUEUED)
	queued.sort_custom(func(a: OrchestratorTask, b: OrchestratorTask) -> bool:
		if a.priority != b.priority:
			return a.priority > b.priority
		return a.created_at_ms < b.created_at_ms)
	return queued


func counts() -> Dictionary:
	var result := {}
	for task in tasks():
		var key := (task as OrchestratorTask).state_text_now()
		result[key] = int(result.get(key, 0)) + 1
	return result


func describe_all() -> Array:
	var out: Array = []
	for task in tasks():
		out.append((task as OrchestratorTask).describe())
	return out


func reset() -> void:
	_tasks.clear()
	_order.clear()
