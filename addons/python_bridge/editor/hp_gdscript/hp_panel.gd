class_name PythonBridgeHPPanel
extends VBoxContainer
## Dock panel for the optional GDScript -> C++ -> GDExtension high-performance
## path. It shells out to the bundled GDScript2All converter and scaffolds a
## GDExtension workspace the user can edit and build.
##
## Workflow:
##   1. Select GDScript file(s)/folder(s) (drag from FileSystem or pick).
##   2. Click "Convert".
##   3. Inspect generated C++ in the workspace (button opens folder).
##   4. Build (automatic by default; manual button available).
##
## Generated files are intentionally kept editable and outside the add-on dir.

var _core: PythonBridgeHPCore = null
var _status: Label = null
var _log: RichTextLabel = null
var _sel: ItemList = null
var _script_paths: PackedStringArray = []

func _init() -> void:
    _core = PythonBridgeHPCore.new()
    _build_ui()

## ----------------------------------------------------------------- UI

func _build_ui() -> void:
    # top bar
    var bar := HBoxContainer.new()
    bar.add_theme_constant_override("separation", 8)
    var refresh := Button.new()
    refresh.text = "Refresh list"
    refresh.pressed.connect(_refresh_list)
    bar.add_child(refresh)

    var pick := Button.new()
    pick.text = "Pick scripts..."
    pick.pressed.connect(_pick_scripts)
    bar.add_child(pick)

    var clear := Button.new()
    clear.text = "Clear"
    clear.pressed.connect(_clear_selection)
    bar.add_child(clear)

    var convert := Button.new()
    convert.text = "Convert"
    convert.pressed.connect(_convert)
    convert.add_theme_color_override("font_color", Color(0.0, 0.5, 0.0))
    bar.add_child(convert)

    _status = Label.new()
    _status.text = "status: idle"
    _status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    bar.add_child(_status)

    add_child(bar)

    # selection list
    var list_container := VBoxContainer.new()
    list_container.add_theme_constant_override("separation", 4)
    var lbl := Label.new()
    lbl.text = "Selected GDScript files/folders (drag from FileSystem dock or pick):"
    lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list_container.add_child(lbl)
    _sel = ItemList.new()
    _sel.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _sel.custom_minimum_size = Vector2(0, 90)
    list_container.add_child(_sel)
    add_child(list_container)

    # action row
    var act := HBoxContainer.new()
    act.add_theme_constant_override("separation", 8)
    var workspace := Button.new()
    workspace.text = "Open workspace folder"
    workspace.pressed.connect(_open_workspace)
    act.add_child(workspace)

    var build := Button.new()
    build.text = "Build extension"
    build.pressed.connect(_build)
    act.add_child(build)

    add_child(act)

    # log
    var log_wrap := ScrollContainer.new()
    log_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
    log_wrap.custom_minimum_size = Vector2(0, 140)
    _log = RichTextLabel.new()
    _log.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _log.custom_minimum_size = Vector2(0, 120)
    _log.bbcode_enabled = true
    _log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    log_wrap.add_child(_log)
    add_child(log_wrap)

    _refresh_list()

## ----------------------------------------------------------------- actions

func _refresh_list() -> void:
    _sel.clear()
    _script_paths = []
    _status.text = "status: " + str(_sel.get_item_count()) + " items"

func _clear_selection() -> void:
    _script_paths = []
    _sel.clear()
    _status.text = "status: cleared"
    _log.text = ""

func _pick_scripts() -> void:
    var f := FileDialog.new()
    f.access = FileDialog.ACCESS_RESOURCES
    f.file_mode = FileDialog.FILE_MODE_OPEN_FILE
    f.title = "Select a GDScript file"
    f.filters = ["*.gd"]
    f.file_selected.connect(_on_picked)
    f.canceled.connect(f.queue_free)
    f.file_selected.connect(f.queue_free)
    get_tree().root.add_child(f)
    f.popup_centered(Vector2i(700, 500))

func _on_picked(path: String) -> void:
    if path == "" or path == null:
        return
    var rel: String = ""
    if path.begins_with("res://"):
        rel = path
    else:
        rel = ProjectSettings.localize_path(path)
    if _script_paths.has(rel):
        return
    _script_paths.append(rel)
    _sel.clear()
    for rel2 in _script_paths:
        _sel.add_item(rel2.replace("res://", ""))
    _status.text = "status: " + str(_script_paths.size()) + " selected"

func _convert() -> void:
    if _script_paths.is_empty():
        _status.text = "status: nothing selected"
        return
    _log.text = "[color=cccccc]Running converter...[/color]\n"
    var err := _core.convert_and_scaffold(_script_paths)
    _append_log(_core.last_log())
    if err == OK:
        _status.text = "status: OK — see log / workspace"
    else:
        _status.text = "status: FAILED"
        _log.text += "[color=ff4444]Error:[/color] " + _core.last_error() + "\n"

func _build() -> void:
    _log.text += "[color=cccccc]Building...[/color]\n"
    var err := _core.build()
    _append_log(_core.last_log())
    if err == OK:
        _status.text = "status: build OK"
    else:
        _status.text = "status: build FAILED"
        _log.text += "[color=ff4444]Error:[/color] " + _core.last_error() + "\n"

func _open_workspace() -> void:
    _core.reveal_workspace()

func _append_log(lines: PackedStringArray) -> void:
    for line in lines:
        _log.text += line
