@tool
extends EditorPlugin
## Einstiegspunkt des "Python Bridge"-Add-ons.
##
## Registriert die zentrale "PythonBridge"-Klasse als Autoload-Singleton
## (INSTANZ-Methoden, damit `await` funktioniert) und haengt das Python-
## Editor-Dock an. Das Dock ist bewusst leichtgewichtig: es spricht nur mit
## der Facade und enthaelt keinerlei Runtime-Logik.

const AUTOLOAD_NAME := "PythonBridge"

var _panel: PythonBridgeEditorPanel = null
var _hp_plugin: EditorPlugin = null
var _autoload_added_by_plugin: bool = false

func _enter_tree() -> void:
	# Projekt-Einstellungen zuerst: die Facade liest sie in _enter_tree.
	_register_settings()
	# Nur registrieren, falls noch nicht vorhanden (Plugin kann sich
	# mehrfach ein-/ausschalten). Der Pfad wird ueber get_script()
	# abgeleitet, damit das Add-on in JEDEM Unterordner funktioniert.
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		var plugin_dir: String = get_script().resource_path.get_base_dir()
		add_autoload_singleton(AUTOLOAD_NAME, plugin_dir + "/core/python_bridge.gd")
		_autoload_added_by_plugin = true

	_panel = PythonBridgeEditorPanel.new(_get_bridge())
	# Der Node-Name ist zugleich der Dock-Tab-Titel im Editor.
	_panel.name = "Python Bridge"
	add_control_to_dock(DockSlot.DOCK_SLOT_RIGHT_UL, _panel)
	_build_tool_menu()

	# Export-Plugin: .py/.txt/.json/.md automatisch in jeden Export packen.
	_ensure_export_plugin()

	# Optionaler Hochleistungspfad (GDScript -> C++ -> GDExtension).
	# Dieser Dock ist unabhaengig vom Python-Dock; er nutzt den bundled
	# GDScript2All-Transpiler und erzeugt eine GDExtension-Scaffold-Struktur.
	# Der Skript-Pfad wird aus get_script() abgeleitet (kein harter
	# res://addons/python_bridge/...-Preload), damit das Add-on auch dann
	# funktioniert, wenn es unter einem anderen Ordner installiert wurde.
	var hp_plugin_path: String = get_script().resource_path.get_base_dir().path_join("editor/hp_gdscript/plugin_hp.gd")
	var hp_plugin_script := load(hp_plugin_path) as GDScript
	if hp_plugin_script:
		_hp_plugin = hp_plugin_script.new()
		# Call the optional nested editor plugin through Callable so the
		# method dispatch remains explicit and compatible with Godot 4's
		# parser.
		Callable(_hp_plugin, "_enter_tree").call_deferred()

func _exit_tree() -> void:
	# Sauberer Shutdown aller Python-Instanzen, danach Dock + Autoload
	# entfernen.
	_remove_tool_menu()
	_remove_export_plugin()
	var pb := _get_bridge()
	if pb:
		pb.call("shutdown_now")
	if _panel:
		remove_control_from_docks(_panel)
		_panel.queue_free()
		_panel = null
	if _hp_plugin:
		Callable(_hp_plugin, "_exit_tree").call_deferred()
		_hp_plugin = null
	# Only remove an autoload that this plugin created. A project-owned
	# autoload must survive addon reload/disable unchanged.
	if _autoload_added_by_plugin and ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		remove_autoload_singleton(AUTOLOAD_NAME)
		_autoload_added_by_plugin = false

# ------------------------------------------------------------------ Projekt-Einstellungen
## Registriert die Einstellungen aus PythonBridgeConfig.project_setting_defs()
## unter "Projekt > Projekteinstellungen > Python Bridge". Das ist der MANUELLE
## Weg: Wer nichts anfasst, bekommt dieselben Defaults wie die Automatik
## (eigene venv, Workspace unter res://python_bridge).
func _register_settings() -> void:
	for def in PythonBridgeConfig.project_setting_defs():
		var path := str(def["path"])
		var default_value: Variant = def["default"]
		if not ProjectSettings.has_setting(path):
			ProjectSettings.set_setting(path, default_value)
		ProjectSettings.set_initial_value(path, default_value)
		ProjectSettings.add_property_info({
			"name": path,
			"type": int(def["type"]),
			"hint": int(def["hint"]),
			"hint_string": str(def["hint_string"]),
		})

# ------------------------------------------------------------------ Tool-Menue
## Einstiegspunkte unter "Projekt > Werkzeuge", damit die Funktionen nicht
## nur im Dock-Tab versteckt sind.
func _build_tool_menu() -> void:
	add_tool_menu_item("Python Bridge: Dock anzeigen", _show_dock)
	add_tool_menu_item("Python Bridge: Neue Datei …", _new_file)
	add_tool_menu_item("Python Bridge: Einstellungen …", _show_settings)
	add_tool_menu_item("Python Bridge: Instanz starten", _start_instance)
	add_tool_menu_item("Python Bridge: Instanz stoppen", _stop_instance)
	add_tool_menu_item("Python Bridge: Cython kompilieren", _compile_cython)

func _remove_tool_menu() -> void:
	for label in ["Python Bridge: Dock anzeigen", "Python Bridge: Neue Datei …",
			"Python Bridge: Einstellungen …", "Python Bridge: Instanz starten",
			"Python Bridge: Instanz stoppen", "Python Bridge: Cython kompilieren"]:
		remove_tool_menu_item(label)

## Best effort: das Dock liegt in einem Tab-Container des Editors. Wenn der
## Nutzer den Tab geschlossen/ausgeblendet hat, gibt es dafuer keine offizielle
## Editor-API - dann zeigen wir wenigstens den Tab und holen das Dock nach vorn.
func _show_dock() -> void:
	if _panel == null:
		return
	_panel.show()
	var parent := _panel.get_parent()
	if parent is TabContainer:
		(parent as TabContainer).current_tab = _panel.get_index()
	_panel.grab_focus()

func _new_file() -> void:
	if _panel == null:
		return
	_show_dock()
	_panel.call("open_new_file_dialog")

func _show_settings() -> void:
	if _panel == null:
		return
	_show_dock()
	_panel.call("open_settings")

func _start_instance() -> void:
	var pb := _get_bridge()
	if pb == null:
		push_warning("[PythonBridge] Autoload nicht gefunden - Plugin neu aktivieren.")
		return
	var res: Variant = await pb.call("start_instance", "default")
	if res is PythonBridgeResult:
		print("[PythonBridge] Instanz: ", (res as PythonBridgeResult).is_ok())

func _stop_instance() -> void:
	var pb := _get_bridge()
	if pb != null:
		pb.call("stop_instance", "default")

func _compile_cython() -> void:
	var pb := _get_bridge()
	if pb == null:
		return
	var res: Variant = await pb.call("compile_cython", "", false)
	if res is PythonBridgeResult:
		print("[PythonBridge] Cython: ", (res as PythonBridgeResult).value
			if (res as PythonBridgeResult).is_ok() else (res as PythonBridgeResult).error_message())

# Treibt die Polling-Schleife zusaetzlich aus dem Editor, damit Instanzen
# auch dann zuverlaessig ticken, wenn der Autoload im Editor-Kontext nicht
# selbst _process bekommen wuerde. Der Hot-Reload-Watcher haengt hier mit an.
func _process(_delta: float) -> void:
	var pb := _get_bridge()
	if pb:
		pb.poll()
	if _panel:
		_panel.editor_poll()

func _get_bridge() -> Node:
	return get_node_or_null("/root/" + AUTOLOAD_NAME)

# ------------------------------------------------------------------ Export
## Godot packt in Standard-Exports nur Ressourcen, KEINE .py/.txt-Dateien.
## Ohne Export-Plugin fehlen im Export (Desktop UND Web) die Bridge-
## Python-Runtime und alle Workspace-Skripte - die Bridge kann dort nicht
## starten. Der EditorExportPlugin (core/export_plugin.gd) ergaenzt die
## Dateien beim Export automatisch.
var _export_plugin: EditorExportPlugin = null

func _ensure_export_plugin() -> void:
	if _export_plugin != null:
		return
	var script := load(get_script().resource_path.get_base_dir() + "/core/export_plugin.gd") as GDScript
	if script:
		_export_plugin = script.new()
		add_export_plugin(_export_plugin)

func _remove_export_plugin() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null