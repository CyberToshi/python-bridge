class_name PythonBridgeConfig
extends RefCounted
## Central configuration for the Python Bridge.
##
## All tunables, version floors and protocol constants live here instead of
## being hard-coded at usage sites. `configure()` on the facade merges a user
## dictionary over these defaults; `normalize()` coerces types so that
## downstream modules can rely on the shapes documented below.

const PROTOCOL_VERSION: int = 2
const MIN_GODOT_VERSION: String = "4.2"
const MIN_PYTHON_MAJOR: int = 3
const MIN_PYTHON_MINOR: int = 8

const DEFAULT_WORKSPACE_DIR: String = "res://python_bridge"
const DEFAULT_INSTANCE: String = "default"

## Default settings. Keys are stable identifiers used by all core modules.
##
## Implemented as a function (not a constant): the editor compiles autoload
## scripts with a stricter constant-expression check, and a constant whose
## literal contains e.g. PackedStringArray() or arithmetic would fail there.
## Building the dictionary at runtime is equally fast and avoids that trap.
static func defaults() -> Dictionary:
	return {
		# --- General -----------------------------------------------------------
		"autostart": false,
		"workspace_dir": DEFAULT_WORKSPACE_DIR,
		"python_executable": "",
		"dependencies": PackedStringArray(),
		# --- Task manager / backpressure ----------------------------------------
		"max_queued_tasks": 1000,
		# Anzahl gleichzeitig offener Units pro Instanz. Fuer Parallelitaet auf
		# mehreren Worker-Slots zusammen mit workers_per_instance erhoehen
		# (z. B. beide 4). Gleiche Contexts bleiben serialisiert (Scheduler).
		"max_inflight_per_instance": 1,
		# Worker-Threads pro Python-Prozess. Tasks verschiedener Contexts
		# koennen parallel laufen; gleiche Contexts strikt seriell. Reine
		# CPU-Python-Last skaliert wegen des GIL nur ueber mehrere Prozesse.
		"workers_per_instance": 1,
		# Watchdog: laeuft ein per Timeout abgebrochener Job nach dieser Frist
		# weiter (Thread nicht killbar), beendet sich der Prozess selbst und
		# wird ueber die Restart-Policy neu gestartet. 0 = deaktiviert.
		"runaway_grace_ms": 10000,
		"max_payload_bytes": 64 * 1024 * 1024,
		"task_timeout_ms": 30000,        # execution timeout (RUNNING)
		"queue_timeout_ms": 60000,       # max wait for a worker slot (QUEUED); 0 = unlimited
		"max_stdout_bytes": 1024 * 1024,
		"max_stderr_bytes": 1024 * 1024,
		"max_result_bytes": 256 * 1024 * 1024,
		"max_retries": 0,
		"retry_policy": "connection_error", # none | connection_error | process_error | all
		"retry_delay_ms": 250,
		# --- Batching -----------------------------------------------------------
		"max_batch_size": 32,
		"max_batch_delay_ms": 32,
		# --- Scheduler / frame sync ---------------------------------------------
		"max_dispatch_per_frame": 16,
		"max_results_per_frame": 64,
		"max_inbox_size": 512,
		"max_decode_bytes_per_frame": 16 * 1024 * 1024,  # Entpack-Budget pro Frame
		# --- Data plane / DataRef --------------------------------------------------
		# numpy-Ergebnisse >= dieser Schwelle werden als DataRef-Handle gehalten
		# (Materialisierung erst auf Anfrage); 0 = deaktiviert (direkter Transfer).
		"data_ref_threshold_bytes": 16 * 1024 * 1024,
		# Bytes einer file-backed DataRef pro Frame beim Materialisieren lesen
		# (Datei-Transport statt WebSocket; chunkweise, kein Main-Thread-Stall).
		"file_read_bytes_per_frame": 16 * 1024 * 1024,
		# --- Connection / provisioning -------------------------------------------
		"connect_timeout_ms": 20000,
		"provision_venv_timeout_ms": 120000,
		"provision_pip_timeout_ms": 300000,
		"shutdown_timeout_ms": 3000,
		# --- Health monitoring ---------------------------------------------------
		"health_check_interval_ms": 5000,
		"health_missed_pong_limit": 3,
		# --- Crash / restart -----------------------------------------------------
		"max_restart_attempts": 3,
		"restart_base_delay_ms": 500,
		"restart_backoff_factor": 2,
		"stable_uptime_ms": 30000,
		# --- Hot reload -----------------------------------------------------------
		"hot_reload_mode": "reload_context", # none | reload_context | restart_instance
		# --- Editor / wrapper generation ------------------------------------------
		"auto_generate_wrappers": false,
		"wrapper_dir": "res://python_bridge/wrappers",
	}

## Merges `cfg` over the defaults and coerces types. Unknown keys are kept
## (forward compatible) but not validated.
static func normalize(cfg: Dictionary) -> Dictionary:
	var out: Dictionary = defaults()
	for key in cfg:
		out[key] = _coerce(key, cfg[key], out.get(key, null))
	return out

static func _coerce(key: String, value: Variant, fallback: Variant) -> Variant:
	match key:
		"dependencies":
			if value is Array or value is PackedStringArray:
				return PackedStringArray(value)
			return fallback
		"workspace_dir", "python_executable", "wrapper_dir", "hot_reload_mode", "retry_policy":
			return str(value) if value != null else fallback
		"autostart":
			return bool(value)
		_:
			# Numeric tunables arrive as ints; booleans stay booleans.
			if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
				return int(value)
			return value

## True when the given string is one of the supported hot reload modes.
static func is_valid_reload_mode(mode: String) -> bool:
	return mode in ["none", "reload_context", "restart_instance"]

## True when the given string is one of the supported retry policies.
static func is_valid_retry_policy(policy: String) -> bool:
	return policy in ["none", "connection_error", "process_error", "all"]