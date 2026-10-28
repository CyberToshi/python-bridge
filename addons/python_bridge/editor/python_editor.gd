class_name PythonBridgeEditorPanel
extends VBoxContainer
## Editor-Dock der Python Bridge: schreiben, ausführen, speichern und
## rückstandsfrei löschen von Python-Code direkt im Godot-Editor.
##
## Aufbau (bewusst schlank, Sublime-orientiert):
##   Toolbar   [ + ] [ Speichern ] [ Ausführen ]   Status …  Python-Status  [ ⋯ ]
##   Sidebar   Filter + Skriptliste (Doppelklick/Enter öffnet, RMB = Menü)
##   Editor    Tab-Leiste (ein CodeEdit pro Tab, Close-Button am aktiven Tab)
##   Log       farbige Ausgaben (grün ok, rot Fehler, gelb Hinweise)
##
## Zwei Arten von Skripten - beide erstklassig unterstützt:
##   1. PERSISTENTE DATEIEN  (.py / .pyx im Workspace-Skriptordner)
##      -> Speichern schreibt auf die Festplatte, Löschen räumt ALLE
##         Artefakte ab (siehe core/script_files.gd).
##   2. TEMPORÄRE SKRIPTE ("Scratch", nur im Speicher)
##      -> laufen über PythonBridge.execute(); Strg+S speichert sie als Datei.
##
## Es gibt bewusst KEINEN Zustand außerhalb des Docks: jeder Tab ist ein
## eigener CodeEdit (eigene Undo-Historie, eigener Highlighter), die
## Zuordnung hängt als Meta am Node - damit überlebt das Dock auch einen
## Editor-Hot-Reload des Skripts (siehe _ensure_ui).

const TAB_FILE := "file"
const TAB_SCRATCH := "scratch"
const POLL_INTERVAL_MS := 1000
const LIST_REFRESH_MS := 2500

# --- Aktionen der Dialoge/Menüs (Strings statt Magie-Indizes) -------------
const ACT_NEW_FILE := "new_file"
const ACT_SAVE_AS := "save_as"
const ACT_RENAME := "rename"

# --- Laufzeit -------------------------------------------------------------
var _bridge: Object = null
var _store: PythonBridgeScriptStore = null

# Toolbar
var _new_menu: MenuButton = null
var _save_button: Button = null
var _run_button: Button = null
var _status: Label = null
var _instance_label: Label = null
var _more_menu: MenuButton = null

# Sidebar
var _filter: LineEdit = null
var _file_list: ItemList = null
var _list_menu: PopupMenu = null

# Editor
var _tabs: TabContainer = null
var _empty_label: Label = null
var _log: RichTextLabel = null

# Dialoge
var _name_dialog: AcceptDialog = null
var _name_label: Label = null
var _name_edit: LineEdit = null
var _name_hint: Label = null
var _name_action := ""
var _name_original_id := ""        # Ausgangs-Id bei rename
var _name_target = null            # CodeEdit bei rename/save_as
var _close_dialog: ConfirmationDialog = null
var _close_target = null           # CodeEdit, der geschlossen werden soll
var _close_after_save = null       # Tab, der nach "Speichern unter" schließt
var _delete_dialog: ConfirmationDialog = null
var _delete_target := ""
# Einstellungen: baut sich aus PythonBridgeConfig.project_setting_defs(),
# schreibt in Projekt > Projekteinstellungen > Python Bridge.
var _settings_dialog: ConfirmationDialog = null
var _settings_fields: Dictionary = {}   # key -> Control (CheckBox/OptionButton/LineEdit)

var _scratch_seq := 0
var _bbcode_regex: RegEx = null
var _busy := false
var _last_poll_ms := 0
var _last_list_ms := 0

func _init(bridge: Object = null) -> void:
	_bridge = bridge
	_build_ui()
	refresh_scripts()

## Das Autoload kann nach dem Panel erzeugt werden - deshalb lazy auflösen.
func _resolve_bridge() -> Object:
	if _bridge != null:
		return _bridge
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		_bridge = (main_loop as SceneTree).root.get_node_or_null("PythonBridge")
	return _bridge

# ================================================================== UI-Aufbau
## Baut das komplette UI. Wird nach einem Editor-Hot-Reload des Skripts erneut
## aufgerufen: der Instanz-Node existiert weiter (mit allen Child-Nodes), aber
## neu deklarierte Member sind null. Vor dem Verwerfen werden offene Tabs aus
## den bestehenden CodeEdit-Nodes geborgen, damit kein Text verloren geht.
func _ensure_ui() -> void:
	if _tabs != null and _file_list != null and _log != null and _store != null:
		return
	var snapshot := _capture_tabs()
	_build_ui()
	_restore_tabs(snapshot)
	refresh_scripts()

func _capture_tabs() -> Array:
	var out: Array = []
	for node in find_children("*", "CodeEdit", true, false):
		var editor := node as CodeEdit
		if editor == null or not editor.has_meta("script_id"):
			continue
		out.append({
			"script_id": str(editor.get_meta("script_id", "")),
			"kind": str(editor.get_meta("kind", TAB_FILE)),
			"ext": str(editor.get_meta("ext", "py")),
			"scratch_index": int(editor.get_meta("scratch_index", 0)),
			"text": editor.text,
			"saved_text": str(editor.get_meta("saved_text", "")),
		})
	return out

func _restore_tabs(snapshot: Array) -> void:
	_sync_dirs()
	for entry in snapshot:
		var kind := str(entry.get("kind", TAB_FILE))
		var editor := _create_editor(str(entry.get("script_id", "")), kind, str(entry.get("ext", "py")))
		if kind == TAB_SCRATCH:
			editor.set_meta("scratch_index", int(entry.get("scratch_index", 0)))
			_scratch_seq = maxi(_scratch_seq, int(entry.get("scratch_index", 0)))
		editor.set_meta("saved_text", str(entry.get("saved_text", "")))
		editor.text = str(entry.get("text", ""))
		_refresh_dirty(editor)
		_add_tab(editor)
	if not snapshot.is_empty():
		_append_log("[color=#9fb3c8]Editor neu aufgebaut - %d offene Tabs wiederhergestellt.[/color]" % snapshot.size())

func _build_ui() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	custom_minimum_size = Vector2(520, 340)
	_store = PythonBridgeScriptStore.new()

	_build_toolbar()

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 6)
	add_child(split)

	_build_sidebar(split)

	var v_split := VSplitContainer.new()
	v_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v_split.add_theme_constant_override("separation", 4)
	split.add_child(v_split)

	_build_editor_area(v_split)
	_build_log(v_split)
	_build_dialogs()

	v_split.split_offset = -110
	split.split_offset = 165

func _build_toolbar() -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)
	add_child(bar)

	_new_menu = MenuButton.new()
	_new_menu.icon = _icon("Add")
	_new_menu.text = "" if _new_menu.icon != null else "Neu"
	_new_menu.flat = true
	_new_menu.tooltip_text = "Neu (Strg+N)"
	var popup := _new_menu.get_popup()
	popup.add_item("Neue Datei …", 0)
	popup.add_item("Temporäres Skript", 1)
	popup.id_pressed.connect(_on_new_menu_pressed)
	bar.add_child(_new_menu)

	bar.add_child(VSeparator.new())

	_save_button = Button.new()
	_save_button.icon = _icon("Save")
	_save_button.text = "" if _save_button.icon != null else "Speichern"
	_save_button.flat = true
	_save_button.tooltip_text = "Speichern (Strg+S)"
	_save_button.pressed.connect(_on_save_pressed)
	_attach_shortcut(_save_button, KEY_S)
	bar.add_child(_save_button)

	_run_button = Button.new()
	_run_button.icon = _icon("Play")
	_run_button.text = "" if _run_button.icon != null else "Ausführen"
	_run_button.flat = true
	_run_button.tooltip_text = "Ausführen (Strg+Enter)"
	_run_button.pressed.connect(_on_run_pressed)
	# Bewusst Strg+Enter statt F5: F5/F6 gehören im Godot-Editor dem Projekt
	# bzw. der Szene und sollen nicht vom Dock abgefangen werden.
	_attach_shortcut(_run_button, KEY_ENTER)
	bar.add_child(_run_button)

	_status = Label.new()
	_status.text = "bereit"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	_status.add_theme_color_override("font_color", Color(0.66, 0.70, 0.76))
	bar.add_child(_status)

	_instance_label = Label.new()
	_instance_label.text = "Python: –"
	_instance_label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	bar.add_child(_instance_label)

	_more_menu = MenuButton.new()
	_more_menu.icon = _icon("Tools")
	_more_menu.text = "" if _more_menu.icon != null else "Mehr"
	_more_menu.flat = true
	_more_menu.tooltip_text = "Weitere Aktionen"
	var more := _more_menu.get_popup()
	more.add_item("GDScript-Wrapper generieren", 0)
	more.add_item("Hot Reload (Instanz neu definieren)", 1)
	more.add_separator()
	more.add_check_item("Als Cython-Modul speichern (.pyx)", 2)
	more.add_item("Cython kompilieren", 3)
	more.add_separator()
	more.add_item("Umbenennen …", 4)
	more.add_item("Löschen …", 5)
	more.add_separator()
	more.add_item("Log leeren", 6)
	more.add_separator()
	more.add_item("Einstellungen …", 7)
	more.id_pressed.connect(_on_more_menu_pressed)
	more.about_to_popup.connect(_sync_more_menu)
	bar.add_child(_more_menu)

func _build_sidebar(parent: Control) -> void:
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(150, 0)
	side.add_theme_constant_override("separation", 3)
	parent.add_child(side)

	_filter = LineEdit.new()
	_filter.placeholder_text = "Filtern …"
	_filter.clear_button_enabled = true
	_filter.text_changed.connect(func(_t: String) -> void: refresh_scripts(true))
	side.add_child(_filter)

	_file_list = ItemList.new()
	_file_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_file_list.custom_minimum_size = Vector2(140, 120)
	_file_list.allow_reselect = true
	# Öffnen per Linksklick (nicht bei reiner Tastatur-Navigation, sonst
	# würde jedes Pfeil-runter eine Datei öffnen) und per Doppelklick/Enter.
	_file_list.item_clicked.connect(_on_list_clicked)
	_file_list.item_activated.connect(_on_list_selected)
	side.add_child(_file_list)

	_list_menu = PopupMenu.new()
	_list_menu.add_item("Öffnen", 0)
	_list_menu.add_item("Umbenennen …", 1)
	_list_menu.add_item("Löschen …", 2)
	_list_menu.id_pressed.connect(_on_list_menu_pressed)
	add_child(_list_menu)

func _build_editor_area(parent: Control) -> void:
	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.custom_minimum_size = Vector2(280, 150)
	_tabs.drag_to_rearrange_enabled = true
	_tabs.clip_tabs = true
	_tabs.tab_changed.connect(_on_tab_changed)
	# Close-Button nur am aktiven Tab (Sublime-Look) + Mittelklick schließt.
	# get_tab_bar() existiert ab Godot 4.5; auf älteren Versionen fällt der
	# Close-Button weg - schließen geht dort per Strg+W und Tab-Menü.
	if _tabs.has_method("get_tab_bar"):
		var tab_bar: TabBar = _tabs.get_tab_bar()
		if tab_bar != null:
			tab_bar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ACTIVE_ONLY
			tab_bar.close_with_middle_mouse = true
			tab_bar.scrolling_enabled = true
			if "max_tab_width" in tab_bar:
				tab_bar.max_tab_width = 220
			tab_bar.tab_close_pressed.connect(_on_tab_close_pressed)
	elif _tabs.has_signal("tab_close_pressed"):
		_tabs.connect("tab_close_pressed", _on_tab_close_pressed)
	parent.add_child(_tabs)

	_empty_label = Label.new()
	_empty_label.text = "Keine Datei offen\n\nStrg+N = neue Datei · Doppelklick links = Datei öffnen"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty_label.add_theme_color_override("font_color", Color(0.55, 0.59, 0.65))
	parent.add_child(_empty_label)
	_empty_label.visible = true

func _build_log(parent: Control) -> void:
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 70)
	parent.add_child(_log)

func _build_dialogs() -> void:
	_name_dialog = AcceptDialog.new()
	_name_dialog.title = "Python-Datei"
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(340, 0)
	box.add_theme_constant_override("separation", 6)
	_name_label = Label.new()
	box.add_child(_name_label)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "z. B. mein_modul"
	_name_edit.text_changed.connect(func(_t: String) -> void: _validate_name())
	box.add_child(_name_edit)
	_name_hint = Label.new()
	_name_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name_hint.add_theme_color_override("font_color", Color(0.66, 0.70, 0.76))
	box.add_child(_name_hint)
	_name_dialog.add_child(box)
	_name_dialog.register_text_enter(_name_edit)
	_name_dialog.confirmed.connect(_on_name_confirmed)
	# Abbruch darf kein "nach dem Speichern schließen" zurücklassen.
	_name_dialog.canceled.connect(func() -> void: _close_after_save = null)
	add_child(_name_dialog)

	_close_dialog = ConfirmationDialog.new()
	_close_dialog.title = "Ungespeicherte Änderungen"
	_close_dialog.ok_button_text = "Speichern & schließen"
	_close_dialog.cancel_button_text = "Abbrechen"
	_close_dialog.add_button("Verwerfen", true, "discard")
	_close_dialog.confirmed.connect(_on_close_confirmed)
	_close_dialog.custom_action.connect(_on_close_custom_action)
	add_child(_close_dialog)

	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.title = "Skript löschen"
	_delete_dialog.ok_button_text = "Endgültig löschen"
	_delete_dialog.cancel_button_text = "Abbrechen"
	_delete_dialog.confirmed.connect(_on_delete_confirmed)
	add_child(_delete_dialog)

	_build_settings_dialog()

# ================================================================== Einstellungen
## Gleiche Felder wie in Projekt > Projekteinstellungen > Python Bridge:
## eine Registrierung (PythonBridgeConfig.project_setting_defs()), drei
## Verbraucher (Editor-Dialog, Projekt-Einstellungen, Facade).
func _build_settings_dialog() -> void:
	_settings_dialog = ConfirmationDialog.new()
	_settings_dialog.title = "Python Bridge – Einstellungen"
	_settings_dialog.ok_button_text = "Speichern"
	_settings_dialog.cancel_button_text = "Abbrechen"
	_settings_dialog.add_button("Speichern & neu starten", true, "restart")
	_settings_dialog.confirmed.connect(_on_settings_confirmed)
	_settings_dialog.custom_action.connect(_on_settings_custom_action)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(470, 340)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)

	var intro := Label.new()
	intro.text = ("Diese Werte gelten beim nächsten Start der Python-Instanz. "
		+ "Sie landen in Projekt > Projekteinstellungen > Python Bridge "
		+ "und sind damit versionierbar.")
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_color_override("font_color", Color(0.66, 0.70, 0.76))
	box.add_child(intro)

	for def in PythonBridgeConfig.project_setting_defs():
		box.add_child(HSeparator.new())
		var label := Label.new()
		label.text = str(def.get("label", def.get("key", "")))
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(label)
		var key := str(def["key"])
		var field: Control = null
		if int(def["type"]) == TYPE_BOOL:
			var check := CheckBox.new()
			check.text = "aktiviert"
			field = check
		elif int(def["hint"]) == PROPERTY_HINT_ENUM:
			var option := OptionButton.new()
			for item in str(def["hint_string"]).split(",", false):
				option.add_item(item.strip_edges())
			field = option
		else:
			var edit := LineEdit.new()
			edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			if str(def["hint_string"]) != "":
				edit.placeholder_text = str(def["hint_string"])
			field = edit
		field.tooltip_text = str(def["path"])
		box.add_child(field)
		_settings_fields[key] = field

	_settings_dialog.add_child(scroll)
	add_child(_settings_dialog)

## Öffnet den Einstellungs-Dialog (auch aus dem Tool-Menü des Plugins).
func open_settings() -> void:
	_ensure_ui()
	if _settings_dialog == null:
		return
	_refresh_settings_fields()
	_settings_dialog.popup_centered(Vector2i(520, 440))

func _refresh_settings_fields() -> void:
	for def in PythonBridgeConfig.project_setting_defs():
		var key := str(def["key"])
		var field: Control = _settings_fields.get(key)
		if field == null:
			continue
		var value: Variant = ProjectSettings.get_setting(str(def["path"]), def["default"])
		if field is CheckBox:
			(field as CheckBox).button_pressed = bool(value)
		elif field is OptionButton:
			var option := field as OptionButton
			var wanted := str(value)
			var index := -1
			for i in option.item_count:
				if option.get_item_text(i) == wanted:
					index = i
					break
			option.select(maxi(index, 0))
		elif field is LineEdit:
			(field as LineEdit).text = _settings_value_to_text(value)

func _settings_value_to_text(value: Variant) -> String:
	if value is Array or value is PackedStringArray:
		var parts := PackedStringArray()
		for item in value:
			parts.append(str(item))
		return ", ".join(parts)
	return str(value)

func _settings_field_value(key: String, def: Dictionary) -> Variant:
	var field: Control = _settings_fields.get(key)
	if field == null:
		return def["default"]
	if field is CheckBox:
		return (field as CheckBox).button_pressed
	if field is OptionButton:
		var option := field as OptionButton
		if option.selected < 0:
			return str(def["default"])
		return option.get_item_text(option.selected)
	if field is LineEdit:
		return (field as LineEdit).text.strip_edges()
	return def["default"]

## Schreibt alle Felder in die Projekt-Einstellungen (und damit in
## project.godot, sobald der Nutzer speichert/exportiert).
func _apply_settings_fields() -> Array:
	var changed: Array = []
	for def in PythonBridgeConfig.project_setting_defs():
		var key := str(def["key"])
		var path := str(def["path"])
		var value: Variant = _settings_field_value(key, def)
		if str(ProjectSettings.get_setting(path, "")) != str(value):
			changed.append(key)
		ProjectSettings.set_setting(path, value)
	ProjectSettings.save()
	var bridge := _resolve_bridge()
	if bridge != null and bridge.has_method("reload_config"):
		bridge.call("reload_config")
	_sync_dirs()
	return changed

func _on_settings_confirmed() -> void:
	var changed := _apply_settings_fields()
	_append_log("[color=#7fd97f]Einstellungen gespeichert[/color] (%s) – aktiv beim nächsten Start der Instanz."
		% ("unverändert" if changed.is_empty() else ", ".join(PackedStringArray(changed))))
	_set_status("Einstellungen gespeichert")
	refresh_scripts(true)
	_sync_instance_label()

func _on_settings_custom_action(action: StringName) -> void:
	if action != "restart":
		return
	_on_settings_confirmed()
	_restart_instance()

## Startet die Default-Instanz mit den neuen Einstellungen neu (Prozess neu,
## Workspace bleibt). Nur wenn bereits eine Instanz existiert oder das Dock
## gerade laeuft - sonst waere es ein Kaltstart, den der Nutzer selbst ausloest.
func _restart_instance() -> void:
	var bridge := _resolve_bridge()
	if bridge == null:
		return
	# restart_instance() wartet den Stop ab. Ein blosses stop_instance() +
	# _ensure_instance() würde am STOPPING-Zustand scheitern und keine Instanz
	# zurücklassen.
	if str(bridge.call("instance_status", "default")) == "none":
		_append_log("Keine laufende Instanz – Einstellungen greifen beim nächsten Start.")
		_sync_instance_label()
		return
	_append_log("[b]Python-Instanz wird mit den neuen Einstellungen neu gestartet …[/b]")
	# Waehrend des Neustarts darf kein zweiter Start/Run dazwischenfunken.
	_busy = true
	if _run_button != null:
		_run_button.disabled = true
	var res: Variant = await bridge.call("restart_instance", "default")
	_busy = false
	if _run_button != null:
		_run_button.disabled = false
	if res is PythonBridgeResult and (res as PythonBridgeResult).is_ok():
		_append_log("[color=#7fd97f]Instanz läuft mit den neuen Einstellungen.[/color]")
	else:
		var message := (res as PythonBridgeResult).error_message() if res is PythonBridgeResult else str(res)
		_append_log("[color=#ff8a80]Neustart fehlgeschlagen: %s[/color]" % message)
	_sync_instance_label()

# ================================================================== Werkzeuge
func _icon(name: String) -> Texture2D:
	if not Engine.is_editor_hint():
		return null
	var theme := EditorInterface.get_editor_theme()
	if theme == null or not theme.has_icon(name, "EditorIcons"):
		return null
	return theme.get_icon(name, "EditorIcons")

## Shortcuts sind auf dieses Dock begrenzt (shortcut_context), damit Strg+S
## nicht den GDScript-Editor des Projekts überschreibt.
func _attach_shortcut(button: Button, keycode: Key, with_ctrl := true) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	if with_ctrl:
		event.ctrl_pressed = true
		event.command_or_control_autoremap = true
	var shortcut := Shortcut.new()
	shortcut.events = [event]
	button.shortcut = shortcut
	button.shortcut_in_tooltip = false
	button.shortcut_context = self

func _tab_display_name(editor: CodeEdit) -> String:
	if str(editor.get_meta("kind", TAB_FILE)) == TAB_SCRATCH:
		return "Scratch %d" % int(editor.get_meta("scratch_index", 0))
	return str(editor.get_meta("script_id", "")).get_file() + "." + str(editor.get_meta("ext", "py"))

func _tab_title(editor: CodeEdit) -> String:
	return ("● " if _is_dirty(editor) else "") + _tab_display_name(editor)

func _tab_tooltip(editor: CodeEdit) -> String:
	if str(editor.get_meta("kind", TAB_FILE)) == TAB_SCRATCH:
		return "Temporäres Skript (nur im Speicher). Strg+S speichert es als Datei."
	var path := _store.path_for(str(editor.get_meta("script_id", "")), str(editor.get_meta("ext", "py")))
	return path + ("\nCython-Modul: wird kompiliert und per call_script importiert." \
		if str(editor.get_meta("ext", "py")) == "pyx" else "")

func _active_editor() -> CodeEdit:
	if _tabs == null or _tabs.get_tab_count() == 0:
		return null
	return _tabs.get_current_tab_control() as CodeEdit

func _find_tab(script_id: String) -> CodeEdit:
	if _tabs == null or script_id == "":
		return null
	for i in _tabs.get_tab_count():
		var editor := _tabs.get_child(i) as CodeEdit
		if editor != null and str(editor.get_meta("kind", TAB_FILE)) == TAB_FILE \
				and str(editor.get_meta("script_id", "")) == script_id:
			return editor
	return null

func _is_dirty(editor: CodeEdit) -> bool:
	return bool(editor.get_meta("dirty", false))

## Vergleicht Text mit dem zuletzt gespeicherten/geöffneten Stand. Damit ist
## "geändert" auch nach Undo korrekt (das alte "*"-Flag blieb kleben).
func _refresh_dirty(editor: CodeEdit) -> bool:
	var dirty := editor.text != str(editor.get_meta("saved_text", ""))
	editor.set_meta("dirty", dirty)
	return dirty

func _set_saved_text(editor: CodeEdit, text: String) -> void:
	editor.set_meta("saved_text", text)
	editor.set_meta("dirty", false)

func _update_tab_title(editor: CodeEdit) -> void:
	if _tabs == null or not _tabs.is_ancestor_of(editor):
		return
	var index := editor.get_index()
	_tabs.set_tab_title(index, _tab_title(editor))
	_tabs.set_tab_tooltip(index, _tab_tooltip(editor))

func _add_tab(editor: CodeEdit) -> void:
	_tabs.add_child(editor)
	var index := _tabs.get_tab_count() - 1
	_tabs.set_tab_title(index, _tab_title(editor))
	_tabs.set_tab_tooltip(index, _tab_tooltip(editor))
	_tabs.current_tab = index
	_refresh_empty_state()
	editor.grab_focus()

func _refresh_empty_state() -> void:
	var has_tabs := _tabs.get_tab_count() > 0
	_empty_label.visible = not has_tabs
	_tabs.visible = has_tabs

func _select_tab(editor: CodeEdit) -> void:
	if _tabs == null or not _tabs.is_ancestor_of(editor):
		return
	_tabs.current_tab = editor.get_index()
	editor.grab_focus()
	_sync_status()

func _create_editor(script_id: String, kind: String, ext: String) -> CodeEdit:
	var editor := CodeEdit.new()
	editor.name = "Code_%d" % (Time.get_ticks_usec())
	editor.syntax_highlighter = PythonBridgeSyntaxHighlighter.new()
	_apply_editor_style(editor)
	editor.set_meta("script_id", script_id)
	editor.set_meta("kind", kind)
	editor.set_meta("ext", ext)
	editor.set_meta("saved_text", "")
	editor.set_meta("dirty", false)
	editor.set_meta("mtime", _store.mtime(script_id) if kind == TAB_FILE else -1)
	editor.text_changed.connect(_on_editor_text_changed.bind(editor))
	editor.gui_input.connect(_on_editor_gui_input.bind(editor))
	return editor

## Ruhiger, professioneller Editor-Look: Zeilennummern, Gutter, 4 Spaces,
## Tabs sichtbar, aktuelle Zeile hervorgehoben, Mono-Font des Editors.
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
	editor.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	editor.highlight_current_line = true
	editor.highlight_all_occurrences = true
	editor.add_theme_color_override("line_number_color", Color(0.45, 0.49, 0.55))
	editor.add_theme_color_override("current_line_color", Color(1, 1, 1, 0.045))
	if Engine.is_editor_hint():
		var theme := EditorInterface.get_editor_theme()
		if theme != null:
			if theme.has_font("source", "EditorFonts"):
				editor.add_theme_font_override("font", theme.get_font("source", "EditorFonts"))
			if theme.has_font_size("source_size", "EditorFonts"):
				editor.add_theme_font_size_override("font_size", theme.get_font_size("source_size", "EditorFonts"))

func _clear_highlighter_cache(editor: CodeEdit) -> void:
	var highlighter := editor.syntax_highlighter
	if highlighter is PythonBridgeSyntaxHighlighter:
		(highlighter as PythonBridgeSyntaxHighlighter).invalidate()

func _sync_dirs() -> void:
	if _store == null:
		_store = PythonBridgeScriptStore.new()
	var bridge := _resolve_bridge()
	var scripts := ""
	var wrappers := ""
	if bridge == null:
		if _store.is_configured():
			_store.configure("", "")
		return
	if bridge.has_method("scripts_dir"):
		scripts = str(bridge.call("scripts_dir"))
	elif bridge.has_method("workspace_dir"):
		scripts = str(bridge.call("workspace_dir")) + "/scripts"
	wrappers = scripts.get_base_dir().path_join("wrappers")
	if bridge.has_method("wrapper_dir"):
		wrappers = str(bridge.call("wrapper_dir"))
	if _store.scripts_dir == scripts and _store.wrappers_dir == wrappers:
		return
	_store.configure(scripts, wrappers)

func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text

func _sync_status() -> void:
	var editor := _active_editor()
	if editor == null:
		_set_status("Keine Datei offen")
		return
	var state := "● geändert" if _is_dirty(editor) else "gespeichert"
	if str(editor.get_meta("kind", TAB_FILE)) == TAB_SCRATCH:
		state = "temporär (nicht auf der Festplatte)"
	_set_status("%s  ·  %s" % [_tab_display_name(editor), state])

func _append_log(text: String) -> void:
	if _log != null:
		_log.append_text(text + "\n")
	# Konsole/Output ohne BBCode-Tags: nur der reine Text.
	print("[PythonBridge/Editor] " + _strip_bbcode(text))

func _strip_bbcode(text: String) -> String:
	if _bbcode_regex == null:
		_bbcode_regex = RegEx.new()
		_bbcode_regex.compile("\\[/?(color|b|i|u)(=[^\\]]*)?\\]")
	return _bbcode_regex.sub(text, "", true)

# ================================================================== Dateiliste
## Liest den Skriptordner neu ein. `from_poll` unterdrückt Statusmeldungen,
## damit der Hintergrund-Poll die Statuszeile nicht überschreibt.
func refresh_scripts(from_poll := false) -> void:
	_ensure_ui()
	_sync_dirs()
	if _file_list == null:
		return
	var previous := _selected_list_id()
	_file_list.clear()
	if not _store.is_configured():
		if not from_poll:
			_set_status("Workspace nicht verfügbar - Instanz starten oder configure() aufrufen")
		return
	var filter := _filter.text.strip_edges().to_lower()
	var shown := 0
	for entry in _store.list():
		var id := str(entry.get("id", ""))
		if filter != "" and not id.to_lower().contains(filter):
			continue
		var ext := str(entry.get("ext", "py"))
		var index := _file_list.add_item(id)
		_file_list.set_item_metadata(index, id)
		_file_list.set_item_tooltip(index, str(entry.get("path", "")))
		if ext == "pyx":
			_file_list.set_item_text(index, id + "  ·pyx")
			_file_list.set_item_custom_fg_color(index, Color(0.78, 0.65, 0.98))
		shown += 1
	if previous != "":
		_select_list_id(previous)
	if not from_poll:
		_set_status("%d Skript(e) · %d Tab(s) offen" % [shown, _tabs.get_tab_count()])

func _selected_list_id() -> String:
	if _file_list == null:
		return ""
	var selected := _file_list.get_selected_items()
	if selected.is_empty():
		return ""
	return str(_file_list.get_item_metadata(selected[0]))

func _select_list_id(script_id: String) -> void:
	for i in _file_list.item_count:
		if str(_file_list.get_item_metadata(i)) == script_id:
			_file_list.select(i)
			return

func _on_list_selected(index: int) -> void:
	if index < 0:
		return
	var script_id := str(_file_list.get_item_metadata(index))
	open_script(script_id)

func _on_list_clicked(index: int, at_position: Vector2, mouse_button_index: int) -> void:
	if index < 0:
		return
	if mouse_button_index == MOUSE_BUTTON_LEFT:
		_file_list.select(index)
		open_script(str(_file_list.get_item_metadata(index)))
		return
	if mouse_button_index != MOUSE_BUTTON_RIGHT:
		return
	_file_list.select(index)
	_list_menu.position = Vector2i(_file_list.get_screen_position() + at_position)
	_list_menu.popup()
	accept_event()

func _on_list_menu_pressed(id: int) -> void:
	var script_id := _selected_list_id()
	if script_id == "":
		return
	match id:
		0:
			open_script(script_id)
		1:
			_open_name_dialog(ACT_RENAME, _find_tab(script_id), script_id)
		2:
			request_delete(script_id)

# ================================================================== Tabs
## Öffnet ein Skript in einem Tab (oder aktiviert den vorhandenen Tab).
## Rückgabe: die geladene Script-Id oder "" bei Fehler.
func open_script(script_id: String) -> String:
	_ensure_ui()
	_sync_dirs()
	if script_id == "":
		return ""
	var existing := _find_tab(script_id)
	if existing != null:
		_select_tab(existing)
		return script_id
	var read := _store.read(script_id)
	if not bool(read.get("ok", false)):
		_append_log("[color=#ff8a80]%s[/color]" % str(read.get("error", "Öffnen fehlgeschlagen.")))
		_set_status("Öffnen fehlgeschlagen")
		return ""
	var editor := _create_editor(script_id, TAB_FILE, str(read.get("ext", "py")))
	editor.set_meta("saved_text", str(read.get("text", "")))
	editor.text = str(read.get("text", ""))
	_refresh_dirty(editor)
	_add_tab(editor)
	_append_log("geöffnet: %s" % _tab_display_name(editor))
	_sync_status()
	return script_id

## Legt ein temporäres Skript an: lebt nur im Dock, läuft per execute().
## Öffentlich für das Tool-Menü des Plugins ("Neue Datei …").
func open_new_file_dialog() -> void:
	_ensure_ui()
	_open_name_dialog(ACT_NEW_FILE, null, "")

func new_scratch() -> CodeEdit:
	_ensure_ui()
	_sync_dirs()
	_scratch_seq += 1
	var editor := _create_editor("", TAB_SCRATCH, "")
	editor.set_meta("scratch_index", _scratch_seq)
	editor.text = ""
	_add_tab(editor)
	_append_log("temporäres Skript angelegt - Strg+S speichert es als Datei, Strg+Enter führt es aus.")
	_sync_status()
	return editor

func _on_tab_changed(_index: int) -> void:
	_refresh_empty_state()
	_sync_status()
	_sync_more_menu()
	var editor := _active_editor()
	if editor != null:
		editor.grab_focus()
		var script_id := str(editor.get_meta("script_id", ""))
		if script_id != "":
			_select_list_id(script_id)

func _on_tab_close_pressed(index: int) -> void:
	if index < 0 or index >= _tabs.get_tab_count():
		return
	_request_close(_tabs.get_child(index) as CodeEdit)

func _request_close(editor: CodeEdit) -> void:
	if editor == null:
		return
	if not _is_dirty(editor):
		_close_tab(editor)
		return
	_close_target = editor
	_close_dialog.dialog_text = "»%s« hat ungespeicherte Änderungen." % _tab_display_name(editor)
	_close_dialog.popup_centered()

func _on_close_confirmed() -> void:
	var editor := _close_target as CodeEdit
	_close_target = null
	if editor == null:
		return
	if str(editor.get_meta("kind", TAB_FILE)) == TAB_SCRATCH:
		# Ein temporäres Skript muss erst eine Datei werden.
		_close_after_save = editor
		_open_name_dialog(ACT_SAVE_AS, editor, "")
		return
	if _save_editor(editor):
		_close_tab(editor)

func _on_close_custom_action(action: StringName) -> void:
	if action == "discard":
		var editor := _close_target as CodeEdit
		_close_target = null
		if editor != null:
			_close_tab(editor)

func _close_tab(editor: CodeEdit) -> void:
	if editor == null or _tabs == null or not _tabs.is_ancestor_of(editor):
		return
	var name := _tab_display_name(editor)
	_tabs.remove_child(editor)
	editor.queue_free()
	_refresh_empty_state()
	_sync_status()
	_set_status("geschlossen: " + name)

func _on_editor_gui_input(event: InputEvent, editor: CodeEdit) -> void:
	if not (event is InputEventKey) or not event.pressed or (event as InputEventKey).echo:
		return
	var key := event as InputEventKey
	var ctrl := key.ctrl_pressed or key.meta_pressed
	if ctrl and key.keycode == KEY_W:
		_request_close(editor)
		editor.accept_event()
	elif ctrl and key.keycode == KEY_S:
		_save_editor(editor)
		editor.accept_event()
	elif ctrl and key.keycode == KEY_N:
		_on_new_menu_pressed(0)
		editor.accept_event()
	elif ctrl and (key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER):
		if _active_editor() != editor:
			_select_tab(editor)
		_on_run_pressed()
		editor.accept_event()

func _on_editor_text_changed(editor: CodeEdit) -> void:
	_clear_highlighter_cache(editor)
	var was_dirty := _is_dirty(editor)
	var now_dirty := _refresh_dirty(editor)
	if was_dirty != now_dirty:
		_update_tab_title(editor)
		_sync_status()

# ================================================================== Speichern
func _on_save_pressed() -> void:
	var editor := _active_editor()
	if editor == null:
		_set_status("Keine Datei offen")
		return
	_save_editor(editor)

## Speichert den Tab-Inhalt. Persistente Tabs schreiben sofort (synchron, ohne
## await), temporäre Tabs öffnen den "Speichern unter"-Dialog.
func _save_editor(editor: CodeEdit) -> bool:
	if str(editor.get_meta("kind", TAB_FILE)) == TAB_SCRATCH:
		_open_name_dialog(ACT_SAVE_AS, editor, "")
		return false
	var script_id := str(editor.get_meta("script_id", ""))
	var as_cython := str(editor.get_meta("ext", "py")) == "pyx"
	var write := _store.write(script_id, editor.text, as_cython)
	if not bool(write.get("ok", false)):
		_append_log("[color=#ff8a80]Speichern fehlgeschlagen: %s[/color]" % str(write.get("error", "")))
		_set_status("Speichern fehlgeschlagen")
		return false
	_after_write(editor, write)
	return true

## Meldet der Bridge, dass eine Datei direkt auf der Platte geschrieben wurde
## (script_store schreibt ohne die Facade). notify_script_saved() spiegelt die
## Datei im Web in den Pyodide-Workspace und verwirft Cython-Module des Stems;
## ältere Bridge-Stände kennen nur forget_script_cache().
func _notify_bridge_saved(script_id: String, path: String) -> void:
	var bridge := _resolve_bridge()
	if bridge == null:
		return
	if bridge.has_method("notify_script_saved"):
		bridge.call("notify_script_saved", script_id, path)
	elif bridge.has_method("forget_script_cache"):
		bridge.call("forget_script_cache", path)

func _after_write(editor: CodeEdit, write: Dictionary) -> void:
	var script_id := str(editor.get_meta("script_id", ""))
	var counterpart := str(write.get("removed_counterpart", ""))
	_set_saved_text(editor, editor.text)
	editor.set_meta("mtime", _store.mtime(script_id))
	_update_tab_title(editor)
	_notify_bridge_saved(script_id, str(write.get("path", "")))
	if counterpart != "":
		_append_log("Gegenstück entfernt (%s) - ein Skript existiert nur einmal." % counterpart.get_file())
	var purged: Array = write.get("purged_build", [])
	if not purged.is_empty():
		_append_log("Build-Reste entfernt: %s" % ", ".join(PackedStringArray(purged)))
	_append_log("[color=#7fd97f]gespeichert: %s[/color]" % str(write.get("path", "")))
	_set_status("gespeichert: " + _tab_display_name(editor))
	refresh_scripts(true)
	_sync_status()

# ================================================================== Dialoge
func _on_new_menu_pressed(id: int) -> void:
	match id:
		0:
			_open_name_dialog(ACT_NEW_FILE, null, "")
		1:
			new_scratch()

func _open_name_dialog(action: String, target, initial := "") -> void:
	_name_action = action
	_name_target = target
	_name_original_id = initial if action == ACT_RENAME else ""
	var start := initial
	match action:
		ACT_NEW_FILE:
			_name_dialog.title = "Neue Python-Datei"
			_name_label.text = "Dateiname (ohne .py):"
			_name_dialog.ok_button_text = "Anlegen"
			_name_edit.placeholder_text = "z. B. mein_modul"
		ACT_SAVE_AS:
			_name_dialog.title = "Temporäres Skript speichern"
			_name_label.text = "Als Datei speichern (ohne .py):"
			_name_dialog.ok_button_text = "Speichern"
			_name_edit.placeholder_text = "z. B. mein_modul"
			start = "skript_%d" % maxi(1, _scratch_seq)
		ACT_RENAME:
			_name_dialog.title = "Skript umbenennen"
			_name_label.text = "Neuer Name (ohne .py):"
			_name_dialog.ok_button_text = "Umbenennen"
			start = initial
	_name_edit.text = start
	_validate_name()
	_name_dialog.popup_centered(Vector2i(380, 0))
	_name_edit.grab_focus()
	_name_edit.select_all()

func _validate_name() -> void:
	var script_id := _name_edit.text.strip_edges()
	var error := ""
	if script_id == "":
		error = "Bitte einen Namen eingeben."
	elif _name_action == ACT_RENAME and script_id == _name_original_id:
		error = ""  # unverändert = ok
	elif _name_action == ACT_RENAME:
		error = PythonBridgeScriptFiles.validate_script_id(script_id)
		if error == "" and _store.exists(script_id):
			error = "Es gibt bereits ein Skript \"%s\"." % script_id
	else:
		error = _store.validate_new_id(script_id)
	_name_hint.text = error if error != "" else "Datei: %s.py" % script_id
	_name_hint.add_theme_color_override("font_color",
		Color(0.98, 0.55, 0.55) if error != "" else Color(0.62, 0.72, 0.62))
	_name_dialog.get_ok_button().disabled = error != "" or script_id == ""

func _name_arg_for_rename() -> String:
	return _name_original_id

func _on_name_confirmed() -> void:
	var script_id := _name_edit.text.strip_edges()
	if script_id == "":
		return
	match _name_action:
		ACT_NEW_FILE:
			var write := _store.write(script_id, "")
			if not bool(write.get("ok", false)):
				_append_log("[color=#ff8a80]Anlegen fehlgeschlagen: %s[/color]" % str(write.get("error", "")))
				return
			_append_log("[color=#7fd97f]angelegt: %s[/color]" % str(write.get("path", "")))
			# Leere Datei: im Web muss sie im MEMFS existieren, bevor sie
			# importiert wird (Desktop sieht die Platte direkt).
			_notify_bridge_saved(script_id, str(write.get("path", "")))
			refresh_scripts(true)
			open_script(script_id)
		ACT_SAVE_AS:
			_save_as(script_id)
		ACT_RENAME:
			_rename_to(script_id)

func _save_as(script_id: String) -> void:
	var editor := _name_target as CodeEdit
	if editor == null:
		return
	var write := _store.write(script_id, editor.text)
	if not bool(write.get("ok", false)):
		_append_log("[color=#ff8a80]Speichern fehlgeschlagen: %s[/color]" % str(write.get("error", "")))
		_set_status("Speichern fehlgeschlagen")
		return
	editor.set_meta("kind", TAB_FILE)
	editor.set_meta("script_id", script_id)
	editor.set_meta("ext", str(write.get("ext", "py")))
	# Der Scratch-Name verschwindet: der Tab ist jetzt eine echte Datei.
	editor.remove_meta("scratch_index")
	_after_write(editor, write)
	var closing := _close_after_save as CodeEdit
	_close_after_save = null
	if closing == editor:
		_close_tab(editor)

func _rename_to(new_id: String) -> void:
	var editor := _name_target as CodeEdit
	var old_id := _name_original_id
	if old_id == "" or new_id == old_id:
		return
	var result := _store.rename(old_id, new_id)
	if not bool(result.get("ok", false)):
		_append_log("[color=#ff8a80]Umbenennen fehlgeschlagen: %s[/color]" % str(result.get("error", "")))
		_set_status("Umbenennen fehlgeschlagen")
		return
	# Alter Name verschwindet vollständig (Cache, laufende Kontexte, im Web die
	# Datei im MEMFS) - sonst bliebe das Skript unter dem alten Namen
	# importierbar, während der neue Name unbekannt ist.
	var bridge := _resolve_bridge()
	if bridge != null:
		if bridge.has_method("notify_script_deleted"):
			bridge.call("notify_script_deleted", old_id)
		elif bridge.has_method("forget_script_cache"):
			bridge.call("forget_script_cache", _store.path_for(old_id, "py"))
			bridge.call("forget_script_cache", _store.path_for(old_id, "pyx"))
	_notify_bridge_saved(new_id, str(result.get("path", "")))
	if editor != null:
		editor.set_meta("script_id", new_id)
		editor.set_meta("ext", str(result.get("ext", "py")))
		editor.set_meta("mtime", _store.mtime(new_id))
		_update_tab_title(editor)
	_append_log("[color=#7fd97f]umbenannt: %s -> %s[/color]" % [old_id, new_id])
	_set_status("umbenannt: " + new_id)
	refresh_scripts(true)
	_sync_status()

## Öffentlich (auch per Rechtklick in der Liste erreichbar): löscht ein Skript
## samt aller Artefakte, nach Bestätigung.
func request_delete(script_id: String) -> void:
	if script_id == "":
		return
	_delete_target = script_id
	var editor := _find_tab(script_id)
	var extra := ""
	if editor != null and _is_dirty(editor):
		extra = "\n\nAchtung: der offene Tab hat ungespeicherte Änderungen - sie gehen verloren."
	_delete_dialog.dialog_text = ("»%s« endgültig löschen?\n\nEntfernt werden: Quelle (.py/.pyx), .pyc, "
		+ "Cython-Artefakte (.c/.so/.pyd/.obj), Build-Zustand und der generierte Wrapper.%s") % [script_id, extra]
	_delete_dialog.popup_centered()

func _on_delete_confirmed() -> void:
	var script_id := _delete_target
	_delete_target = ""
	if script_id == "":
		return
	var report := _delete_script(script_id)
	var editor := _find_tab(script_id)
	if editor != null:
		_close_tab(editor)
	if bool(report.get("ok", false)):
		var removed: Array = report.get("removed", [])
		if removed.is_empty():
			_append_log("[color=#ffd166]%s: nichts zu löschen (keine Datei gefunden).[/color]" % script_id)
		else:
			_append_log("[color=#7fd97f]gelöscht: %s (%d Datei(en)/Artefakt(e))[/color]" % [script_id, removed.size()])
			for path in removed:
				_append_log("  · %s" % str(path))
		_set_status("gelöscht: " + script_id)
	else:
		_append_log("[color=#ff8a80]Löschen fehlgeschlagen: %s[/color]" % str(report.get("error", "")))
		for entry in report.get("failed", []):
			_append_log("  · %s" % str(entry))
		_set_status("Löschen fehlgeschlagen")
	refresh_scripts(true)

## Bevorzugt die Facade (invalidiert zusätzlich den Registry-Cache), damit
## API und Dock exakt dieselbe Aufräumroutine nutzen.
func _delete_script(script_id: String) -> Dictionary:
	_sync_dirs()
	var bridge := _resolve_bridge()
	if bridge != null and bridge.has_method("delete_script"):
		var res: Variant = bridge.call("delete_script", script_id)
		if res is PythonBridgeResult:
			var result := res as PythonBridgeResult
			if result.is_ok() and result.value is Dictionary:
				return result.value
			return {"ok": false, "error": result.error_message()}
	return _store.delete(script_id)

# ================================================================== Ausführen
func _on_run_pressed() -> void:
	await run_active()

## Führt den aktiven Tab aus: persistente Dateien über execute_script (vorher
## speichern, damit exakt der sichtbare Code läuft), temporäre Skripte über
## execute() direkt aus dem Buffer.
func run_active() -> void:
	var editor := _active_editor()
	if editor == null:
		_set_status("Keine Datei offen")
		return
	if _busy:
		return
	var bridge := _resolve_bridge()
	if bridge == null:
		_append_log("[color=#ff8a80]PythonBridge-Autoload nicht gefunden.[/color]")
		return
	_busy = true
	_run_button.disabled = true
	_set_status("Python wird vorbereitet …")
	if not await _ensure_instance():
		_busy = false
		_run_button.disabled = false
		return

	var kind := str(editor.get_meta("kind", TAB_FILE))
	var res: Variant = null
	if kind == TAB_SCRATCH:
		_append_log("[b]run (temporär, %d Zeilen)[/b]" % editor.get_line_count())
		res = await bridge.call("execute", editor.text, {}, "default", 30.0)
	else:
		var ext := str(editor.get_meta("ext", "py"))
		if ext == "pyx":
			_append_log("[color=#ffd166].pyx-Module werden nicht ausgeführt, sondern importiert: "
				+ "»GDScript-Wrapper generieren« oder PythonBridge.call_script(\"%s\", \"f\", [...]) verwenden.[/color]"
				% str(editor.get_meta("script_id", "")))
			_set_status("kein Run für .pyx")
			_busy = false
			_run_button.disabled = false
			return
		if _is_dirty(editor) and not _save_editor(editor):
			_busy = false
			_run_button.disabled = false
			return
		var script_id := str(editor.get_meta("script_id", ""))
		_append_log("[b]run %s[/b]" % script_id)
		res = await bridge.call("execute_script", script_id, {}, "default", 30.0)

	_log_result(res)
	_busy = false
	_run_button.disabled = false
	_sync_instance_label()

func _ensure_instance() -> bool:
	var bridge := _resolve_bridge()
	if bridge == null:
		return false
	if str(bridge.call("instance_status", "default")) == "ready":
		return true
	_append_log("Python-Instanz startet … (beim ersten Mal wird die venv eingerichtet, das dauert 1-3 Minuten)")
	var res: Variant = await bridge.call("start_instance", "default")
	if res is PythonBridgeResult and (res as PythonBridgeResult).is_ok():
		_append_log("[color=#7fd97f]Python ist bereit.[/color]")
		_sync_instance_label()
		return true
	var message := (res as PythonBridgeResult).error_message() if res is PythonBridgeResult else str(res)
	_append_log("[color=#ff8a80]Start fehlgeschlagen: %s[/color]" % message)
	_set_status("Python-Start fehlgeschlagen")
	return false

func _log_result(res: Variant) -> void:
	if not (res is PythonBridgeResult):
		_append_log("[color=#ff8a80]Keine gültige Antwort: %s[/color]" % str(res))
		_set_status("Ausführung fehlgeschlagen")
		return
	var result := res as PythonBridgeResult
	if result.is_ok():
		var value: Variant = result.value
		_append_log("[color=#7fd97f]ok[/color]" + ("" if value == null else ": " + str(value).substr(0, 600)))
		for stream in ["stdout", "stderr"]:
			var text := str(result.meta.get(stream, "")).strip_edges()
			if text != "":
				_append_log("[color=#9fb3c8]%s:[/color]\n%s" % [stream, text])
		_set_status("Ausführung ok")
	else:
		_append_log("[color=#ff8a80]%s: %s[/color]" % [result.status, result.error_message()])
		var traceback := str(result.error.get("traceback", "")).strip_edges()
		if traceback != "":
			_append_log("[color=#ffb4a2]%s[/color]" % traceback)
		_set_status("Ausführung fehlgeschlagen")

func _sync_instance_label() -> void:
	if _instance_label == null:
		return
	var bridge := _resolve_bridge()
	if bridge == null or not bridge.has_method("instance_status"):
		_instance_label.text = "Python: –"
		return
	var status := str(bridge.call("instance_status", "default"))
	var label := status
	match status:
		"ready":
			_instance_label.add_theme_color_override("font_color", Color(0.55, 0.85, 0.55))
		"none", "stopped":
			label = "nicht gestartet"
			_instance_label.add_theme_color_override("font_color", Color(0.6, 0.63, 0.68))
		_:
			_instance_label.add_theme_color_override("font_color", Color(0.95, 0.8, 0.45))
	_instance_label.text = "Python: " + label

# ================================================================== Mehr-Menü
## PopupMenu-Indizes zählen Separatoren mit, `id_pressed` liefert dagegen die
## IDs - deshalb wird über get_item_index() gearbeitet.
func _sync_more_menu() -> void:
	if _more_menu == null:
		return
	var more := _more_menu.get_popup()
	var editor := _active_editor()
	var is_file := editor != null and str(editor.get_meta("kind", TAB_FILE)) == TAB_FILE
	var cython_index := more.get_item_index(2)
	if cython_index >= 0:
		more.set_item_checked(cython_index, is_file and str(editor.get_meta("ext", "py")) == "pyx")
		more.set_item_disabled(cython_index, not is_file)
	var build_index := more.get_item_index(3)
	if build_index >= 0:
		more.set_item_disabled(build_index, OS.has_feature("web"))
	for menu_id in [4, 5]:
		var item_index := more.get_item_index(menu_id)
		if item_index >= 0:
			more.set_item_disabled(item_index, not is_file)

func _on_more_menu_pressed(id: int) -> void:
	match id:
		0:
			await _generate_wrapper()
		1:
			await _hot_reload()
		2:
			_toggle_cython()
		3:
			await _compile_cython()
		4:
			var editor := _active_editor()
			if editor != null:
				_open_name_dialog(ACT_RENAME, editor, str(editor.get_meta("script_id", "")))
		5:
			var active := _active_editor()
			if active != null:
				request_delete(str(active.get_meta("script_id", "")))
		6:
			_log.clear()
		7:
			open_settings()

# ================================================================== Wrapper / Reload / Cython
func _generate_wrapper() -> void:
	var editor := _active_editor()
	if editor == null or str(editor.get_meta("kind", TAB_FILE)) != TAB_FILE:
		_set_status("keine Datei offen")
		return
	var script_id := str(editor.get_meta("script_id", ""))
	_append_log("[b]GDScript-Wrapper für %s erzeugen …[/b]" % script_id)
	if not await _ensure_instance():
		return
	var bridge := _resolve_bridge()
	var res: Variant = await bridge.call("introspect_script", script_id, "default")
	if not (res is PythonBridgeResult) or not (res as PythonBridgeResult).is_ok():
		_log_result(res)
		return
	var schema: Array = (res as PythonBridgeResult).value if (res as PythonBridgeResult).value is Array else []
	var generated := PythonBridgeWrapperGenerator.generate(schema, script_id)
	if not bool(generated.get("ok", false)):
		_append_log("[color=#ff8a80]Wrapper-Erzeugung fehlgeschlagen: %s[/color]"
			% str(generated.get("error", "unbekannt")))
		return
	_write_wrapper(script_id, str(generated.get("code", "")))

func _write_wrapper(script_id: String, code: String) -> void:
	_sync_dirs()
	var dir := _store.wrappers_dir if _store.wrappers_dir != "" else "res://python_bridge/wrappers"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir.path_join(script_id.get_file() + "_wrapper.gd")
	if FileAccess.file_exists(path) and not PythonBridgeWrapperGenerator.is_generated(path):
		_append_log("[color=#ff8a80]%s ist keine generierte Datei - sie wird nicht überschrieben.[/color]" % path)
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_append_log("[color=#ff8a80]Wrapper nicht schreibbar: %s[/color]" % path)
		return
	file.store_string(code)
	file.close()
	_append_log("[color=#7fd97f]Wrapper geschrieben: %s[/color]" % path)
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()

func _hot_reload() -> void:
	var editor := _active_editor()
	if editor == null or str(editor.get_meta("kind", TAB_FILE)) != TAB_FILE:
		_set_status("keine Datei offen")
		return
	var script_id := str(editor.get_meta("script_id", ""))
	var bridge := _resolve_bridge()
	var res: Variant = await bridge.call("hot_reload_script", script_id)
	if res is PythonBridgeResult and (res as PythonBridgeResult).is_ok():
		_append_log("[color=#7fd97f]Hot Reload: %s[/color]" % script_id)
	else:
		_log_result(res)

## Schaltet den aktiven Tab zwischen .py und .pyx um. Der Inhalt bleibt: der
## Store schreibt die neue Variante und entfernt die alte.
func _toggle_cython() -> void:
	var editor := _active_editor()
	var script_id := str(editor.get_meta("script_id", ""))
	var as_cython := str(editor.get_meta("ext", "py")) != "pyx"
	var write := _store.write(script_id, editor.text, as_cython)
	if not bool(write.get("ok", false)):
		_append_log("[color=#ff8a80]Umschalten fehlgeschlagen: %s[/color]" % str(write.get("error", "")))
		return
	editor.set_meta("ext", str(write.get("ext", "py")))
	_after_write(editor, write)
	_append_log("[color=#c7a3ff]%s ist jetzt ein Cython-Modul (.pyx) - Build beim ersten Aufruf oder über »Cython kompilieren«.[/color]"
		% script_id if as_cython else "[color=#c7a3ff]%s ist wieder ein normales .py-Skript.[/color]" % script_id)
	_sync_more_menu()

func _compile_cython() -> void:
	var bridge := _resolve_bridge()
	if bridge == null or not bridge.has_method("compile_cython"):
		_set_status("compile_cython nicht verfügbar")
		return
	_append_log("[b]Cython-Build läuft (inkrementell) …[/b]")
	_set_status("Cython-Build läuft …")
	var res: Variant = await bridge.call("compile_cython", "", false)
	if res is PythonBridgeResult and (res as PythonBridgeResult).is_ok():
		var report: Dictionary = (res as PythonBridgeResult).value if (res as PythonBridgeResult).value is Dictionary else {}
		_append_log("[color=#7fd97f]cython ok: built=%s skipped=%s compiler=%s (%ss)[/color]"
			% [report.get("built", []), report.get("skipped", []), report.get("compiler", "?"), report.get("duration_s", "?")])
		_set_status("Cython-Build fertig")
	else:
		_log_result(res)

# ================================================================== Poll
## Wird vom Plugin in jedem Editor-Frame aufgerufen. Aktualisiert in einem
## Sekundentakt Instanz-Status, externe Dateiänderungen und die Skriptliste.
func editor_poll() -> void:
	_ensure_ui()
	var now := Time.get_ticks_msec()
	if now - _last_poll_ms < POLL_INTERVAL_MS:
		return
	_last_poll_ms = now
	_sync_instance_label()
	_check_external_changes()
	if now - _last_list_ms >= LIST_REFRESH_MS:
		_last_list_ms = now
		if visible:
			refresh_scripts(true)

## Erkennt Änderungen durch einen externen Editor. Ungespeicherte Tabs werden
## NICHT überschrieben (nur gemeldet) - kein stiller Datenverlust.
func _check_external_changes() -> void:
	if _tabs == null:
		return
	for i in _tabs.get_tab_count():
		var editor := _tabs.get_child(i) as CodeEdit
		if editor == null or str(editor.get_meta("kind", TAB_FILE)) != TAB_FILE:
			continue
		var script_id := str(editor.get_meta("script_id", ""))
		var disk_mtime := _store.mtime(script_id)
		if disk_mtime < 0 or disk_mtime == int(editor.get_meta("mtime", -1)):
			continue
		editor.set_meta("mtime", disk_mtime)
		var read := _store.read(script_id)
		if not bool(read.get("ok", false)):
			continue
		var text := str(read.get("text", ""))
		if text == editor.text:
			_set_saved_text(editor, text)
			_update_tab_title(editor)
			continue
		if _is_dirty(editor):
			_append_log("[color=#ffd166]%s wurde extern geändert - der Tab hat ungespeicherte Änderungen und bleibt unangetastet.[/color]"
				% _tab_display_name(editor))
			continue
		var caret_line := editor.get_caret_line()
		editor.text = text
		_set_saved_text(editor, text)
		_clear_highlighter_cache(editor)
		editor.set_caret_line(mini(caret_line, maxi(0, editor.get_line_count() - 1)))
		_update_tab_title(editor)
		_append_log("[color=#7fd9ff]%s wurde extern geändert und neu geladen.[/color]" % _tab_display_name(editor))
