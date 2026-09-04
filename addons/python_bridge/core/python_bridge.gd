@tool
extends Node
## Zentrale, kombinierbare API-Facade.
##
## Diese Klasse wird vom Plug-in als AUTOLOAD-Singleton namens "PythonBridge"
## registriert. Dadurch sind alle Funktionen INSTANZ-Methoden und koennen
## `await` verwenden (ein `static`-Funktion darf in Godot 4 KEINE Koroutine
## sein -> das waere ein Parse-Fehler).
##
## Aufruf aus GDScript (das "PythonBridge" global verweist dann auf diese
## Instanz):
##     var inst := await PythonBridge.start_instance("default")
##     var r    := await PythonBridge.execute("result = 1 + 1")

signal pulse                              # wird jeden Frame emittiert (fuer wait_ready)
signal instance_state_changed(instance: String, state: String)

const PROTOCOL_VERSION := 1
const DEFAULT_INSTANCE := "default"

var _instances: Dictionary = {}           # name -> BridgeInstance
var _settings: Dictionary = {
	"autostart": false,
	"workspace_dir": "res://python_bridge",
	"python_executable": "",
	"dependencies": PackedStringArray(),
}

@warning_ignore("return_value_discarded")
func _enter_tree() -> void:
	if bool(_settings.get("autostart", false)):
		# Wir starten die Default-Instanz bewusst ohne await; der Manager weiss,
		# dass er sie asynchron hochzieht.
		start_instance(DEFAULT_INSTANCE)

func _exit_tree() -> void:
	shutdown()

func _process(_delta: float) -> void:
	# Zusaetzlich ruft das Plug-in selbst `poll()` auf (Editor-Robustheit).
	poll()

# Pollt alle Instanzen. Aufrufbar per Autoload-_process UND per EditorPlugin-
# _process (ueber das Plug-in), damit es auch im Editor zuverlaessig laeuft.
func poll() -> void:
	pulse.emit()
	for name in _instances.keys():
		var inst: BridgeInstance = _instances[name]
		inst.tick()

# Helfer, der die Instanz ueber den Autoload-Pfad statt ueber den globalen
# Namen findet - nuetzlich, wenn `PythonBridge` als globaler Bezeichner
# aufgeloest werden soll.
static func system() -> Node:
	var root: Node = Engine.get_main_loop().root if Engine.get_main_loop() else null
	return root.get_node_or_null("PythonBridge") if root else null

# ------------------------------------------------------------------ Konfiguration
func configure(cfg: Dictionary) -> void:
	for key in cfg:
		_settings[key] = cfg[key]
	if _settings["dependencies"] is Array:
		_settings["dependencies"] = PackedStringArray(_settings["dependencies"])

func workspace_dir() -> String:
	return str(_settings["workspace_dir"])

# Settings fuer eine neue Instanz, ergaenzt um:
#  - workspace_fs:      ECHTER Dateisystem-Pfad des Workspace (fuer OS.execute/
#                       Subprozesse; res://-Pfade versteht nur Godot selbst).
#  - bridge_python_dir: Add-on-interner Python-Ordner (layout-unabhaengig).
func _instance_settings() -> Dictionary:
	var s: Dictionary = _settings.duplicate()
	s["workspace_fs"] = ProjectSettings.globalize_path(str(_settings["workspace_dir"]))
	var script_path: String = get_script().resource_path
	if script_path != "":
		s["bridge_python_dir"] = script_path.get_base_dir() + "/../python"
	return s

# ------------------------------------------------------------------ Instanzen
func start_instance(instance_name := DEFAULT_INSTANCE) -> PythonBridgeResult:
	var inst := _get_instance(instance_name)
	if inst:
		if inst.is_ready_immediately():
			return PythonBridgeResult.success({"instance": instance_name})
		if await inst.wait_ready(180.0):
			return PythonBridgeResult.success({"instance": instance_name})
		return PythonBridgeResult.failed(inst.status_text(), inst.last_error_message())

	inst = BridgeInstance.new(self, instance_name, _instance_settings())
	inst.name = "Instance_" + instance_name
	inst.state_changed.connect(_on_instance_state)
	_instances[instance_name] = inst
	add_child(inst)
	inst.start()

	if await inst.wait_ready(180.0):
		return PythonBridgeResult.success({"instance": instance_name})
	return PythonBridgeResult.failed(inst.status_text(), inst.last_error_message())

func get_instance(instance_name := DEFAULT_INSTANCE) -> BridgeInstance:
	return _get_instance(instance_name)

func _get_instance(instance_name: String) -> BridgeInstance:
	return _instances.get(instance_name, null) as BridgeInstance

func instance_status(instance_name := DEFAULT_INSTANCE) -> String:
	var inst := _get_instance(instance_name)
	return inst.status_text() if inst else "none"

func stop_instance(instance_name := DEFAULT_INSTANCE) -> void:
	var inst := _get_instance(instance_name)
	if inst:
		inst.stop()
		_instances.erase(instance_name)
		inst.queue_free()

func stop_all() -> void:
	for name in _instances.keys():
		stop_instance(name)

func shutdown() -> void:
	stop_all()

func _on_instance_state(instance: String, state: String) -> void:
	instance_state_changed.emit(instance, state)

# ------------------------------------------------------------------ Temporaerer Code
func execute(code: String, input: Variant = {},
		instance := DEFAULT_INSTANCE, timeout_sec := 30.0) -> PythonBridgeResult:
	var inst := _get_instance(instance)
	if not inst:
		return PythonBridgeResult.failed("not_ready", "Unbekannte Instanz: " + instance)
	var ctx := "temp_%s_%d" % [instance, inst.next_context_id()]
	return await inst.run(ctx, code, input, "run", "", [], {}, timeout_sec)

# ------------------------------------------------------------------ Dauerhafte Skripte
func create_script(script_id: String, code: String, subfolder := "") -> PythonBridgeResult:
	var path := script_path_for(script_id, subfolder)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return PythonBridgeResult.failed("internal", "Kann Datei nicht oeffnen: " + path)
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

func execute_script(script_id: String, input: Variant = {},
		instance := DEFAULT_INSTANCE, timeout_sec := 30.0) -> PythonBridgeResult:
	var inst := _get_instance(instance)
	if not inst:
		return PythonBridgeResult.failed("not_ready", "Unbekannte Instanz: " + instance)
	var src := get_script_source(script_id)
	if src == "":
		return PythonBridgeResult.failed("internal", "Skript nicht gefunden: " + script_id)
	return await inst.run("script:" + script_id, src, input, "run", "", [], {}, timeout_sec)

func call_script(script_id: String, function: String, args: Array = [],
		kwargs: Dictionary = {}, instance := DEFAULT_INSTANCE,
		timeout_sec := 30.0) -> PythonBridgeResult:
	var inst := _get_instance(instance)
	if not inst:
		return PythonBridgeResult.failed("not_ready", "Unbekannte Instanz: " + instance)
	var src := get_script_source(script_id)
	if src == "":
		return PythonBridgeResult.failed("internal", "Skript nicht gefunden: " + script_id)
	return await inst.run("script:" + script_id, src, {}, "call", function, args, kwargs, timeout_sec)

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