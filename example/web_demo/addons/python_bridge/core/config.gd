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
	var out: Dictionary = {
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
		# --- Web transport (Pyodide) ---------------------------------------------
		# Web-Exports nutzen automatisch den Pyodide-Transport; web_transport
		# erzwingt ihn optional auch auf Desktop (Tests). Auf Web ist der
		# Prozess-Transport technisch unmoeglich (kein OS.create_process).
		"web_transport": false,
		# Worker-Skript (addons/python_bridge/web/bridge_worker.js). Der
		# Build (tools/build_web_bundle.py) kopiert es neben den Export;
		# "bridge_worker.js" ist dann page-relativ erreichbar.
		"web_worker_url": "bridge_worker.js",
		# Lokal gebuendelte Pyodide-Runtime (bevorzugt, offline-faehig).
		"web_pyodide_dir": "",
		# CDN-Fallback, wenn kein lokales Bundle gesetzt ist.
		"web_cdn_url": "https://cdn.jsdelivr.net/pyodide/v0.26.4/full/",
		# Workspace-Bundle (tar, vom Build erzeugt) fuer das virtuelle
		# Dateisystem: python/, modules/, plugins/ usw.
		"web_bundle_url": "bridge_workspace.tar",
		# Pyodide-Pakete (Komma-Liste). Verbindliches Wissenschaftsprofil:
		# numpy, scipy, pandas werden vom Web-Transport geladen (Fehler, wenn
		# sie nicht verfügbar sind - keine stille Verschlechterung).
		"web_packages": "numpy,scipy,pandas",
		"web_tag": "web",
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
	# Web-Transport: der Pyodide-Worker laedt Runtime (CDN) + Wissenschafts-
	# pakete, BEVOR er ready meldet - beim Kaltstart 10-60 s und damit weit
	# ueber dem Desktop-WebSocket-Budget. 120 s decken den Kaltstart ab;
	# echte Worker-Fehler kommen zusaetzlich als Error-Event an.
	if OS.has_feature("web"):
		out["connect_timeout_ms"] = 120000
	return out

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
			# Projekt-Einstellungen speichern Komma-Listen als String (ein
			# editierbares Feld statt eines unhandlichen Arrays).
			if value is String:
				return split_list(value)
			return fallback
		"workspace_dir", "wrapper_dir":
			# Leerzeichen/leere Eingabe (z. B. geleertes Feld im
			# Einstellungs-Dialog) darf den Workspace nicht auf "" setzen -
			# sonst landeten Skripte in "/scripts" statt im Projekt.
			if value == null or str(value).strip_edges() == "":
				return fallback
			return str(value).strip_edges()
		"python_executable", "hot_reload_mode", "retry_policy", "web_worker_url", "web_pyodide_dir", "web_cdn_url", "web_bundle_url", "web_packages", "web_tag":
			return str(value) if value != null else fallback
		"autostart":
			return bool(value)
		_:
			# Numeric tunables arrive as ints; booleans stay booleans.
			if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
				return int(value)
			return value

# ------------------------------------------------------------------ Projekt-Einstellungen
## Praefix aller Einstellungen, die im Editor unter
## "Projekt > Projekteinstellungen" erscheinen (Abschnitt "Python Bridge").
const SETTINGS_SECTION := "python_bridge"

## Einzige Quelle der Wahrheit fuer die Einstellungs-Oberflaeche: Das Plugin
## registriert GENAU diese Eintraege, die Facade liest GENAU diese, und der
## Einstellungs-Dialog im Dock baut sich aus derselben Liste. Dadurch koennen
## UI, Registrierung und Lesepfad nie auseinanderlaufen.
##
## Rueckgabe: Array von
##   {path, key, type, default, hint (PropertyHint), hint_string, label}
static func project_setting_defs() -> Array:
	return [
		{
			"path": SETTINGS_SECTION + "/general/autostart", "key": "autostart",
			"type": TYPE_BOOL, "default": false, "hint": PROPERTY_HINT_NONE,
			"hint_string": "", "label": "Python beim Start des Editors/Spiels automatisch starten",
		},
		{
			"path": SETTINGS_SECTION + "/general/workspace_dir", "key": "workspace_dir",
			"type": TYPE_STRING, "default": DEFAULT_WORKSPACE_DIR,
			"hint": PROPERTY_HINT_DIR, "hint_string": "",
			"label": "Workspace-Ordner (scripts/, wrappers/, tmp/) – leer = Standard",
		},
		{
			"path": SETTINGS_SECTION + "/general/python_executable", "key": "python_executable",
			"type": TYPE_STRING, "default": "", "hint": PROPERTY_HINT_FILE,
			"hint_string": "*.exe,*.bat,python*,python3*",
			"label": "Python-Interpreter (leer = Bridge legt eigene venv an)",
		},
		{
			"path": SETTINGS_SECTION + "/general/dependencies", "key": "dependencies",
			"type": TYPE_STRING, "default": "", "hint": PROPERTY_HINT_NONE,
			"hint_string": "",
			"label": "Python-Pakete (Komma-getrennt, z. B. numpy,scipy>=1.10)",
		},
		{
			"path": SETTINGS_SECTION + "/general/hot_reload_mode", "key": "hot_reload_mode",
			"type": TYPE_STRING, "default": "reload_context",
			"hint": PROPERTY_HINT_ENUM,
			"hint_string": "none,reload_context,restart_instance",
			"label": "Hot-Reload-Verhalten",
		},
		{
			"path": SETTINGS_SECTION + "/general/auto_generate_wrappers",
			"key": "auto_generate_wrappers", "type": TYPE_BOOL, "default": false,
			"hint": PROPERTY_HINT_NONE, "hint_string": "",
			"label": "GDScript-Wrapper automatisch erzeugen",
		},
		{
			"path": SETTINGS_SECTION + "/web/packages", "key": "web_packages",
			"type": TYPE_STRING, "default": "numpy,scipy,pandas",
			"hint": PROPERTY_HINT_NONE, "hint_string": "",
			"label": "Web-Export: Pyodide-Pakete (Komma-getrennt)",
		},
	]

## Zerlegt eine Komma-/Semikolon-Liste ("numpy, scipy>=1.10") in Specs.
static func split_list(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for part in text.replace(";", ",").split(",", false):
		var spec := part.strip_edges()
		if spec != "":
			out.append(spec)
	return out

## Liest die registrierten Projekt-Einstellungen direkt aus ProjectSettings.
## Wird von der Facade beim Start benutzt; im Export stehen die Werte aus
## project.godot zur Verfuegung, im Editor zusaetzlich die Live-Aenderungen.
static func read_project_values() -> Dictionary:
	var out: Dictionary = {}
	for def in project_setting_defs():
		var path := str(def["path"])
		if ProjectSettings.has_setting(path):
			var value: Variant = ProjectSettings.get_setting(path)
			if value != null:
				out[str(def["key"])] = value
	return out

## Liest die Werte der Projekt-Einstellungen als Dictionary {key: value}.
## Nicht gesetzte Eintraege fehlen im Ergebnis (kein Ueberschreiben der
## Defaults mit Nullen). In Tests ohne ProjectSettings nutzbar, wenn
## `source` ein Dictionary ist.
static func project_values(source: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for def in project_setting_defs():
		var path := str(def["path"])
		if not source.has(path):
			continue
		var value: Variant = source[path]
		if value == null:
			continue
		out[str(def["key"])] = value
	return out

## Baut die effektive Konfiguration: defaults -> Projekt-Einstellungen ->
## config.json. Spaetere Quellen gewinnen. Ein explizites configure()
## ersetzt das Ergebnis vollstaendig (dokumentierte Praezedenz).
static func collect(project: Dictionary = {}, file_cfg: Dictionary = {}) -> Dictionary:
	var merged := defaults()
	# Projekt-Werte duerfen in beiden Formen kommen: {key: wert} (fertig
	# abgebildet) oder als roher ProjectSettings-Dump
	# {"python_bridge/general/autostart": wert}. Pfade werden abgebildet.
	var project_map: Dictionary = project
	for key in project:
		if str(key).contains("/"):
			project_map = project_values(project)
			break
	for source in [project_map, file_cfg]:
		if not (source is Dictionary):
			continue
		for key in source:
			if source[key] != null:
				merged[str(key)] = source[key]
	return normalize(merged)

## True when the given string is one of the supported hot reload modes.
static func is_valid_reload_mode(mode: String) -> bool:
	return mode in ["none", "reload_context", "restart_instance"]

## True when the given string is one of the supported retry policies.
static func is_valid_retry_policy(policy: String) -> bool:
	return policy in ["none", "connection_error", "process_error", "all"]