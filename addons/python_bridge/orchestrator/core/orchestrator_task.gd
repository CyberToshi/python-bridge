class_name OrchestratorTask
extends RefCounted
## Eine zu orchestrierende Python-Aufgabe (Task Node, Phase 3).
##
## Reines Datenmodell – **kein** eigener Python-Interpreter. `python_task`
## referenziert eine bestehende Python-Aufgabe des Tools/Bridge (z. B. eine
## Skript-ID wie in `PythonBridge.call_script`). Der Zustandsautomat wird vom
## OrchestratorTaskManager geführt.

enum State { CREATED, QUEUED, ASSIGNED, WAITING_FOR_DATA, RUNNING, COMPLETED, FAILED, RETRYING, CANCELLED }
enum Priority { LOW, NORMAL, HIGH }

var task_id: String = ""
var python_task: String = ""               # Referenz auf die bestehende Python-Aufgabe
var priority: int = Priority.NORMAL
var required_files: Array = []             # logische file_ids (Phase 6/7)
var requirements: Dictionary = {}          # z. B. {"min_ram_pct": 20, "gpu": true}
var state: int = State.CREATED
var target: String = ""                    # gewünschter Server ("": egal)
var assigned_server: String = ""           # tatsächlich zugewiesener Server
var created_at_ms: int = 0
var updated_at_ms: int = 0
var attempts: int = 0
var max_retries: int = 2
var ack_received: bool = false             # Zielrechner hat Annahme bestätigt
var result: Variant = null
var error: String = ""
var meta: Dictionary = {}

# --- Live-Status waehrend der Ausfuehrung (Phase 12) ----------------------
## Fortschritt 0.0..1.0 und die zugehoerige Stufe ("env", "build", "run").
var progress: float = 0.0
var progress_stage: String = ""
var progress_text: String = ""
## Klartext-Hinweis des Workers, was zu tun ist (z. B. fehlendes Paket).
var error_hint: String = ""
## Build-/Umgebungsbericht des Workers (Cache-Treffer, Key, Notizen).
var build: Dictionary = {}


## Erzeugt einen neuen Task. Ohne `p_id` wird eine eindeutige ID generiert.
static func make(p_python_task: String, p_priority: int = Priority.NORMAL,
		p_required_files: Array = [], p_requirements: Dictionary = {},
		p_id: String = "") -> OrchestratorTask:
	var t := OrchestratorTask.new()
	t.task_id = p_id if p_id != "" else generate_id()
	t.python_task = p_python_task
	t.priority = p_priority
	t.required_files = p_required_files.duplicate()
	t.requirements = p_requirements.duplicate(true)
	t.created_at_ms = Time.get_ticks_msec()
	t.updated_at_ms = t.created_at_ms
	return t


## Eindeutige Task-ID (UUID-artig). Worker können bereits bekannte IDs
## erkennen, damit Netzwerk-Retries keine Doppelausführung auslösen.
static func generate_id() -> String:
	var a := randi() % 0xFFFF
	var b := randi() % 0xFFFF
	return "task-%d-%04x%04x" % [Time.get_ticks_usec(), a, b]


func is_terminal() -> bool:
	return state in [State.COMPLETED, State.FAILED, State.CANCELLED]


func is_active() -> bool:
	return not is_terminal()


# ---------------------------------------------------------------- Darstellung
static func state_text(s: int) -> String:
	match s:
		State.CREATED:
			return "CREATED"
		State.QUEUED:
			return "QUEUED"
		State.ASSIGNED:
			return "ASSIGNED"
		State.WAITING_FOR_DATA:
			return "WAITING_FOR_DATA"
		State.RUNNING:
			return "RUNNING"
		State.COMPLETED:
			return "COMPLETED"
		State.FAILED:
			return "FAILED"
		State.RETRYING:
			return "RETRYING"
		State.CANCELLED:
			return "CANCELLED"
	return "UNKNOWN"


static func priority_text(p: int) -> String:
	match p:
		Priority.LOW:
			return "LOW"
		Priority.HIGH:
			return "HIGH"
	return "NORMAL"


func state_text_now() -> String:
	return state_text(state)


func describe() -> Dictionary:
	return {
		"task_id": task_id,
		"python_task": python_task,
		"priority": priority_text(priority),
		"required_files": required_files.duplicate(),
		"requirements": requirements.duplicate(true),
		"state": state_text(state),
		"target": target,
		"assigned_server": assigned_server,
		"attempts": attempts,
		"max_retries": max_retries,
		"ack_received": ack_received,
		"error": error,
		"created_at_ms": created_at_ms,
		"updated_at_ms": updated_at_ms,
	}
