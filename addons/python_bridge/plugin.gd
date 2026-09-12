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
var _orchestrator_panel: Control = null
var _autoload_added_by_plugin: bool = false

func _enter_tree() -> void:
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

	# Optionaler visueller Task-Orchestrator (eigenstaendiges Untermodul,
	# rein additiv). Entscheidet nur, WO eine bestehende Python-Aufgabe
	# laeuft; die Python-Ausfuehrung bleibt unveraendert. Fehlt das Modul,
	# laeuft das Plugin unveraendert weiter.
	#
	# WICHTIG: Das Dock wird – wie das Python-Dock – DIREKT von diesem Plugin
	# registriert. `add_control_to_dock` funktioniert zuverlaessig nur aus einem
	# beim Editor registrierten Plugin heraus; ein per `script.new()` erzeugtes
	# Unter-Plugin ist nicht registriert und kann sein Dock stumm verlieren.
	var orchestrator_panel_path: String = get_script().resource_path.get_base_dir().path_join("orchestrator/editor/orchestrator_panel.gd")
	var orchestrator_panel_script := load(orchestrator_panel_path) as GDScript
	if orchestrator_panel_script:
		_orchestrator_panel = orchestrator_panel_script.new() as Control
		if _orchestrator_panel != null:
			_orchestrator_panel.name = "Task Orchestrator"
			add_control_to_dock(DockSlot.DOCK_SLOT_RIGHT_UL, _orchestrator_panel)
		else:
			push_warning("[PythonBridge] Orchestrator-Panel konnte nicht erzeugt werden.")
	else:
		push_warning("[PythonBridge] Orchestrator-Panel nicht gefunden: " + orchestrator_panel_path)

func _exit_tree() -> void:
	# Sauberer Shutdown aller Python-Instanzen, danach Dock + Autoload
	# entfernen.
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
	if _orchestrator_panel:
		remove_control_from_docks(_orchestrator_panel)
		_orchestrator_panel.queue_free()
		_orchestrator_panel = null
	# Only remove an autoload that this plugin created. A project-owned
	# autoload must survive addon reload/disable unchanged.
	if _autoload_added_by_plugin and ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		remove_autoload_singleton(AUTOLOAD_NAME)
		_autoload_added_by_plugin = false

# Treibt die Polling-Schleife zusaetzlich aus dem Editor, damit Instanzen
# auch dann zuverlaessig ticken, wenn der Autoload im Editor-Kontext nicht
# selbst _process bekommen wuerde. Der Hot-Reload-Watcher haengt hier mit an.
func _process(_delta: float) -> void:
	var pb := _get_bridge()
	if pb:
		pb.poll()
	if _panel:
		_panel.editor_poll()
	if _orchestrator_panel != null and _orchestrator_panel.has_method("editor_poll"):
		_orchestrator_panel.call("editor_poll")

func _get_bridge() -> Node:
	return get_node_or_null("/root/" + AUTOLOAD_NAME)