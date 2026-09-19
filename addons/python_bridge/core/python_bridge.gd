@tool
extends Node
## Zentrale, kombinierbare API-Facade der Python Bridge.
##
## Diese Klasse wird vom Plug-in als AUTOLOAD-Singleton namens "PythonBridge"
## registriert. Dadurch sind alle Funktionen INSTANZ-Methoden und koennen
## `await` verwenden.
##
## Die Facade ist der einzige Einstiegspunkt: sie verwaltet Instanzen,
## reicht Tasks an den TaskManager/Scheduler weiter und verdrahtet die
## Frame-Synchronisation. Editor- und Wrapper-Komponenten nutzen ausschliess
## diese API und haengen nicht am Kern.
##
## Aufruf aus GDScript:
##     await PythonBridge.start_instance("default")
##     var r := await PythonBridge.call_script("mein_skript", "calculate", [2, 3])

signal pulse                              # jeden Frame (fuer wait_ready u. a.)
signal instance_state_changed(instance: String, state: String)
signal task_done(task: PythonBridgeTask)  # Observable: jeder terminale Task
signal bridge_event(instance: String, event: Dictionary) # Python -> Godot events

var _instances: Dictionary = {}           # name -> BridgeInstance
var _settings: Dictionary = {}            # initialized in _init (runtime, after class cache is ready)
var _task_manager: PythonBridgeTaskManager = null
var _scheduler: PythonBridgeScheduler = null
var _script_registry: PythonBridgeScriptRegistry = null
var _task_seq: int = 0
var _context_seq: int = 0
var _shutting_down: bool = false
var _dep_restart_done: Dictionary = {}   # context|hash -> true (Einmal-Schutz)
# Data-Plane (DataRef-Handles): laufende data_get/data_release-Anfragen und
# die je Instanz bekannten Handles (fuer stale-Markierung beim Lifecycle).
var _pending_data: Dictionary = {}
var _refs_by_instance: Dictionary = {}     # instance -> Array[PythonBridgeDataRef]
var _data_seq: int = 0
# Cython-Sonderpfad (Desktop-only): Manager + laufende Builds.
var _cython: BridgeCythonManager = null
var _cython_awaiters: Array = []  # [{"scripts_dir": String, "awaiter": Callable}]

func _init() -> void:
	# Runtime initialization: the global class cache is fully built by the
	# time an instance exists, so resolving PythonBridgeConfig here is safe
	# even when this script is compiled as an autoload during editor startup.
	if _settings.is_empty():
		_settings = PythonBridgeConfig.defaults()

func _enter_tree() -> void:
	_init_task_layer()
	if bool(_settings.get("autostart", false)):
		# Bewusst ohne await; die Instanz zieht asynchron hoch.
		start_instance(PythonBridgeConfig.DEFAULT_INSTANCE)

func _exit_tree() -> void:
	shutdown_now()

func _process(_delta: float) -> void:
	poll()
	_cython_tick()

func _init_task_layer() -> void:
	_script_registry = PythonBridgeScriptRegistry.new()
	_task_manager = PythonBridgeTaskManager.new(_settings)
	_task_manager.attach_registry(_script_registry)
	_scheduler = PythonBridgeScheduler.new(_settings)
	_scheduler.setup(
		_task_manager,
		Callable(self, "_get_ready_instances"),
		Callable(self, "_send_to_instance"),
		Callable(self, "_on_bridge_event"),
		Callable(self, "_get_instance_by_name"))

# Pollt alle Instanzen und treibt den Scheduler (Sync-Punkt). Aufrufbar per
# Autoload-_process UND per EditorPlugin-_process (Editor-Robustheit).
func poll() -> void:
	if _shutting_down:
		return
	pulse.emit()
	for name in _instances.keys():
		var inst: BridgeInstance = _instances[name]
		inst.tick()
	_scheduler.tick()

static func system() -> Node:
	var root: Node = Engine.get_main_loop().root if Engine.get_main_loop() else null
	return root.get_node_or_null("PythonBridge") if root else null

# ------------------------------------------------------------------ Konfiguration
func configure(cfg: Dictionary) -> void:
	_settings = PythonBridgeConfig.normalize(cfg)
	_apply_export_workspace_redirect()
	if _task_manager == null:
		return
	# Tunables werden zur Laufzeit vom TaskManager/Scheduler gelesen.
	_task_manager._cfg = _settings
	_scheduler._cfg = _settings

## Export-Lauf (Desktop/Web): res:// ist im PCK nicht schreibbar. Der
## workspace_dir wird einmalig auf user://python_bridge umgeleitet, damit
## ALLE Workspace-Zugriffe (create_script, hot reload, Dependency-Manager,
## Provisioner) konsistent im schreibbaren Nutzerbereich arbeiten. Im
## Editor bleibt res:// (echte Dateien). Die Inhalte werden in
## _instance_settings() beim ersten Instanz-Start aus dem PCK geseedet.
## Falls die Engine im Editor laeuft, res:// direkt beschreibbar ist und
## kein Export vorliegt, bleibt alles im Editor unverändert (res://).
## ACHTUNG: Der korrekte Export-Feature-Tag ist "template" - "export" ist
## im exportierten Spiel NIE gesetzt (Godot-Doku), deshalb pruefen wir
## "template". Im Export ist res:// ins PCK gepackt und NICHT schreibbar.
func _apply_export_workspace_redirect() -> void:
	if not OS.has_feature("template"):
		return
	var ws := str(_settings.get("workspace_dir", PythonBridgeConfig.DEFAULT_WORKSPACE_DIR))
	if ws.begins_with("user://"):
		return  # bereits umgeleitet (oder bewusst konfiguriert)
	_settings["_export_source_workspace"] = ws
	_settings["workspace_dir"] = "user://python_bridge"

func workspace_dir() -> String:
	return str(_settings.get("workspace_dir", PythonBridgeConfig.DEFAULT_WORKSPACE_DIR))

func config() -> Dictionary:
	return _settings.duplicate(true)

# ------------------------------------------------------------------ Instanzen
func start_instance(instance_name := PythonBridgeConfig.DEFAULT_INSTANCE) -> PythonBridgeResult:
	# Web: der Pyodide-Transport ist der einzige moegliche Python-Transport.
	# Auf Desktop bleibt alles beim gewohnten Prozess-Weg.
	var web_mode := OS.has_feature("web") or bool(_settings.get("web_transport", false))
	var inst := _get_instance_by_name(instance_name)
	# Beendete/fehlgeschlagene Instanz gleichen Namens entsorgen, bevor neu
	# gestartet wird (sonst wuerde wait_ready sofort false liefern).
	if inst and inst.status_text() in ["stopped", "error"]:
		_instances.erase(instance_name)
		inst.queue_free()
		inst = null
	if inst:
		if inst.is_ready_immediately():
			return PythonBridgeResult.success({"instance": instance_name})
		if await inst.wait_ready():
			return PythonBridgeResult.success({"instance": instance_name})
		return PythonBridgeResult.failed(inst.status_text(), inst.last_error_message())

	if web_mode:
		inst = BridgeWebInstance.new(self, instance_name, _instance_settings())
	else:
		inst = BridgeInstance.new(self, instance_name, _instance_settings())
	inst.name = "Instance_" + instance_name
	inst.state_changed.connect(_on_instance_state)
	inst.message_received.connect(_on_instance_message)
	inst.lost.connect(_on_instance_lost)
	_instances[instance_name] = inst
	add_child(inst)
	inst.start()

	if await inst.wait_ready():
		return PythonBridgeResult.success({"instance": instance_name})
	return PythonBridgeResult.failed(inst.status_text(), inst.last_error_message())

func get_instance(instance_name := PythonBridgeConfig.DEFAULT_INSTANCE) -> BridgeInstance:
	return _get_instance_by_name(instance_name)

func instance_status(instance_name := PythonBridgeConfig.DEFAULT_INSTANCE) -> String:
	var inst := _get_instance_by_name(instance_name)
	return inst.status_text() if inst else "none"

## Startet den Graceful-Shutdown einer Instanz (non-blocking; die Instanz
## beendet ihren Prozess selbst in tick()). Die Instanz bleibt registriert,
## bis der STOPPED-Zustand erreicht ist.
func stop_instance(instance_name := PythonBridgeConfig.DEFAULT_INSTANCE) -> void:
	var inst := _get_instance_by_name(instance_name)
	if inst == null:
		return
	# Queued + running tasks dieses Instanzziels sauber aufloesen.
	var err := PythonBridgeErrorHandler.make(
		PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR,
		"Instance stopped: " + instance_name, "", instance_name)
	_task_manager.fail_queued_for(instance_name, err)
	_task_manager.fail_in_flight(instance_name, err)
	inst.stop()

func stop_all() -> void:
	for name in _instances.keys():
		stop_instance(name)

## Blockiert neue Tasks und stoppt alle Instanzen (non-blocking; Ablauf im
## Scheduler/Instanz-tick). Aufruf ohne await feuert und vergisst.
func shutdown() -> void:
	_shutting_down = true
	stop_all()
	_shutting_down = false

## Sofortiger, erzwungener Stop aller Instanzen (keine Zombies). Fuer
## _exit_tree / Editor-Teilung gedacht.
func shutdown_now() -> void:
	_shutting_down = true
	_mark_all_refs_stale()
	for name in _instances.keys():
		var inst := _get_instance_by_name(name)
		if inst:
			inst.shutdown_now()
	_instances.clear()
	_shutting_down = false

func _on_instance_state(instance: String, state: String) -> void:
	# Sobald ein Python-Prozess endet, sind alle seine Context-Compile-Caches
	# weg: Registry-Bestaetigungen verwerfen, damit der naechste Call den
	# Source wieder mitschickt und den Context sauber neu aufbaut.
	if state in ["stopped", "crashed", "error", "restarting"]:
		_script_registry.reset_instance(instance)
		# Alle Daten-Handles dieser Instanz sind ungueltig: der Python-Prozess
		# kennt die gehaltenen Datensaetze nicht mehr.
		_mark_instance_refs_stale(instance)
	instance_state_changed.emit(instance, state)

func _on_instance_message(instance: String, parsed: Dictionary) -> void:
	# Introspect-/Data-Antworten loesen die Facade direkt auf (kein Task-
	# Durchlauf; sie sind Request/Response ueber _pending_*).
	var msg: Dictionary = parsed.get("msg", {})
	var mtype := str(msg.get("type", ""))
	if mtype == PythonProtocol.MSG_INTROSPECT_RESULT:
		var rid := str(msg.get("id", ""))
		if rid != "":
			_pending_introspect[rid] = {
				"ok": str(msg.get("status", "error")) == "ok",
				"functions": msg.get("functions", []),
				"error": msg.get("error", {}),
			}
		return
	if mtype == PythonProtocol.MSG_DATA_RESULT or mtype == PythonProtocol.MSG_DATA_ACK:
		var rid2 := str(msg.get("id", ""))
		if rid2 != "":
			_pending_data[rid2] = msg
		return
	# Task-Ergebnisse gehen in den Scheduler (Frame-Sync); Events ebenfalls.
	_scheduler.on_message(instance, parsed)

func _on_instance_lost(instance: String, error: Dictionary) -> void:
	# Crash: In-Flight-Tasks fehlschlagen lassen; Instanz restartet selbst
	# per Backoff-Policy. Registry-Bestaetigungen des Prozesses sind damit
	# ungueltig (der neue Prozess startet mit leeren Contexts).
	_script_registry.reset_instance(instance)
	_mark_instance_refs_stale(instance)
	_scheduler.on_instance_lost(instance, error)

func _on_bridge_event(instance: String, event: Dictionary) -> void:
	bridge_event.emit(instance, event)

# ------------------------------------------------------------ Data-Plane (Refs)
## Registriert DataRef-Handles aus einem Task-Ergebnis und ordnet sie der
## Instanz zu, die das Ergebnis geliefert hat (Auto-Tasks erfahren ihre
## konkrete Instanz erst beim Dispatch).
func _track_ref_value(v: Variant, instance_name: String) -> void:
	if v is PythonBridgeDataRef:
		var ref := v as PythonBridgeDataRef
		if ref.instance_name == "":
			ref.instance_name = instance_name
		if not _refs_by_instance.has(instance_name):
			_refs_by_instance[instance_name] = []
		var arr: Array = _refs_by_instance[instance_name]
		if not arr.has(ref):
			arr.append(ref)
	elif v is Array:
		for x in v:
			_track_ref_value(x, instance_name)
	elif v is Dictionary:
		for k in v:
			_track_ref_value(v[k], instance_name)

func _mark_instance_refs_stale(instance: String) -> void:
	var arr: Array = _refs_by_instance.get(instance, [])
	for ref in arr:
		(ref as PythonBridgeDataRef).mark_stale()
	_refs_by_instance.erase(instance)

func _mark_all_refs_stale() -> void:
	for instance in _refs_by_instance.keys():
		_mark_instance_refs_stale(instance)

func _get_ready_instances() -> Array:
	var ready: Array = []
	for name in _instances.keys():
		var inst: BridgeInstance = _instances[name]
		if inst.is_ready():
			ready.append(inst)
	return ready

func _get_instance_by_name(instance_name: String) -> BridgeInstance:
	return _instances.get(instance_name, null) as BridgeInstance

func _send_to_instance(instance: Object, msg: Dictionary) -> Error:
	if instance is BridgeInstance:
		return (instance as BridgeInstance).send_message(msg)
	return ERR_INVALID_PARAMETER

func _instance_settings() -> Dictionary:
	var s: Dictionary = _settings.duplicate(true)
	var ws_dir := str(_settings.get("workspace_dir", PythonBridgeConfig.DEFAULT_WORKSPACE_DIR))
	# Export-Lauf (Web/Desktop): res:// ist ins PCK gepackt und NICHT
	# schreibbar. Der GESAMTE Workspace (venv, scripts, config, tmp) zieht
	# in den schreibbaren Nutzerbereich (user://) und wird beim ersten
	# Start einmalig aus dem PCK befuellt (Skripte, Konfiguration -
	# vorhandene Dateien werden nie ueberschrieben). Im Editor bleibt
	# alles unter res:// (echte Dateien, Hot Reload etc.).
	var exported := OS.has_feature("template")
	if exported:
		ws_dir = "user://python_bridge"
		s["workspace_dir"] = ws_dir
	s["workspace_res"] = ws_dir
	# Export: globalize_path(user://...) liefert die reale Adresse im
	# Nutzerordner. Editor: globalize_path(res://...) die echte Adresse im
	# Projekt. Beides ist fuer OS-Prozesse (venv-python + run_server.py)
	# direkt nutzbar.
	s["workspace_fs"] = ProjectSettings.globalize_path(ws_dir)
	if exported:
		# Workspace-Inhalte aus dem PCK seeden (config, scripts, modules,
		# plugins, packages), damit Provisioner/Deps-Manager/Hot-Reload
		# konsistent auf user:// arbeiten. Quelle ist die ORIGINAL-
		# workspace_dir (res://python_bridge), nicht die umgeleitete.
		_seed_export_workspace(str(_settings.get("_export_source_workspace",
			"res://python_bridge")), s["workspace_fs"])
	var script_path: String = get_script().resource_path
	if script_path != "":
		# Provisioner filesystem operations require an absolute path. The
		# resource path is still useful for locating the add-on, but must be
		# globalized before the Python runtime is copied into the workspace.
		# AUSNAHME Export: dort gibt es fuer res:// keine reale Adresse
		# (Inhalt liegt im PCK). DirAccess/FileAccess lesen PCK-Inhalte
		# direkt, daher bleibt der res://-Pfad un-globalisiert und der
		# Provisioner kopiert die Bridge-Runtime daraus in den user://-
		# Workspace. Der RUNNER wird im Export real aus dem kopierten
		# Workspace gestartet (ein OS-Prozess kann nicht aus dem PCK lesen).
		var py_dir := script_path.get_base_dir() + "/../python"
		s["bridge_python_dir"] = py_dir if exported else ProjectSettings.globalize_path(py_dir)
	return s

## Kopiert im Export-Lauf die Workspace-Inhalte aus dem PCK (res://) in
## den schreibbaren user://-Workspace. Vorhandene Dateien werden NICHT
## ueberschrieben (Nutzer-Aenderungen bleiben erhalten); Unterordner
## werden rekursiv uebernommen.
func _seed_export_workspace(from_res: String, to_fs: String) -> void:
	for sub in ["config", "scripts", "modules", "plugins", "packages"]:
		_seed_dir(from_res + "/" + sub, to_fs + "/" + sub)

func _seed_dir(src_res: String, dst_fs: String) -> void:
	var dir := DirAccess.open(src_res)
	if dir == null:
		return  # Ordner nicht im PCK (leeres Projekt) - ok
	DirAccess.make_dir_recursive_absolute(dst_fs)
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var src_full := src_res + "/" + entry
			var dst_full := dst_fs + "/" + entry
			if dir.current_is_dir():
				_seed_dir(src_full, dst_full)
			else:
				if not FileAccess.file_exists(dst_full):
					var src_f := FileAccess.open(src_full, FileAccess.READ)
					if src_f:
						var dst_f := FileAccess.open(dst_full, FileAccess.WRITE)
						if dst_f:
							dst_f.store_buffer(src_f.get_buffer(src_f.get_length()))
							dst_f.close()
						src_f.close()
		entry = dir.get_next()
	dir.list_dir_end()

# ------------------------------------------------------------------ Task-API
## Erzeugt und submitted einen Task. Liefert sofort ein PythonBridgeResult:
## ok, wenn der Task angenommen wurde (Backpressure-Check), sonst Fehler.
## Das Endergebnis kommt ueber `task.done` (await) bzw. `task.result`.
func submit_task(task: PythonBridgeTask) -> PythonBridgeResult:
	if _shutting_down:
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Bridge is shutting down"))
	if task.id == "":
		task.id = _next_task_id()
	var now := Time.get_ticks_msec()
	var res := _task_manager.submit(task, now)
	if res.is_ok():
		task.done.connect(func(r: PythonBridgeResult) -> void:
			task_done.emit(task)
			# DataRef-Handles im Ergebnis registrieren (Auto-Tasks kennen ihre
			# Instanz erst nach dem Dispatch; r.instance_id ist dann gesetzt).
			if task.result != null and task.result.value != null and task.instance_id != "":
				_track_ref_value(task.result.value, task.instance_id))
	return res

func cancel_task(task_id: String) -> bool:
	return _task_manager.cancel(task_id)

func get_task(task_id: String) -> PythonBridgeTask:
	return _task_manager.get_task(task_id)

func _next_task_id() -> String:
	_task_seq += 1
	return "task-%d" % _task_seq

func _next_context_id() -> String:
	_context_seq += 1
	return "temp-%d" % _context_seq

# ------------------------------------------------------------------ Temporaerer Code
func execute(code: String, input: Variant = {}, instance := PythonBridgeConfig.DEFAULT_INSTANCE, timeout_sec := 30.0) -> PythonBridgeResult:
	var ctx := _next_context_id()
	var task := PythonBridgeTask.make_run(_next_task_id(), ctx, code, input,
		int(timeout_sec * 1000.0))
	task.batchable = false
	return await _submit_and_await(task, instance)

# ------------------------------------------------------------------ Dauerhafte Skripte
func create_script(script_id: String, code: String, subfolder := "") -> PythonBridgeResult:
	var path := script_path_for(script_id, subfolder)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Cannot open file for writing: " + path))
	file.store_string(code)
	file.close()
	# Registry-Cache verwerfen, damit der naechste Lesezugriff den neuen
	# Inhalt sieht (mtime-Granularitaet ist sonst nicht zuverlaessig).
	_script_registry.forget(path)
	return PythonBridgeResult.success({"path": path})

## Speichert Code als .pyx (Cython) im Skript-Ordner. Wie create_script,
## aber mit .pyx-Endung - der Build wird separat per compile_cython()
## angestossen (Hash-basiert inkrementell, veraenderte Dateien erkennen
## die Build-Tools selbst).
func create_cython_script(script_id: String, code: String) -> PythonBridgeResult:
	var dir := workspace_dir() + "/scripts"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir + "/" + script_id + ".pyx"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Cannot open file for writing: " + path))
	file.store_string(code)
	file.close()
	return PythonBridgeResult.success({"path": path, "cython": true})

## Startet den inkrementellen Cython-Build (Desktop-only). Rueckgabe via
## await; Report-Format siehe cython_build.py (ok/built/skipped/errors/
## compiler/duration_s). Im Web-Pfad liefert die Methode einen klaren
## Fehler statt still zu scheitern.
func compile_cython(scripts_dir := "", force := false) -> PythonBridgeResult:
	if OS.has_feature("web"):
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
		"Cython-Build wird im Web-Export nicht unterstuetzt (Pyodide hat keinen C-Compiler)."))
	var dir := scripts_dir
	if dir == "":
		dir = workspace_dir() + "/scripts"
	if _cython == null:
		_cython = BridgeCythonManager.new()
		_cython.finished.connect(_on_cython_finished)
	var report := _cython.start_build(dir, PackedStringArray(), force)
	if report.get("pending", false) or _cython.is_busy():
		# Der fertige Report trifft per _process/Tick ein. Auch wenn bereits
		# EIN Build laeuft: hier warten statt "laeuft bereits"-Fehler -
		# parallele Caller (z. B. call_script-Autobuild neben Start-Build)
		# bekommen denselben Report. Achtung: await auf ein Signal MIT genau
		# einem Argument liefert das Argument DIREKT (kein Array) - beide
		# Formen akzeptieren (versionsunabhaengig).
		var frame: Variant = await _cython.finished
		var done: Dictionary = {}
		if frame is Dictionary:
			done = frame
		elif frame is Array and not (frame as Array).is_empty():
			done = (frame as Array)[0] as Dictionary
		return _cython_result(done)
	return _cython_result(report)

## Verwirft den Registry-Cache-Eintrag eines Pfads (nach Rename .py <-> .pyx,
## damit der naechste Lesezugriff frisch liest).
func forget_script_cache(path: String) -> void:
	_script_registry.forget(path)

## Rohes Cython ist nicht exec-bar: run/define-Stil ist fuer .pyx bewusst
## gesperrt (mit klarer Meldung statt kryptischem SyntaxError). Cython-
## Module sind Call-Ziele - die Funktionen werden importiert.
func _cython_run_style_guard(script_id: String) -> String:
	if resolve_script_path(script_id).ends_with(".pyx") and not OS.has_feature("web"):
		return "execute_script/define_script unterstuetzen keine .pyx-Module " \
			+ "(rohes Cython ist nicht ausfuehrbar). Funktionen per " \
			+ "call_script aufrufen - das kompilierte Modul wird importiert."
	return ""

func get_script_source(script_id: String) -> String:
	var entry := _script_entry(script_id)
	return str(entry.get("source", ""))

## Liest Skript ueber die Registry (mtime/size-Cache). Liefert
## {source, hash, mtime, size} oder {} wenn nicht vorhanden.
func _script_entry(script_id: String) -> Dictionary:
	var path := resolve_script_path(script_id)
	if not FileAccess.file_exists(path):
		_script_registry.forget(path)
		return {}
	return _script_registry.entry_for(path)

func execute_script(script_id: String, input: Variant = {}, instance := PythonBridgeConfig.DEFAULT_INSTANCE, timeout_sec := 30.0) -> PythonBridgeResult:
	var pyx_err := _cython_run_style_guard(script_id)
	if pyx_err != "":
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR, pyx_err))
	var entry := _script_entry(script_id)
	if entry.is_empty():
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Script not found: " + script_id))
	var task := PythonBridgeTask.make_run(_next_task_id(), _script_context(script_id), entry.source, input,
		int(timeout_sec * 1000.0))
	task.source_hash = entry.hash
	return await _submit_and_await(task, instance)

func call_script(script_id: String, function: String, args: Array = [], kwargs: Dictionary = {}, instance := PythonBridgeConfig.DEFAULT_INSTANCE, timeout_sec := 30.0) -> PythonBridgeResult:
	var entry := _script_entry(script_id)
	if entry.is_empty():
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Script not found: " + script_id))
	# Auto-Restart: deklariert ein (neues) Skript Pakete, die in der venv
	# noch fehlen, wird die Instanz EINMAL neu gestartet (der Provisioner
	# installiert sie beim Start). Pro Skript-Version nur ein Versuch -
	# ein NameError durch einen Tippfehler loest keine Restart-Schleife aus.
	var result := await _call_script_inner(script_id, function, args, kwargs, instance, timeout_sec, entry)
	if result.is_ok() or not _needs_dependency_restart(result):
		return result
	var restart_key := _script_context(script_id) + "|" + str(entry.hash)
	if _dep_restart_done.has(restart_key):
		return result  # schon einmal probiert - Fehler ehrlich durchreichen
	_dep_restart_done[restart_key] = true
	# Deklarationen persistent machen (dependencies.txt) und Instanz neu
	# starten - der Provisioner installiert die fehlenden Pakete, danach
	# wird der Call genau einmal wiederholt.
	register_dependencies(PythonBridgeDependencyManager.deps_from_source(entry.source))
	var inst_name := instance if instance != "" else PythonBridgeConfig.DEFAULT_INSTANCE
	var inst := _get_instance_by_name(inst_name)
	if inst == null:
		return result
	inst.shutdown_now()
	var restarted := await start_instance(inst_name)
	if restarted.is_error():
		return restarted
	return await _call_script_inner(script_id, function, args, kwargs, instance, timeout_sec, entry)

## True, wenn der Fehler einen fehlenden, per __bridge_deps__ deklarierten
## Paket-Spec betrifft (Executor-Gate: DEPENDENCY_ERROR vor der Ausfuehrung).
## Genau dieser Fall ist per Neustart + Provisionierung behebbar; reine
## Tippfehler im Nutzercode (NameError ohne Deklaration) bleiben unberuehrt.
func _needs_dependency_restart(result: PythonBridgeResult) -> bool:
	return str(result.error.get("code", "")) == "DEPENDENCY_ERROR"

func _call_script_inner(script_id: String, function: String, args: Array, kwargs: Dictionary, instance: String, timeout_sec: float, entry: Dictionary) -> PythonBridgeResult:
	# Cython-Sonderpfad (Desktop): Vor dem ersten Call nach .pyd/.so-Seiten
	# schauen; fehlt die Seite, einmal den Build anstossen. Der Build-Manager
	# laeuft ueber die venv - der Server bleibt unangetastet.
	var entry_path := resolve_script_path(script_id)
	if entry_path.ends_with(".pyx") and not OS.has_feature("web"):
		var stem := entry_path.get_file().get_basename()
		if not _cython_output_present(stem):
			var build_res: PythonBridgeResult = await compile_cython("", false)
			if build_res.is_error():
				return build_res
		return await _submit_and_await(PythonBridgeTask.make_call(_next_task_id(),
			"cython:" + entry_path, "", function, args, kwargs,
			int(timeout_sec * 1000.0)), instance)
	var task := PythonBridgeTask.make_call(_next_task_id(), _script_context(script_id), entry.source,
		function, args, kwargs, int(timeout_sec * 1000.0))
	task.source_hash = entry.hash
	return await _submit_and_await(task, instance)

## True, wenn fuer stem bereits eine kompilierte Seite (.so/.pyd) liegt.
func _cython_output_present(stem: String) -> bool:
	var dir := DirAccess.open(workspace_dir() + "/scripts")
	if dir == null:
		return false
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.begins_with(stem + ".") and (fname.ends_with(".so") or fname.ends_with(".pyd")):
			return true
		fname = dir.get_next()
	return false

func define_script(script_id: String, instance := PythonBridgeConfig.DEFAULT_INSTANCE, timeout_sec := 30.0) -> PythonBridgeResult:
	var pyx_err := _cython_run_style_guard(script_id)
	if pyx_err != "":
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR, pyx_err))
	var entry := _script_entry(script_id)
	if entry.is_empty():
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Script not found: " + script_id))
	var task := PythonBridgeTask.make_define(_next_task_id(), _script_context(script_id), entry.source,
		int(timeout_sec * 1000.0))
	task.source_hash = entry.hash
	return await _submit_and_await(task, instance)

## Kanonischer Context-Name eines persistenten Skripts. Wird von calls,
## execute, define UND hot reload identisch verwendet, damit der Python-
## Server genau den Context invalidiert, den die Calls nutzen.
func _script_context(script_id: String) -> String:
	if _script_entry_raw(script_id).get("is_cython", false):
		return "cython:" + resolve_script_path(script_id)
	return "script:" + resolve_script_path(script_id)

## Registry-Rohzugriff ohne Kontext-Ableitung (fuer _script_context).
func _script_entry_raw(script_id: String) -> Dictionary:
	var path := resolve_script_path(script_id)
	if not FileAccess.file_exists(path):
		_script_registry.forget(path)
		return {}
	return _script_registry.entry_for(path)

## Deklariert Abhaengigkeiten aus GDScript (statt/als Ergaenzung zu
## __bridge_deps__ im Python-Code und dependencies.txt). Muss VOR
## start_instance() aufgerufen werden - die Pakete landen im naechsten
## Provisionierungs-Lauf der venv.
##
##     PythonBridge.register_dependencies(["numpy", "pandas>=2.0"])
##     await PythonBridge.start_instance()
func register_dependencies(deps: PackedStringArray) -> PythonBridgeResult:
	var ws_fs := ProjectSettings.globalize_path(str(_settings.get("workspace_dir",
		PythonBridgeConfig.DEFAULT_WORKSPACE_DIR)))
	var cfg_dir := ws_fs + "/config"
	DirAccess.make_dir_recursive_absolute(cfg_dir)
	var path := cfg_dir + "/dependencies.txt"
	var existing := {}
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			for line in f.get_as_text().split("\n"):
				var s := line.strip_edges()
				if s != "" and not s.begins_with("#"):
					existing[s] = true
			f.close()
	var added := PackedStringArray()
	for dep in deps:
		var d := str(dep).strip_edges()
		if d != "" and not existing.has(d):
			existing[d] = true
			added.append(d)
	if added.is_empty():
		return PythonBridgeResult.success({"added": [], "file": path})
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Cannot write dependencies file: " + path))
	for d in existing.keys():
		out.store_line(str(d))
	out.close()
	return PythonBridgeResult.success({"added": Array(added), "file": path})

func _submit_and_await(task: PythonBridgeTask, instance: String) -> PythonBridgeResult:
	var res := _submit_task_with_instance(task, instance)
	if res.is_error():
		return res
	return await task.done

## Submit mit optionalem Instanzziel: leeres "" = Auto-Zuordnung durch den
## Scheduler; ein unbekannter Instanzname schlaegt sofort fehl (not_ready).
func _submit_task_with_instance(task: PythonBridgeTask, instance: String) -> PythonBridgeResult:
	if instance != "":
		var inst := _get_instance_by_name(instance)
		if inst == null:
			return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
				PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
				"Unknown instance: " + instance, task.id))
		task.instance_id = instance
	return submit_task(task)

# ------------------------------------------------------------------ Pfad-Umrechnung
func script_path_for(script_id: String, subfolder: String) -> String:
	var base := workspace_dir() + "/scripts"
	if subfolder != "":
		base += "/" + subfolder
	return base + "/" + script_id + ".py"

## Erlaubt volle Pfade ODER "id" bzw. "unterordner/id" innerhalb von scripts/.
func resolve_script_path(script_id: String) -> String:
	if script_id.begins_with("/") or script_id.contains("://"):
		return script_id
	# .pyx (Cython) hat Vorrang vor .py - der Editor-Toggle speichert so.
	var pyx := workspace_dir() + "/scripts/" + script_id + ".pyx"
	if FileAccess.file_exists(pyx):
		return pyx
	return workspace_dir() + "/scripts/" + script_id + ".py"

# ------------------------------------------------------------------ Cython
func _on_cython_finished(report: Dictionary) -> void:
	# Report nur zwischenspeichern; await-Aufloesung geschieht im Frame,
	# der das Signal empfaengt (await _cython.finished gibt das Argument-Array).
	pass

func _cython_result(report: Dictionary) -> PythonBridgeResult:
	if bool(report.get("ok", false)):
		return PythonBridgeResult.success(report)
	var msg := str(report.get("error", ""))
	if msg == "" and not report.get("errors", []).is_empty():
		var first: Dictionary = report["errors"][0]
		msg = "%s: %s" % [first.get("file", "?"), first.get("message", "")]
	if msg == "":
		msg = "Cython-Build fehlgeschlagen (ohne Details)."
	return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
		PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR, msg))

func _cython_tick() -> void:
	if _cython != null:
		_cython.tick()

# ------------------------------------------------------------------ Hot Reload
## Loest Hot Reload fuer ein Skript aus (konfigurierbarer Modus).
## Godot-State bleibt unangetastet. Liefert eine PythonBridgeResult-Meldung.
func hot_reload_script(script_id: String) -> PythonBridgeResult:
	var mode := str(_settings.get("hot_reload_mode", "reload_context"))
	if mode == "none":
		return PythonBridgeResult.success({"reloaded": false, "mode": "none"})
	# Immer frisch von der Platte lesen (nicht aus dem mtime-Cache), damit
	# der Reload garantiert den aktuellsten Stand definiert.
	var entry := _script_registry.refresh(resolve_script_path(script_id))
	if entry.is_empty():
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Script not found: " + script_id))
	var src: String = entry.source
	var context := _script_context(script_id)
	if mode == "restart_instance":
		for name in _instances.keys():
			var inst := _get_instance_by_name(name)
			if inst and inst.is_active():
				inst.stop()
				inst.start()
		# Prozess-Neustart: Registry-Bestaetigungen werden ueber die
		# State-Transition (stopped) bereits verworfen.
		return PythonBridgeResult.success({"reloaded": true, "mode": mode})
	# reload_context: Server invalidiert den Kontext-Hash und definiert die
	# neue Quelle sofort. Da der Server-Hash danach NICHT mehr dem entspricht,
	# den Godot bestaetigt hat, werden die Bestaetigungen hier verworfen:
	# der naechste Call traegt den Source wieder (genau eine Neudefinition).
	var msg := {
		"v": PythonProtocol.PROTOCOL_VERSION,
		"type": PythonProtocol.MSG_RELOAD,
		"id": "reload-" + script_id,
		"context": context,
		"source": src,
	}
	var sent := false
	for name in _instances.keys():
		var inst := _get_instance_by_name(name)
		if inst and inst.is_ready():
			if inst.send_message(msg) == OK:
				sent = true
	_script_registry.reset_context_all(context)
	return PythonBridgeResult.success({"reloaded": sent, "mode": mode})

# ------------------------------------------------------------------ Introspection
## Fragt die Funktionen-Signaturen eines Skripts vom Python-Server ab
## (AST-basiert, ohne das Skript auszufuehren). Ergebnis: Array von
## {name, params, returns, docstring} - Basis fuer den Wrapper-Generator.
func introspect_script(script_id: String, instance := PythonBridgeConfig.DEFAULT_INSTANCE) -> PythonBridgeResult:
	var inst := _get_instance_by_name(instance)
	if inst == null or not inst.is_ready():
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Instance not ready: " + instance))
	var src := get_script_source(script_id)
	if src == "":
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Script not found: " + script_id))
	return await _introspect_request(inst, src)

func _introspect_request(inst: BridgeInstance, src: String) -> PythonBridgeResult:
	# Direkte Anfrage ueber die Instanz (kein TaskManager-Durchlauf), da
	# Introspection synchron ein Ergebnis erwartet und nicht gebatcht werden
	# soll. Rueckkanal: message_received -> MSG_INTROSPECT_RESULT.
	var rid := "introspect-%d" % _context_seq
	_context_seq += 1
	var msg := {
		"v": PythonProtocol.PROTOCOL_VERSION,
		"type": PythonProtocol.MSG_INTROSPECT,
		"id": rid,
		"source": src,
	}
	var err := inst.send_message(msg)
	if err != OK:
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR,
			"Introspect send failed: %s" % err))
	# Auf die Antwort warten (main-thread, non-blocking via process_frame).
	var timeout_ms := int(_settings.get("task_timeout_ms", 30000))
	var waited := 0.0
	while waited < timeout_ms / 1000.0:
		await get_tree().process_frame
		waited += 0.016
		if _pending_introspect.has(rid) and _pending_introspect[rid] != null:
			var pending: Dictionary = _pending_introspect[rid]
			_pending_introspect.erase(rid)
			return _introspect_result_to_result(pending)
	_pending_introspect.erase(rid)
	return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
		PythonBridgeErrorHandler.CATEGORY_TIMEOUT_ERROR, "Introspect timeout"))

func _introspect_result_to_result(pending: Dictionary) -> PythonBridgeResult:
	if bool(pending.get("ok", false)):
		return PythonBridgeResult.success(pending.get("functions", []))
	return PythonBridgeResult.failed_with_error(pending.get("error", {}))

var _pending_introspect: Dictionary = {}

# ------------------------------------------------------------------ Data-Plane API
## Materialisiert einen DataRef-Handle: holt die Daten vom Python-Prozess
## (normale, binär-chunked Uebertragung) und liefert sie als gewoehnlichen
## Wert (typisierte Arrays fuer numpy, PackedByteArray fuer Bytes, ...).
## Handles koennen mehrfach materialisiert werden; ein stale/Released-Handle
## liefert einen strukturierten Fehler statt eines Absturzes.
func materialize_data(ref: PythonBridgeDataRef, timeout_sec := 60.0) -> PythonBridgeResult:
	var pre := _ref_precheck(ref)
	if pre.is_error():
		return pre
	var inst := _get_instance_by_name(ref.instance_name)
	if inst == null or not inst.is_ready():
		return _ref_stale_result(ref, "Instance '%s' is not ready" % ref.instance_name)
	var rid := _next_data_rid("get")
	var msg := {
		"v": PythonProtocol.PROTOCOL_VERSION,
		"type": PythonProtocol.MSG_DATA_GET,
		"id": rid,
		"ref_id": ref.data_id,
		"want": "file", # Phase 4: Datei-Transport bevorzugen (transparenter Fallback)
	}
	var pending := await _data_request_wait(inst, msg, timeout_sec)
	if str(pending.get("status", "error")) == "ok":
		var data: Variant = pending.get("data", null)
		# Datei-Modus: statt der Rohdaten kam ein Datei-Descriptor - die Daten
		# werden chunkweise per FileAccess gelesen (kein WebSocket-Transfer).
		if data is Dictionary and str((data as Dictionary).get("transport", "")) == "file":
			return await _materialize_file(data as Dictionary)
		return PythonBridgeResult.success(data)
	var err: Dictionary = pending.get("error", {})
	err = PythonBridgeErrorHandler.normalize(err, ref.data_id, ref.instance_name)
	return PythonBridgeResult.failed_with_error(err, ref.data_id, ref.instance_name)

## Liest eine file-backed DataRef chunkweise (Frame-Budget) und dekodiert sie
## in den Zieltyp. Fehler (fehlende/korrupte Datei, Pruefsumme) werden
## strukturiert gemeldet.
func _materialize_file(desc: Dictionary) -> PythonBridgeResult:
	var budget := int(_settings.get("file_read_bytes_per_frame", 16 * 1024 * 1024))
	var res := await PythonBridgeDataFile.read_chunked(
		str(desc.get("path", "")),
		budget,
		int(desc.get("nbytes", 0)),
		str(desc.get("sha256", "")))
	if not bool(res.get("ok", false)):
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_SERIALIZATION_ERROR,
			str(res.get("error", "File materialization failed"))))
	var value: Variant = PythonBridgeDataFile.decode_bytes(
		res.get("data", PackedByteArray()),
		str(desc.get("dtype", "float64")),
		desc.get("shape", []))
	return PythonBridgeResult.success(value)

## Gibt die vom Handle referenzierten Daten im Python-Prozess frei (Speicher).
## Der Handle wird als stale markiert; weitere materialize_data-Aufrufe
## schlagen strukturiert fehl. Nach Instanz-Ende/Crash sind Handles ohnehin
## stale - release_data ist dann ein No-Op (Erfolg, released=false).
func release_data(ref: PythonBridgeDataRef, timeout_sec := 10.0) -> PythonBridgeResult:
	if ref == null:
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR, "DataRef is null"))
	var inst := _get_instance_by_name(ref.instance_name) if ref.instance_name != "" else null
	var released := false
	if inst != null and inst.is_ready() and not ref.is_stale():
		var rid := _next_data_rid("rel")
		var msg := {
			"v": PythonProtocol.PROTOCOL_VERSION,
			"type": PythonProtocol.MSG_DATA_RELEASE,
			"id": rid,
			"ref_id": ref.data_id,
		}
		var pending := await _data_request_wait(inst, msg, timeout_sec)
		released = bool(pending.get("freed", false))
	ref.mark_stale()
	if ref.instance_name != "" and _refs_by_instance.has(ref.instance_name):
		(_refs_by_instance[ref.instance_name] as Array).erase(ref)
	return PythonBridgeResult.success({"released": released, "ref_id": ref.data_id})

## Strukturierte Beschreibung eines Handles ohne Roundtrip.
func describe_data(ref: PythonBridgeDataRef) -> PythonBridgeResult:
	if ref == null:
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR, "DataRef is null"))
	return PythonBridgeResult.success(ref.describe())

func _ref_precheck(ref: PythonBridgeDataRef) -> PythonBridgeResult:
	if ref == null:
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR, "DataRef is null"))
	if ref.is_stale():
		return _ref_stale_result(ref, "Data handle '%s' is stale (instance ended or released)" % ref.data_id)
	if ref.data_id == "" or ref.instance_name == "":
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Data handle has no id/instance association"))
	return PythonBridgeResult.success({})

func _ref_stale_result(ref: PythonBridgeDataRef, message: String) -> PythonBridgeResult:
	return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
		PythonBridgeErrorHandler.CATEGORY_TASK_ERROR, message, ref.data_id))

func _next_data_rid(kind: String) -> String:
	_data_seq += 1
	return "data-%s-%d" % [kind, _data_seq]

## Request/Response-Helfer (main-thread, non-blocking): sendet `msg` an die
## Instanz und wartet per process_frame auf die passende _pending_data-
## Antwort (MSG_DATA_RESULT / MSG_DATA_ACK).
func _data_request_wait(inst: BridgeInstance, msg: Dictionary, timeout_sec: float) -> Dictionary:
	var rid := str(msg.get("id", ""))
	if inst.send_message(msg) != OK:
		return {"status": "error", "error": PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR,
			"Data request send failed (connection closed?)")}
	var timeout_ms := int(timeout_sec * 1000.0)
	var waited := 0.0
	while waited < float(timeout_ms) / 1000.0:
		await get_tree().process_frame
		waited += 0.016
		if _pending_data.has(rid) and _pending_data[rid] != null:
			var pending: Dictionary = _pending_data[rid]
			_pending_data.erase(rid)
			return pending
	_pending_data.erase(rid)
	return {"status": "error", "error": PythonBridgeErrorHandler.make(
		PythonBridgeErrorHandler.CATEGORY_TIMEOUT_ERROR,
		"Data request timeout after %d ms" % timeout_ms)}
