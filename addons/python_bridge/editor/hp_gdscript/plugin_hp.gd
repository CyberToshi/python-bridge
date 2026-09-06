@tool
class_name PythonBridgeHPEditorPlugin
extends EditorPlugin
## Editor plugin for the optional GDScript2All high-performance path dock.

const PANEL_CLASS := "PythonBridgeHPPanel"
const PANEL_SCRIPT := "res://addons/python_bridge/editor/hp_gdscript/hp_panel.gd"

var _panel: Control = null

func _enter_tree() -> void:
    var panel_script := load(PANEL_SCRIPT)
    _panel = panel_script.new()
    _panel.name = "HP GDScript"
    add_control_to_dock(DockSlot.DOCK_SLOT_RIGHT_UL, _panel)

func _exit_tree() -> void:
    if _panel != null:
        remove_control_from_docks(_panel)
        _panel.queue_free()
        _panel = null
