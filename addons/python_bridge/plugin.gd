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

func _enter_tree() -> void:
	# Nur registrieren, falls noch nicht vorhanden (Plugin kann sich
	# mehrfach ein-/ausschalten). Der Pfad wird ueber get_script()
	# abgeleitet, damit das Add-on in JEDEM Unterordner funktioniert.
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		var plugin_dir: String = get_script().resource_path.get_base_dir()
		add_autoload_singleton(AUTOLOAD_NAME, plugin_dir + "/core/python_bridge.gd")

	_panel = PythonBridgeEditorPanel.new(_get_bridge())
	# Der Node-Name ist zugleich der Dock-Tab-Titel im Editor.
	_panel.name = "Python Bridge"
	add_control_to_dock(DockSlot.DOCK_SLOT_RIGHT_UL, _panel)

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
	if ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		remove_autoload_singleton(AUTOLOAD_NAME)

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