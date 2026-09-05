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
var _task_seq: int = 0
var _context_seq: int = 0
var _shutting_down: bool = false

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

func _init_task_layer() -> void:
	_task_manager = PythonBridgeTaskManager.new(_settings)
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
	if _task_manager == null:
		return
	# Tunables werden zur Laufzeit vom TaskManager/Scheduler gelesen.
	_task_manager._cfg = _settings
	_scheduler._cfg = _settings

func workspace_dir() -> String:
	return str(_settings.get("workspace_dir", PythonBridgeConfig.DEFAULT_WORKSPACE_DIR))

func config() -> Dictionary:
	return _settings.duplicate(true)

# ------------------------------------------------------------------ Instanzen
func start_instance(instance_name := PythonBridgeConfig.DEFAULT_INSTANCE) -> PythonBridgeResult:
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
	for name in _instances.keys():
		var inst := _get_instance_by_name(name)
		if inst:
			inst.shutdown_now()
	_instances.clear()
	_shutting_down = false

func _on_instance_state(instance: String, state: String) -> void:
	instance_state_changed.emit(instance, state)

func _on_instance_message(instance: String, parsed: Dictionary) -> void:
	# Introspect-Antworten loesen die Facade direkt auf (kein Task-Durchlauf).
	var msg: Dictionary = parsed.get("msg", {})
	if str(msg.get("type", "")) == PythonProtocol.MSG_INTROSPECT_RESULT:
		var rid := str(msg.get("id", ""))
		if rid != "":
			_pending_introspect[rid] = {
				"ok": str(msg.get("status", "error")) == "ok",
				"functions": msg.get("functions", []),
				"error": msg.get("error", {}),
			}
		return
	# Task-Ergebnisse gehen in den Scheduler (Frame-Sync); Events ebenfalls.
	_scheduler.on_message(instance, parsed)

func _on_instance_lost(instance: String, error: Dictionary) -> void:
	# Crash: In-Flight-Tasks fehlschlagen lassen; Instanz restartet selbst
	# per Backoff-Policy.
	_scheduler.on_instance_lost(instance, error)

func _on_bridge_event(instance: String, event: Dictionary) -> void:
	bridge_event.emit(instance, event)

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
	s["workspace_fs"] = ProjectSettings.globalize_path(str(_settings.get("workspace_dir")))
	var script_path: String = get_script().resource_path
	if script_path != "":
		s["bridge_python_dir"] = script_path.get_base_dir() + "/../python"
	return s

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
			task_done.emit(task))
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
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Cannot open file for writing: " + path))
	file.store_string(code)
	file.close()
	return PythonBridgeResult.success({"path": path})

func get_script_source(script_id: String) -> String:
	var path := resolve_script_path(script_id)
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	var src := file.get_as_text()
	file.close()
	return src

func execute_script(script_id: String, input: Variant = {}, instance := PythonBridgeConfig.DEFAULT_INSTANCE, timeout_sec := 30.0) -> PythonBridgeResult:
	var src := get_script_source(script_id)
	if src == "":
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Script not found: " + script_id))
	var task := PythonBridgeTask.make_run(_next_task_id(), "script:" + script_id, src, input,
		int(timeout_sec * 1000.0))
	return await _submit_and_await(task, instance)

func call_script(script_id: String, function: String, args: Array = [], kwargs: Dictionary = {}, instance := PythonBridgeConfig.DEFAULT_INSTANCE, timeout_sec := 30.0) -> PythonBridgeResult:
	var src := get_script_source(script_id)
	if src == "":
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Script not found: " + script_id))
	var task := PythonBridgeTask.make_call(_next_task_id(), "script:" + script_id, src,
		function, args, kwargs, int(timeout_sec * 1000.0))
	return await _submit_and_await(task, instance)

func define_script(script_id: String, instance := PythonBridgeConfig.DEFAULT_INSTANCE, timeout_sec := 30.0) -> PythonBridgeResult:
	var src := get_script_source(script_id)
	if src == "":
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Script not found: " + script_id))
	var task := PythonBridgeTask.make_define(_next_task_id(), "script:" + script_id, src,
		int(timeout_sec * 1000.0))
	return await _submit_and_await(task, instance)

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
	return workspace_dir() + "/scripts/" + script_id + ".py"

# ------------------------------------------------------------------ Hot Reload
## Loest Hot Reload fuer ein Skript aus (konfigurierbarer Modus).
## Godot-State bleibt unangetastet. Liefert eine PythonBridgeResult-Meldung.
func hot_reload_script(script_id: String) -> PythonBridgeResult:
	var mode := str(_settings.get("hot_reload_mode", "reload_context"))
	if mode == "none":
		return PythonBridgeResult.success({"reloaded": false, "mode": "none"})
	var src := get_script_source(script_id)
	if src == "":
		return PythonBridgeResult.failed_with_error(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR,
			"Script not found: " + script_id))
	var context := "script:" + resolve_script_path(script_id)
	if mode == "restart_instance":
		for name in _instances.keys():
			var inst := _get_instance_by_name(name)
			if inst and inst.is_active():
				inst.stop()
				inst.start()
		return PythonBridgeResult.success({"reloaded": true, "mode": mode})
	# reload_context: Server invalidiert den Kontext-Hash; der naechste Call
	# re-definiert die Quelle (siehe Python executor.py).
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