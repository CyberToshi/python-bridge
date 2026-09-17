class_name PythonBridgeEditorPanel
extends VBoxContainer
## Dock panel for editing and running Python scripts from inside the Godot
## editor. Lightweight by design: it only provides editing + integration and
## talks exclusively to the PythonBridge facade (never to core internals).
##
## Features:
##   - script list (res://<workspace>/scripts/**, auto-refreshing)
##   - MULTI-FILE tabbed editor: each open script is a tab with its own
##     CodeEdit (undo history + Python syntax highlighting per file)
##   - dirty marker ("*") on modified tabs; closing a dirty tab asks first
##   - Save / Run (execute_script) / Generate wrapper / Hot reload act on
##     the ACTIVE tab
##   - status + log output
##   - hot reload watcher: when the active file changes on disk (external
##     editor) and is not dirty, its tab content is refreshed and
##     PythonBridge.hot_reload_script() is triggered per config
##
## Because Godot's built-in script editor only handles GDScript/C#, this
## dock is the place to write the project's Python files with highlighting.

const HOT_RELOAD_POLL_MS := 1000

var _bridge: Object = null
var _file_list: ItemList = null
var _tab_bar: TabBar = null
var _code_area: Control = null
var _status: Label = null
var _log: RichTextLabel = null
var _placeholder: CodeEdit = null
var _confirm_close: ConfirmationDialog = null
var _pending_close: String = ""     # script_id awaiting close confirmation

# Open tabs: parallel to TabBar indices, keyed by script_id.
var _open_order: Array = []         # [script_id, ...]
var _editors: Dictionary = {}       # script_id -> CodeEdit
var _dirty: Dictionary = {}         # script_id -> bool
var _mtimes: Dictionary = {}        # script_id -> int (modified time on disk)
var _last_poll_ms: int = 0
var _loading := false               # suppress text_changed while swapping text

func _init(bridge: Object = null) -> void:
	_bridge = bridge
	_build_ui()
	refresh_scripts()

## The autoload may be registered after the panel is created; resolve it
## lazily so the panel works regardless of construction order.
func _resolve_bridge() -> Object:
	if _bridge != null:
		return _bridge
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		_bridge = (main_loop as SceneTree).root.get_node_or_null("PythonBridge")
	return _bridge

# ------------------------------------------------------------------ UI
func _build_ui() -> void:
	# The Godot editor hot-reloads this script while the dock is open. The
	# existing panel instance survives such a reload, but freshly declared
	# members (like _tab_bar) are null on it - so never stack duplicate UI:
	# discard any previous children before rebuilding.
	for child in get_children():
		remove_child(child)
		child.queue_free()

	# Give the dock a usable starting size; the splitters below let the user
	# drag list/editor/log to any size afterwards.
	custom_minimum_size = Vector2(560, 380)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)

	var refresh_btn := Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.pressed.connect(refresh_scripts)
	header.add_child(refresh_btn)

	var new_btn := Button.new()
	new_btn.text = "New script"
	new_btn.pressed.connect(_on_new_script)
	header.add_child(new_btn)

	_status = Label.new()
	_status.text = "status: -"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_status)

	add_child(header)

	# Split: script list (left) | tabbed editor (right). HSplitContainer
	# makes the divider draggable, so the user can resize the list and the
	# editor freely.
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 8)
	add_child(split)

	_file_list = ItemList.new()
	_file_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_file_list.custom_minimum_size = Vector2(150, 120)
	_file_list.item_selected.connect(_on_script_selected)
	split.add_child(_file_list)

	# Editor (tabs + code) and log stacked vertically, also draggable.
	var v_split := VSplitContainer.new()
	v_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v_split.add_theme_constant_override("separation", 4)
	split.add_child(v_split)

	var editor_box := VBoxContainer.new()
	editor_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor_box.add_theme_constant_override("separation", 4)
	v_split.add_child(editor_box)

	_tab_bar = TabBar.new()
	_tab_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_bar.scrolling_enabled = true
	_tab_bar.select_with_rmb = false
	# Close buttons appear on tab hover (TabBar default close policy).
	_tab_bar.tab_changed.connect(_on_tab_changed)
	_tab_bar.tab_close_pressed.connect(_on_tab_close_pressed)
	editor_box.add_child(_tab_bar)

	_code_area = Control.new()
	_code_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code_area.custom_minimum_size = Vector2(280, 160)
	editor_box.add_child(_code_area)

	# Read-only placeholder so the editor area is never empty: it is shown
	# while no script tab is open and hidden once a file is opened.
	_placeholder = CodeEdit.new()
	_placeholder.editable = false
	_placeholder.text = "No script open.\n\nOpen a file from the list, or create one with \"New script\"."
	_placeholder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_apply_editor_style(_placeholder)
	_code_area.add_child(_placeholder)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(_on_save)
	actions.add_child(save_btn)

	var run_btn := Button.new()
	run_btn.text = "Run"
	run_btn.pressed.connect(_on_run)
	actions.add_child(run_btn)

	var wrapper_btn := Button.new()
	wrapper_btn.text = "Generate wrapper"
	wrapper_btn.pressed.connect(_on_generate_wrapper)
	actions.add_child(wrapper_btn)

	var reload_btn := Button.new()
	reload_btn.text = "Hot reload"
	reload_btn.pressed.connect(_on_hot_reload)
	actions.add_child(reload_btn)

	add_child(actions)

	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 90)
	_log.bbcode_enabled = true
	_log.scroll_following = true
	v_split.add_child(_log)
	# Give the editor the larger share initially; the user can drag it.
	v_split.split_offset = -150
	split.split_offset = 170

	_confirm_close = ConfirmationDialog.new()
	_confirm_close.dialog_text = "Unsaved changes will be lost. Close tab?"
	_confirm_close.ok_button_text = "Close and discard"
	_confirm_close.cancel_button_text = "Keep editing"
	_confirm_close.confirmed.connect(_on_close_confirmed)
	add_child(_confirm_close)

## Rebuilds the whole UI once when the script was hot-reloaded in the running
## editor (the instance survives such a reload, but its UI members are null).
## Safe to call on every frame: it is a no-op while the UI is intact.
func _ensure_ui() -> void:
	if _tab_bar != null and _file_list != null and _log != null:
		return
	_open_order.clear()
	_editors.clear()
	_dirty.clear()
	_mtimes.clear()
	_pending_close = ""
	_build_ui()
	refresh_scripts()

# ------------------------------------------------------------------ Scripts (list)
func refresh_scripts() -> void:
	_ensure_ui()
	_file_list.clear()
	_current_list_mtimes_clear()
	var scripts_dir := _scripts_dir()
	if scripts_dir == "":
		_set_status("no bridge yet")
		return
	var dir := DirAccess.open(scripts_dir)
	if dir == null:
		_set_status("no scripts dir: " + scripts_dir)
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.ends_with(".py"):
			_file_list.add_item(entry.get_basename())
		entry = dir.get_next()
	dir.list_dir_end()
	_set_status("scripts: %d  (open tabs: %d)" % [_file_list.item_count, _open_order.size()])
	_sync_list_selection()

## mtimes are tracked per OPEN tab only (see _tab_mtime helpers); this keeps
## the old helper name available for list refreshes without stale entries.
func _current_list_mtimes_clear() -> void:
	pass

func _scripts_dir() -> String:
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("workspace_dir"):
		return str(bridge.call("workspace_dir")) + "/scripts"
	return ""

# ------------------------------------------------------------------ Tabs
func _active_script_id() -> String:
	if _tab_bar == null:
		return ""
	if _tab_bar.current_tab < 0 or _tab_bar.current_tab >= _open_order.size():
		return ""
	return str(_open_order[_tab_bar.current_tab])

## Opens `script_id` in the editor: reuses an existing tab or creates a new
## one. Returns the id (or "" when the script cannot be read).
func open_script(script_id: String) -> String:
	_ensure_ui()
	if script_id == "":
		return ""
	# Already open? Just activate that tab.
	var existing := _open_order.find(script_id)
	if existing >= 0:
		_tab_bar.current_tab = existing
		_activate_current()
		return script_id
	# Read content through the facade (same source the runtime uses).
	var bridge := _resolve_bridge()
	var source := ""
	if bridge and bridge.has_method("get_script_source"):
		source = str(bridge.call("get_script_source", script_id))
	if source == "" and not _script_file_exists(script_id):
		_set_status("script not found: " + script_id)
		return ""
	# New editor instance -> own undo history + syntax highlighting.
	var editor := CodeEdit.new()
	editor.syntax_highlighter = PythonBridgeSyntaxHighlighter.new()
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.custom_minimum_size = Vector2(280, 160)
	editor.set_anchors_preset(Control.PRESET_FULL_RECT)
	_apply_editor_style(editor)
	_code_area.add_child(editor)
	if _placeholder:
		_placeholder.visible = false
	var captured := script_id
	editor.text_changed.connect(func() -> void: _on_text_changed_for(captured))
	_loading = true
	editor.text = source
	_loading = false

	_open_order.append(script_id)
	_editors[script_id] = editor
	_dirty[script_id] = false
	_mtimes[script_id] = _disk_mtime(script_id)
	_tab_bar.add_tab(_tab_label(script_id, false))
	_tab_bar.current_tab = _open_order.size() - 1
	_activate_current()
	_editor(script_id).grab_focus()
	return script_id

## Shared professional look for every CodeEdit in the dock: line numbers
## (zero-padded), a gutter, 4-space indentation and tab visualization.
## NOTE: Godot 4.4+ renamed the CodeEdit properties (line numbers became a
## configurable gutter system: `gutters_draw_line_numbers`). The engine
## verified for this addon is 4.7.x, but the `in`-checks keep the code
## working on older Godot 4.x too.
func _apply_editor_style(editor: CodeEdit) -> void:
	if "gutters_draw_line_numbers" in editor:
		editor.gutters_draw_line_numbers = true
		editor.gutters_zero_pad_line_numbers = true
	elif "draw_line_numbers" in editor:
		editor.draw_line_numbers = true
		editor.line_number_zero_padded = true
	if "indent_use_spaces" in editor:
		editor.indent_use_spaces = true
	elif "indent_using_spaces" in editor:
		editor.indent_using_spaces = true
	editor.indent_size = 4
	editor.draw_tabs = true
	editor.add_theme_color_override("line_number_color", Color(0.5, 0.5, 0.55))

func _activate_current() -> void:
	var id := _active_script_id()
	if id == "":
		# No open tab: show the read-only placeholder editor.
		for open_id in _open_order:
			_editor(open_id).visible = false
		if _placeholder:
			_placeholder.visible = true
		return
	if _placeholder:
		_placeholder.visible = false
	# Show only the active CodeEdit.
	for open_id in _open_order:
		var ed: CodeEdit = _editors[open_id]
		ed.visible = (open_id == id)
	# External change check: refresh content when the file changed on disk and
	# the tab is not dirty (avoids stale text after external edits).
	if not bool(_dirty.get(id, false)):
		var disk := _disk_mtime(id)
		if disk >= 0 and int(_mtimes.get(id, -1)) != disk:
			_mtimes[id] = disk
			var bridge := _resolve_bridge()
			if bridge and bridge.has_method("get_script_source"):
				_loading = true
				_editor(id).text = str(bridge.call("get_script_source", id))
				_loading = false
				_append_log("[color=#7fd9ff]reloaded from disk: %s[/color]" % id)
	_sync_list_selection()
	_set_status("open: %s" % id)

func _tab_label(script_id: String, dirty: bool) -> String:
	return ("* " if dirty else "") + script_id.get_file()

func _update_tab_label(script_id: String) -> void:
	var idx := _open_order.find(script_id)
	if idx < 0:
		return
	_tab_bar.set_tab_title(idx, _tab_label(script_id, bool(_dirty.get(script_id, false))))

func _disk_mtime(script_id: String) -> int:
	var path := _scripts_dir() + "/" + script_id + ".py"
	return FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else -1

func _script_file_exists(script_id: String) -> bool:
	var path := _scripts_dir() + "/" + script_id + ".py"
	return FileAccess.file_exists(path)

func _editor(script_id: String) -> CodeEdit:
	return _editors.get(script_id, null) as CodeEdit

func _sync_list_selection() -> void:
	if _file_list == null:
		return
	var id := _active_script_id()
	if id == "":
		return
	for i in _file_list.item_count:
		if _file_list.get_item_text(i) == id.get_file().get_basename() or _file_list.get_item_text(i) == id:
			_file_list.select(i)
			return

# ------------------------------------------------------------------ Tab events
func _on_tab_changed(index: int) -> void:
	if index < 0 or index >= _open_order.size():
		# No tabs left: nothing active.
		for open_id in _open_order:
			_editor(open_id).visible = false
		_sync_list_selection()
		return
	_activate_current()
	var ed := _editor(str(_open_order[index]))
	if ed:
		ed.grab_focus()

func _on_tab_close_pressed(index: int) -> void:
	if index < 0 or index >= _open_order.size():
		return
	var id := str(_open_order[index])
	if bool(_dirty.get(id, false)):
		_pending_close = id
		_confirm_close.popup_centered()
		return
	_remove_tab(id)

func _on_close_confirmed() -> void:
	if _pending_close != "":
		_remove_tab(_pending_close)
	_pending_close = ""

func _remove_tab(script_id: String) -> void:
	var idx := _open_order.find(script_id)
	if idx < 0:
		return
	_open_order.remove_at(idx)
	var ed: CodeEdit = _editors.get(script_id, null)
	if ed:
		_editors.erase(script_id)
		ed.queue_free()
	_dirty.erase(script_id)
	_mtimes.erase(script_id)
	_tab_bar.remove_tab(idx)
	if _pending_close == script_id:
		_pending_close = ""
	# Activate a sensible neighbour, then sync empty state if none left.
	if _open_order.is_empty():
		_activate_current()
		_set_status("no script open")
		return
	var target := mini(idx, _open_order.size() - 1)
	_tab_bar.current_tab = target
	_activate_current()
	_on_tab_changed(target)

func _on_script_selected(index: int) -> void:
	var name := _file_list.get_item_text(index)
	open_script(name)

func _on_text_changed_for(script_id: String) -> void:
	if _loading:
		return
	_dirty[script_id] = true
	_update_tab_label(script_id)
	_set_status("edited: " + script_id)

func _on_new_script() -> void:
	_ensure_ui()
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "script_id"
	var dlg := AcceptDialog.new()
	dlg.title = "New Python script"
	dlg.dialog_text = "Script id (without .py):"
	dlg.add_child(name_edit)
	add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		var id := name_edit.text.strip_edges()
		if id == "":
			return
		var bridge := _resolve_bridge()
		if bridge and bridge.has_method("create_script"):
			bridge.call("create_script", id, "# %s.py\n" % id)
		refresh_scripts()
		open_script(id))
	dlg.popup_centered()

# ------------------------------------------------------------------ Actions
func _on_save() -> void:
	_ensure_ui()
	var id := _active_script_id()
	if id == "":
		_set_status("no script open")
		return
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("create_script"):
		var res: PythonBridgeResult = await bridge.call("create_script", id, _editor(id).text)
		if res and res.is_ok():
			_dirty[id] = false
			_mtimes[id] = _disk_mtime(id)
			_update_tab_label(id)
			_set_status("saved: " + id)
		else:
			_log_error("save failed", res)

func _on_run() -> void:
	_ensure_ui()
	var id := _active_script_id()
	if id == "":
		_set_status("no script open")
		return
	_append_log("[b]run %s[/b]" % id)
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("execute_script"):
		var res: PythonBridgeResult = await bridge.call("execute_script", id, {}, "default", 30.0)
		if res:
			if res.is_ok():
				_append_log("[color=#7fd97f]ok: %s[/color]" % str(res.value))
				_set_status("run ok")
			else:
				_append_log("[color=#ff7f7f]error (%s): %s[/color]" % [res.status, res.error_message()])
				if res.error.has("traceback"):
					_append_log("[color=#ffaa7f]%s[/color]" % str(res.error["traceback"]))
				_set_status("run failed")

func _on_generate_wrapper() -> void:
	_ensure_ui()
	var id := _active_script_id()
	if id == "":
		_set_status("no script open")
		return
	_append_log("[b]generate wrapper %s[/b]" % id)
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("introspect_script"):
		var res: PythonBridgeResult = await bridge.call("introspect_script", id, "default")
		if res and res.is_ok():
			var schema: Array = res.value
			var generated := PythonBridgeWrapperGenerator.generate(schema, id)
			if not bool(generated.get("ok", false)):
				_log_error("wrapper generation failed", generated)
				return
			_write_wrapper(id, str(generated.get("code", "")))
		else:
			_log_error("introspect failed (instance ready?)", res)

func _write_wrapper(script_id: String, code: String) -> void:
	var dir := ""
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("workspace_dir"):
		dir = str(bridge.call("workspace_dir")) + "/wrappers"
	else:
		dir = "res://python_bridge/wrappers"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir + "/" + script_id.get_file().get_basename() + "_wrapper.gd"
	# Marker-safe overwrite: refuse to touch manual files.
	if FileAccess.file_exists(path) and not PythonBridgeWrapperGenerator.is_generated(path):
		_log_error("refusing to overwrite manual file", {"error": path})
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_log_error("cannot write wrapper", {"error": path})
		return
	f.store_string(code)
	f.close()
	_append_log("[color=#7fd97f]wrapper written: %s[/color]" % path)
	EditorInterface.get_resource_filesystem().scan()

func _on_hot_reload() -> void:
	_ensure_ui()
	var id := _active_script_id()
	if id == "":
		_set_status("no script open")
		return
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("hot_reload_script"):
		var res: PythonBridgeResult = await bridge.call("hot_reload_script", id)
		if res:
			_append_log("hot reload: %s" % JSON.stringify(res.meta if res.is_ok() else res.error))

# ------------------------------------------------------------------ Hot reload watcher
## Called by the plugin each editor frame while the panel exists.
func editor_poll() -> void:
	_ensure_ui()
	var id := _active_script_id()
	if id == "":
		return
	var now := Time.get_ticks_msec()
	if now - _last_poll_ms < HOT_RELOAD_POLL_MS:
		return
	_last_poll_ms = now
	var disk := _disk_mtime(id)
	if disk < 0:
		return
	if int(_mtimes.get(id, -1)) != disk:
		_mtimes[id] = disk
		if bool(_dirty.get(id, false)):
			# Keep the user's edits; still offer a hint in the log.
			_append_log("[color=#7fd9ff]file changed on disk (tab has unsaved edits): %s[/color]" % id)
			return
		var bridge := _resolve_bridge()
		if bridge and bridge.has_method("get_script_source"):
			_loading = true
			_editor(id).text = str(bridge.call("get_script_source", id))
			_loading = false
		_append_log("[color=#7fd9ff]file changed on disk: %s[/color]" % id)
		_on_hot_reload()

# ------------------------------------------------------------------ Log
func _set_status(text: String) -> void:
	if _status:
		_status.text = "status: " + text

func _append_log(text: String) -> void:
	if _log:
		_log.append_text(text + "\n")

func _log_error(prefix: String, res: Variant) -> void:
	var detail := ""
	if res is PythonBridgeResult:
		detail = "%s: %s" % [res.status, res.error_message()]
	elif res is Dictionary:
		detail = str(res.get("error", res))
	else:
		detail = str(res)
	_append_log("[color=#ff7f7f]%s: %s[/color]" % [prefix, detail])
	_set_status(prefix + " failed")
