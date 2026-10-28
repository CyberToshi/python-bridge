extends Node
## Maximalbeispiel — alle Register, die die Bridge zieht.
##
## Gezeigt wird:
##   * die vollständige Konfiguration (dieselben Keys, die auch in den
##     Projekteinstellungen und in <workspace>/config.json stehen können),
##   * zwei parallele Python-Instanzen ("default" und "worker"),
##   * ein .py-Skript mit eigener Dependency-Deklaration (__bridge_deps__),
##   * ein .pyx-Modul inklusive Cython-Build,
##   * DataRefs für große numpy-Ergebnisse (Schwelle hier bewusst klein),
##   * Introspection der Funktionssignaturen,
##   * alle vier Signale der Facade.
##
## Bewusst NICHT gezeigt: die Wrapper-Generierung (Editor-Funktion
## "⋯ → GDScript-Wrapper generieren") und ein Web-Export — für beides ist die
## Doku-Seite "Erste Schritte" bzw. "Python im Browser" der bessere Ort.

const DEFAULT_INSTANCE := "default"
const WORKER_INSTANCE := "worker"
const EXAMPLE_SCRIPTS := "res://example/maximum/scripts"
const STATS_ID := "max_stats"
const CYTHON_ID := "max_fastmath"

var _failures := 0

func _ready() -> void:
	print("[maximum] Start")
	_configure_everything()
	_connect_signals()
	if not await _start_instances():
		return
	_sync_scripts()
	await _stats_on(DEFAULT_INSTANCE)
	await _stats_on(WORKER_INSTANCE)
	await _data_ref_demo()
	await _cython_demo()
	await _introspection()
	print("[maximum] Ende, Fehler: %d" % _failures)

# --------------------------------------------------------------- Konfiguration
## Alles, was man deklarieren kann. Die Werte sind bewusst nicht die Defaults,
## damit im Log sichtbar wird, dass sie greifen. Alternativ stehen genau diese
## Keys unter Projekt → Projekteinstellungen → Python Bridge oder in
## <workspace>/config.json; die Präzedenz ist Defaults → Projekt-Einstellungen
## → config.json → configure().
func _configure_everything() -> void:
	PythonBridge.configure({
		# --- Allgemein ---------------------------------------------------
		"autostart": false,                       # true = Instanz startet mit dem Autoload
		"workspace_dir": "res://python_bridge",   # im Export z. B. user://python_bridge
		"python_executable": "",                  # leer = automatische Suche
		"dependencies": ["numpy"],                # zusätzlich zu websockets
		# --- Tasks, Queue, Backpressure ----------------------------------
		"max_queued_tasks": 2000,
		"max_inflight_per_instance": 2,
		"workers_per_instance": 2,
		"task_timeout_ms": 60000,
		"queue_timeout_ms": 120000,
		"max_payload_bytes": 64 * 1024 * 1024,
		"max_result_bytes": 256 * 1024 * 1024,
		"max_stdout_bytes": 256 * 1024,
		"max_stderr_bytes": 256 * 1024,
		"runaway_grace_ms": 15000,
		# --- Retries ------------------------------------------------------
		"max_retries": 2,
		"retry_policy": "connection_error",       # none | connection_error | process_error | all
		"retry_delay_ms": 500,
		# --- Batching -----------------------------------------------------
		"max_batch_size": 16,
		"max_batch_delay_ms": 16,
		# --- Frame-Sync ---------------------------------------------------
		"max_dispatch_per_frame": 16,
		"max_results_per_frame": 64,
		"max_inbox_size": 1024,
		"max_decode_bytes_per_frame": 8 * 1024 * 1024,
		# --- Datenebene ---------------------------------------------------
		"data_ref_threshold_bytes": 4096,         # absichtlich klein: DataRef sichtbar
		"file_read_bytes_per_frame": 8 * 1024 * 1024,
		# --- Verbindung / Provisioning ------------------------------------
		"connect_timeout_ms": 30000,
		"provision_venv_timeout_ms": 120000,      # derzeit reserviert
		"provision_pip_timeout_ms": 300000,       # derzeit reserviert
		"shutdown_timeout_ms": 5000,
		# --- Health & Restart ---------------------------------------------
		"health_check_interval_ms": 5000,
		"health_missed_pong_limit": 3,
		"max_restart_attempts": 3,
		"restart_base_delay_ms": 500,
		"restart_backoff_factor": 2.0,
		"stable_uptime_ms": 30000,
		# --- Hot Reload ---------------------------------------------------
		"hot_reload_mode": "reload_context",      # none | reload_context | restart_instance
		# --- Editor / Wrapper (reserviert) --------------------------------
		"auto_generate_wrappers": false,          # reserviert, wirkt derzeit nicht
		"wrapper_dir": "res://python_bridge/wrappers",
		# --- Web-Transport (greift nur im Web-Export) ---------------------
		"web_transport": false,                   # true erzwingt Pyodide auch auf Desktop
		"web_worker_url": "bridge_worker.js",
		"web_pyodide_dir": "",                    # lokal gebündelte Runtime
		"web_cdn_url": "https://cdn.jsdelivr.net/pyodide/v0.26.4/full/",
		"web_bundle_url": "bridge_workspace.tar",
		"web_packages": "numpy,scipy,pandas",
		"web_tag": "web",
	})
	var cfg: Dictionary = PythonBridge.config()
	print("[maximum] %d Konfigurationsschlüssel aktiv" % cfg.size())

func _connect_signals() -> void:
	PythonBridge.instance_state_changed.connect(
		func(instance: String, state: String) -> void:
			print("[maximum] Instanz '%s' -> %s" % [instance, state])
	)
	PythonBridge.task_done.connect(
		func(task: PythonBridgeTask) -> void:
			print("[maximum] Task %s fertig (%s)" % [task.id, task.state_text()])
	)
	PythonBridge.bridge_event.connect(
		func(instance: String, event: Dictionary) -> void:
			print("[maximum] Event aus '%s': %s" % [instance, event])
	)
	PythonBridge.pulse.connect(func() -> void: pass)

# ------------------------------------------------------------------- Instanzen
func _start_instances() -> bool:
	for instance in [DEFAULT_INSTANCE, WORKER_INSTANCE]:
		var started: PythonBridgeResult = await PythonBridge.start_instance(instance)
		if started.is_error():
			_failures += 1
			push_error("[maximum] Start von '%s' fehlgeschlagen: %s"
				% [instance, started.error_message()])
			return false
		print("[maximum] Instanz '%s' bereit" % instance)
	return true

# --------------------------------------------------------------------- Skripte
## Die Beispieldateien liegen neben der Szene und werden in den Workspace
## kopiert — genau das macht auch das Dock beim Speichern.
func _sync_scripts() -> void:
	var stats_code := _read(EXAMPLE_SCRIPTS + "/app_stats.py")
	if stats_code != "":
		PythonBridge.create_script(STATS_ID, stats_code)
	var cython_code := _read(EXAMPLE_SCRIPTS + "/fastmath.pyx")
	if cython_code != "":
		PythonBridge.create_cython_script(CYTHON_ID, cython_code)

	var invalid := PythonBridge.validate_script_id("unerlaubt/../x")
	print("[maximum] validate_script_id: %s" % ("abgelehnt" if invalid != "" else "erlaubt"))
	var ids: Array = []
	for entry in PythonBridge.list_scripts():
		ids.append(entry.get("id", "?"))
	print("[maximum] Skripte im Workspace: %s" % ", ".join(ids))

func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		_failures += 1
		push_error("[maximum] Beispieldatei fehlt: " + path)
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_failures += 1
		return ""
	var text := file.get_as_text()
	file.close()
	return text

# -------------------------------------------------------------- Aufrufe (Call)
func _stats_on(instance: String) -> void:
	var values := [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0, 11.0, 13.0]
	var result: PythonBridgeResult = await PythonBridge.call_script(
		STATS_ID, "describe", [values], {"bins": 4}, instance, 60.0
	)
	if result.is_error():
		_failures += 1
		push_error("[maximum] describe auf '%s': %s" % [instance, result.error_message()])
		return
	var stats: Dictionary = result.value
	print("[maximum] '%s' describe: n=%s mean=%.2f std=%.2f"
		% [instance, stats.get("count"), stats.get("mean", 0.0), stats.get("std", 0.0)])

func _data_ref_demo() -> void:
	# 64x64 float64 = 32 KiB — über der hier gesetzten 4-KiB-Schwelle, also
	# kommt ein Handle statt der Daten. materialize_data holt die Bytes.
	var result: PythonBridgeResult = await PythonBridge.call_script(
		STATS_ID, "big_matrix", [64], {}, DEFAULT_INSTANCE, 60.0
	)
	if result.is_error():
		_failures += 1
		push_error("[maximum] big_matrix: " + result.error_message())
		return
	if result.value is PythonBridgeDataRef:
		var ref := result.value as PythonBridgeDataRef
		print("[maximum] DataRef: kind=%s dtype=%s shape=%s nbytes=%s"
			% [ref.kind, ref.dtype, ref.shape, ref.nbytes])
		var materialized: PythonBridgeResult = await PythonBridge.materialize_data(ref)
		if materialized.is_ok():
			print("[maximum] materialisiert: %s" % _payload_info(materialized.value))
		else:
			_failures += 1
			push_error("[maximum] materialize: " + materialized.error_message())
		PythonBridge.release_data(ref)
	else:
		print("[maximum] big_matrix kam direkt an (Schwelle nicht erreicht)")

func _cython_demo() -> void:
	var compiled: PythonBridgeResult = await PythonBridge.compile_cython()
	if compiled.is_error():
		# Kein Compiler? Kein Beinbruch — der Rest des Beispiels läuft weiter.
		print("[maximum] Cython nicht verfügbar: " + compiled.error_message())
		return
	var report: Dictionary = compiled.value
	print("[maximum] Cython: compiler=%s gebaut=%s übersprungen=%s"
		% [report.get("compiler"), report.get("built"), report.get("skipped")])
	if not report.get("ok", false):
		print("[maximum] Cython-Build ohne Erfolg: %s" % [report.get("errors")])
		return
	var result: PythonBridgeResult = await PythonBridge.call_script(
		CYTHON_ID, "dot", [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]], {}, DEFAULT_INSTANCE, 60.0
	)
	if result.is_ok():
		print("[maximum] Cython dot(...) = %s" % str(result.value))
	else:
		_failures += 1
		push_error("[maximum] Cython-Call: " + result.error_message())

func _introspection() -> void:
	var result: PythonBridgeResult = await PythonBridge.introspect_script(STATS_ID)
	if result.is_error():
		_failures += 1
		push_error("[maximum] Introspection: " + result.error_message())
		return
	var names: Array = []
	for entry in result.value:
		names.append(entry.get("name", "?"))
	print("[maximum] Funktionen in %s: %s" % [STATS_ID, ", ".join(names)])

## numpy-Arrays kommen je nach Form als flaches Packed*-Array oder als
## Array von Zeilen an — beides hier lesbar machen.
func _payload_info(data: Variant) -> String:
	if data is PackedFloat64Array:
		return "%d float64" % (data as PackedFloat64Array).size()
	if data is PackedFloat32Array:
		return "%d float32" % (data as PackedFloat32Array).size()
	if data is PackedByteArray:
		return "%d Bytes" % (data as PackedByteArray).size()
	if data is Array:
		var rows := data as Array
		if rows.size() > 0 and rows[0] is PackedFloat64Array:
			return "%d Zeilen x %d float64" % [rows.size(), (rows[0] as PackedFloat64Array).size()]
		return "%d Einträge" % rows.size()
	return "Typ %s" % type_string(typeof(data))

func _exit_tree() -> void:
	PythonBridge.shutdown()
