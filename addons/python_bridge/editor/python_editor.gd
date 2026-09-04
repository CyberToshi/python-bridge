class_name PythonBridgeEditorPanel
extends VBoxContainer
## Dock panel for editing and running Python scripts from inside the Godot
## editor. Lightweight by design: it only provides editing + integration and
## talks exclusively to the PythonBridge facade (never to core internals).
##
## Features:
##   - script list (res://<workspace>/scripts/**, auto-refreshing)
##   - CodeEdit with Python syntax highlighting
##   - Save / Run (execute_script) / Generate wrapper / Hot reload
##   - status + log output
##   - hot reload watcher: when the open file changes on disk (external
##     editor), PythonBridge.hot_reload_script() is triggered per config

const HOT_RELOAD_POLL_MS := 1000

var _bridge: Object = null
var _file_list: ItemList = null
var _editor: CodeEdit = null
var _status: Label = null
var _log: RichTextLabel = null
var _mtimes: Dictionary = {}
var _last_poll_ms: int = 0
var _current_script_id: String = ""

func _init(bridge: Object = null) -> void:
	_bridge = bridge
	_build_ui()
	refresh_scripts()

## The autoload may be registered after the panel is created; resolve it
## lazily so the panel works regardless of construction order.
func _resolve_bridge() -> Object:
	if _bridge != null:
		return _bridge
	var root := Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root:
		_bridge = root.get_node_or_null("PythonBridge")
	return _bridge

# ------------------------------------------------------------------ UI
func _build_ui() -> void:
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

	_file_list = ItemList.new()
	_file_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_file_list.custom_minimum_size = Vector2(0, 120)
	_file_list.item_selected.connect(_on_script_selected)
	add_child(_file_list)

	_editor = CodeEdit.new()
	_editor.syntax_highlighter = PythonBridgeSyntaxHighlighter.new()
	_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_editor.custom_minimum_size = Vector2(0, 200)
	_editor.text_changed.connect(_on_text_changed)
	add_child(_editor)

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
	_log.custom_minimum_size = Vector2(0, 100)
	_log.bbcode_enabled = true
	_log.scroll_following = true
	add_child(_log)

# ------------------------------------------------------------------ Scripts
func refresh_scripts() -> void:
	_file_list.clear()
	_mtimes.clear()
	_current_script_id = ""
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
			var path := scripts_dir + "/" + entry
			_mtimes[entry.get_basename()] = FileAccess.get_modified_time(path)
		entry = dir.get_next()
	dir.list_dir_end()
	_set_status("scripts: %d" % _file_list.item_count)

func _scripts_dir() -> String:
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("workspace_dir"):
		return str(bridge.call("workspace_dir")) + "/scripts"
	return ""

func _on_script_selected(index: int) -> void:
	_on_save_if_dirty()
	var name: String = _file_list.get_item_text(index)
	_open_script(name)

func _open_script(script_id: String) -> void:
	_current_script_id = script_id
	var src := ""
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("get_script_source"):
		src = str(bridge.call("get_script_source", script_id))
	_editor.text = src
	_set_status("open: " + script_id)

func _on_new_script() -> void:
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
		refresh_scripts())
	dlg.popup_centered()

func _on_text_changed() -> void:
	# Mark dirty; saving happens on button or script switch.
	_set_status("edited: " + _current_script_id)

func _on_save_if_dirty() -> void:
	pass # save is explicit; switching scripts without saving is acceptable

func _on_save() -> void:
	if _current_script_id == "":
		_set_status("no script open")
		return
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("create_script"):
		var res: PythonBridgeResult = await bridge.call("create_script", _current_script_id, _editor.text)
		if res and res.is_ok():
			_set_status("saved: " + _current_script_id)
			var path := _scripts_dir() + "/" + _current_script_id + ".py"
			_mtimes[_current_script_id] = FileAccess.get_modified_time(path)
		else:
			_log_error("save failed", res)

func _on_run() -> void:
	if _current_script_id == "":
		_set_status("no script open")
		return
	_append_log("[b]run %s[/b]" % _current_script_id)
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("execute_script"):
		var res: PythonBridgeResult = await bridge.call("execute_script", _current_script_id, {}, "default", 30.0)
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
	if _current_script_id == "":
		_set_status("no script open")
		return
	_append_log("[b]generate wrapper %s[/b]" % _current_script_id)
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("introspect_script"):
		var res: PythonBridgeResult = await bridge.call("introspect_script", _current_script_id, "default")
		if res and res.is_ok():
			var schema: Array = res.value
			var generated := PythonBridgeWrapperGenerator.generate(schema, _current_script_id)
			if not bool(generated.get("ok", false)):
				_log_error("wrapper generation failed", generated)
				return
			_write_wrapper(_current_script_id, str(generated.get("code", "")))
		else:
			_log_error("introspect failed (instance ready?)", res)

func _write_wrapper(script_id: String, code: String) -> void:
	var dir := ""
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("workspace_dir"):
		dir = str(bridge.call("workspace_dir")) + "/wrappers"
	else:
		dir = "res://python_bridge/wrappers"
	DirAccess.make_dir_recursive_absolute(dir)
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
	if _current_script_id == "":
		_set_status("no script open")
		return
	var bridge := _resolve_bridge()
	if bridge and bridge.has_method("hot_reload_script"):
		var res: PythonBridgeResult = await bridge.call("hot_reload_script", _current_script_id)
		if res:
			_append_log("hot reload: %s" % JSON.stringify(res.meta if res.is_ok() else res.error))

# ------------------------------------------------------------------ Hot reload watcher
## Called by the plugin each editor frame while the panel exists.
func editor_poll() -> void:
	if _current_script_id == "":
		return
	var now := Time.get_ticks_msec()
	if now - _last_poll_ms < HOT_RELOAD_POLL_MS:
		return
	_last_poll_ms = now
	if not _mtimes.has(_current_script_id):
		return
	var path := _scripts_dir() + "/" + _current_script_id + ".py"
	if not FileAccess.file_exists(path):
		return
	var mtime := FileAccess.get_modified_time(path)
	if mtime != _mtimes[_current_script_id]:
		_mtimes[_current_script_id] = mtime
		_append_log("[color=#7fd9ff]file changed on disk: %s[/color]" % _current_script_id)
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