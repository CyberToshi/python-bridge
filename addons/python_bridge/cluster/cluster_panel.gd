class_name ClusterPanel
extends Control
## Dunkle, einfache Cluster-Oberflaeche fuer den **Hauptrechner** (V1).
##
## Die Oberflaeche ist bewusst kinderleicht gehalten:
##
##   * oben der Zustand (wie viele Worker sind da),
##   * links die automatisch erkannten Rechner,
##   * rechts Aufgaben erstellen + Verlauf,
##   * unten das Protokoll.
##
## Sie bringt ihren eigenen ClusterManager mit: Wer nur diese Node in eine Szene
## haengt, hat sofort ein funktionierendes System (Discovery startet mit).
## Alternativ kann ein vorhandener Manager ueber `manager_path` gesetzt werden.

const BG := Color("#14161c")
const PANEL := Color("#1c1f28")
const PANEL_HI := Color("#232735")
const BORDER := Color("#2e3444")
const TEXT := Color("#e8ecf5")
const MUTED := Color("#98a2b8")
const ACCENT := Color("#4c8dff")
const GOOD := Color("#39d98a")
const WARN := Color("#f5c451")
const BAD := Color("#ff6b6b")

## Optionaler Pfad zu einem vorhandenen ClusterManager. Leer = eigener Manager.
@export var manager_path: NodePath
## Panel-Hoehe im Fenster (nur wenn das Panel frei steht).
@export var compact: bool = false

var manager: ClusterManager

var _status_label: Label
var _status_dot: PanelContainer
var _worker_box: VBoxContainer
var _task_tree: Tree
var _log_view: TextEdit
var _worker_count_label: Label
var _invite_box: VBoxContainer

var _script_path: LineEdit
var _mode_label: Label
## Ausgewaehlter Projektordner ("" = einzelne Datei).
var _project_dir: String = ""
## Ausgewaehlte Eingabedateien (grosse Dateien laufen ueber den Datei-Transfer).
var _input_files: Array[String] = []
var _data_label: Label
var _transfer_label: Label
var _command: OptionButton
var _function: LineEdit
var _args: LineEdit
var _input_json: TextEdit
var _priority: OptionButton
var _target: OptionButton

var _show_metrics := true
var _show_log := true
var _show_tasks := true
var _tasks_panel: Control
var _log_panel: Control
var _log_lines: Array[String] = []
var _event_index := 0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	manager = _resolve_manager()
	_build_ui()
	_connect_manager()
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(_refresh)
	add_child(timer)
	_refresh()


func _resolve_manager() -> ClusterManager:
	if manager_path != NodePath():
		var found := get_node_or_null(manager_path)
		if found is ClusterManager:
			return found
	for child in get_children():
		if child is ClusterManager:
			return child
	# Kein Manager vorhanden: selbst einen erzeugen (ein Node = fertig).
	var created := ClusterManager.new()
	created.name = "ClusterManager"
	add_child(created)
	return created


func _connect_manager() -> void:
	if manager == null:
		return
	manager.log_event.connect(_on_log)
	manager.worker_discovered.connect(_on_worker_discovered)
	manager.worker_needs_token.connect(_on_worker_needs_token)
	manager.task_finished.connect(_on_task_finished)
	manager.task_progress.connect(_on_task_progress)
	manager.worker_connected.connect(func(_id: String) -> void: _refresh())
	manager.worker_disconnected.connect(func(_id: String, _r: String) -> void: _refresh())
	manager.tls_problem.connect(_on_tls_problem)
	manager.file_transfer_progress.connect(_on_transfer_progress)
	manager.file_transfer_finished.connect(_on_transfer_finished)


# ---------------------------------------------------------------- Aufbau
func _build_ui() -> void:
	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("margin_left", 16)
	root.add_theme_constant_override("margin_right", 16)
	root.add_theme_constant_override("margin_top", 14)
	root.add_theme_constant_override("margin_bottom", 14)
	add_child(root)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	root.add_child(column)

	column.add_child(_build_header())

	var middle := HSplitContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.split_offset = 380
	column.add_child(middle)

	middle.add_child(_build_workers_card())
	middle.add_child(_build_right_side())

	_log_panel = _build_log_card()
	column.add_child(_log_panel)


func _build_header() -> Control:
	var card := _card()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	card.add_child(_padded(box))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)

	var title := _label("Cluster", TEXT, 22, true)
	row.add_child(title)

	_status_dot = PanelContainer.new()
	_status_dot.custom_minimum_size = Vector2(14, 14)
	row.add_child(_status_dot)
	_status_label = _label("startet ...", MUTED, 13)
	row.add_child(_status_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_worker_count_label = _label("0 Worker", MUTED, 13)
	row.add_child(_worker_count_label)

	# Ansicht-Schalter (der Nutzer soll Anzeigen ein-/ausschalten koennen).
	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 14)
	box.add_child(toggles)
	_add_toggle(toggles, "Metriken", true, func(on: bool) -> void:
		_show_metrics = on
		_refresh())
	_add_toggle(toggles, "Aufgaben", true, func(on: bool) -> void:
		_show_tasks = on
		if _tasks_panel != null:
			_tasks_panel.visible = on)
	_add_toggle(toggles, "Protokoll", true, func(on: bool) -> void:
		_show_log = on
		if _log_panel != null:
			_log_panel.visible = on)
	# TLS: bewusste Freigabe selbstsignierter Zertifikate. Ohne sie scheitert ein
	# verschluesselter Worker **sichtbar** - es wird nichts stillschweigend
	# herabgesetzt.
	_add_toggle(toggles, "Selbstsignierte Zertifikate erlauben",
		manager != null and manager.tls_allow_self_signed,
		func(on: bool) -> void:
			if manager != null:
				manager.set_tls_allow_self_signed(on))
	return card


func _build_workers_card() -> Control:
	var card := _card()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	card.add_child(_padded(box))

	box.add_child(_label("Rechner im Netz", TEXT, 15, true))
	box.add_child(_hint("Automatisch erkannt. Kein Eintragen noetig."))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_worker_box = VBoxContainer.new()
	_worker_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_worker_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_worker_box)

	box.add_child(_hint("Hilft der Broadcast nicht (Gastnetz), hier direkt eintragen:"))
	var manual := HBoxContainer.new()
	manual.add_theme_constant_override("separation", 8)
	box.add_child(manual)
	var url := LineEdit.new()
	# Schema bewusst als wss:// vormachen: nur so passt der Eintrag zu einem
	# Worker, den die App standardmaessig verschluesselt startet (ws:// scheitert).
	url.placeholder_text = "wss://192.168.1.42:8765"
	url.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_input(url)
	manual.add_child(url)
	var token := LineEdit.new()
	token.placeholder_text = "Token"
	token.custom_minimum_size = Vector2(120, 0)
	_style_input(token)
	manual.add_child(token)
	manual.add_child(_button("Hinzufuegen", func() -> void:
		var id := manager.add_worker(url.text.strip_edges(), token.text.strip_edges())
		if id != "":
			_on_log("Worker %s manuell hinzugefuegt." % id)
			url.text = ""
			token.text = ""
			_refresh()))
	return card


func _build_right_side() -> Control:
	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 12)

	var task_card := _card()
	_tasks_panel = task_card
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	task_card.add_child(_padded(box))

	box.add_child(_label("Aufgabe starten", TEXT, 15, true))
	box.add_child(_hint("Datei oder ganzen Projektordner waehlen - der Code wird "
		+ "zum Rechner uebertragen. Cython (.pyx) wird dort automatisch gebaut."))

	var file_row := HBoxContainer.new()
	file_row.add_theme_constant_override("separation", 8)
	box.add_child(file_row)
	_script_path = LineEdit.new()
	_script_path.placeholder_text = "Datei oder Projektordner"
	_script_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_input(_script_path)
	file_row.add_child(_script_path)
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.py ; Python"])
	dialog.use_native_dialog = true
	file_row.add_child(dialog)
	file_row.add_child(_button("Datei", func() -> void:
		dialog.popup_centered(Vector2i(680, 460))))
	dialog.file_selected.connect(func(path: String) -> void:
		_script_path.text = path
		_project_dir = ""
		_update_mode_label())

	# Projektordner: alle Python-Dateien werden mitgeschickt; der Worker
	# kuemmert sich um Umgebung und Build.
	var dir_dialog := FileDialog.new()
	dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dir_dialog.access = FileDialog.ACCESS_FILESYSTEM
	dir_dialog.use_native_dialog = true
	file_row.add_child(dir_dialog)
	file_row.add_child(_button("Projektordner", func() -> void:
		dir_dialog.popup_centered(Vector2i(680, 460))))
	dir_dialog.dir_selected.connect(func(path: String) -> void:
		_project_dir = path
		_script_path.text = path
		_update_mode_label())
	_mode_label = _hint("Modus: einzelne Datei")
	box.add_child(_mode_label)

	var options := HBoxContainer.new()
	options.add_theme_constant_override("separation", 8)
	box.add_child(options)
	_command = OptionButton.new()
	_command.add_item("run (input -> result)", 0)
	_command.add_item("call (Funktion)", 1)
	_style_input(_command)
	_command.item_selected.connect(func(_i: int) -> void: _update_command_ui())
	options.add_child(_command)
	_function = LineEdit.new()
	_function.placeholder_text = "Funktionsname"
	_function.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_input(_function)
	options.add_child(_function)
	_args = LineEdit.new()
	_args.placeholder_text = 'Argumente JSON, z. B. ["Hallo"]'
	_args.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_input(_args)
	options.add_child(_args)

	# Eingabedateien: grosse Dateien werden NICHT in den Auftrag gepackt, sondern
	# als Chunks uebertragen und mit SHA-256 geprueft (siehe Datei-Registry).
	box.add_child(_hint("Eingabedateien (werden zum Rechner uebertragen):"))
	var files_row := HBoxContainer.new()
	files_row.add_theme_constant_override("separation", 8)
	box.add_child(files_row)
	_data_label = _label("keine Datei gewaehlt", MUTED, 12)
	_data_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_data_label.clip_text = true
	files_row.add_child(_data_label)
	var input_dialog := FileDialog.new()
	input_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	input_dialog.access = FileDialog.ACCESS_FILESYSTEM
	input_dialog.use_native_dialog = true
	input_dialog.title = "Eingabedateien waehlen"
	files_row.add_child(input_dialog)
	files_row.add_child(_button("Dateien", func() -> void:
		input_dialog.popup_centered(Vector2i(760, 520))))
	files_row.add_child(_button("leeren", func() -> void:
		_input_files.clear()
		_update_data_label()))
	input_dialog.files_selected.connect(func(paths: PackedStringArray) -> void:
		for path in paths:
			if not _input_files.has(path):
				_input_files.append(path)
		_update_data_label())

	box.add_child(_hint("Eingabe fuer 'run' (JSON, wird zu `input`):"))
	_input_json = TextEdit.new()
	_input_json.custom_minimum_size = Vector2(0, 64)
	_input_json.placeholder_text = '{"werte": [1, 2, 3]}'
	_style_text_area(_input_json)
	box.add_child(_input_json)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	box.add_child(bottom)
	_priority = OptionButton.new()
	_priority.add_item("NORMAL", OrchestratorTask.Priority.NORMAL)
	_priority.add_item("HOCH", OrchestratorTask.Priority.HIGH)
	_priority.add_item("NIEDRIG", OrchestratorTask.Priority.LOW)
	_priority.select(0)
	_style_input(_priority)
	bottom.add_child(_priority)
	_target = OptionButton.new()
	_target.add_item("Automatisch", 0)
	_style_input(_target)
	bottom.add_child(_target)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	bottom.add_child(_button("Aufgabe starten", _submit_task, ACCENT))

	side.add_child(task_card)

	var task_list_card := _card()
	task_list_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var list_box := VBoxContainer.new()
	list_box.add_theme_constant_override("separation", 6)
	task_list_card.add_child(_padded(list_box))
	list_box.add_child(_label("Aufgaben", TEXT, 15, true))
	# Fortschritt grosser Eingaben sichtbar machen (sonst wartet die Aufgabe
	# scheinbar grundlos).
	_transfer_label = _label("", MUTED, 12)
	list_box.add_child(_transfer_label)
	_task_tree = Tree.new()
	_task_tree.columns = 7
	_task_tree.hide_root = true
	_task_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_task_tree.custom_minimum_size = Vector2(0, 120)
	_task_tree.set_column_title(0, "Aufgabe")
	_task_tree.set_column_title(1, "Status")
	_task_tree.set_column_title(2, "Fortschritt")
	_task_tree.set_column_title(3, "Rechner")
	_task_tree.set_column_title(4, "Versuch")
	_task_tree.set_column_title(5, "Build")
	_task_tree.set_column_title(6, "Ergebnis")
	_task_tree.add_theme_color_override("font_color", TEXT)
	_task_tree.add_theme_color_override("title_button_color", MUTED)
	list_box.add_child(_task_tree)
	side.add_child(task_list_card)

	_invite_box = VBoxContainer.new()
	_invite_box.add_theme_constant_override("separation", 4)
	list_box.add_child(_invite_box)
	_update_command_ui()
	return side


func _build_log_card() -> Control:
	var card := _card()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	card.add_child(_padded(box))
	box.add_child(_label("Protokoll", TEXT, 15, true))
	_log_view = TextEdit.new()
	_log_view.editable = false
	_log_view.custom_minimum_size = Vector2(0, 140)
	_style_text_area(_log_view)
	box.add_child(_log_view)
	if compact:
		card.custom_minimum_size = Vector2(0, 160)
	return card


# ---------------------------------------------------------------- Aktionen
func _submit_task() -> void:
	var path := _script_path.text.strip_edges()
	if path == "":
		_on_log("Bitte zuerst eine Datei oder einen Projektordner waehlen.")
		return
	var args: Variant = JSON.parse_string(_args.text.strip_edges()) if _args.text.strip_edges() != "" else []
	if not (args is Array):
		_on_log("Argumente muessen ein JSON-Array sein, z. B. [\"Hallo\"]")
		return
	var input_data: Variant = {}
	if _input_json.text.strip_edges() != "":
		input_data = JSON.parse_string(_input_json.text.strip_edges())
		if not (input_data is Dictionary):
			_on_log("Eingabe muss ein JSON-Objekt sein, z. B. {\"werte\": [1,2]}")
			return
	var target := ""
	if _target.selected > 0:
		target = str(_target.get_item_metadata(_target.selected))
	# Achtung: `add_item(text, id)` setzt die **ID**, nicht die Metadaten. Der
	# Prioritaetswert steckt deshalb in `get_item_id` - `get_item_metadata`
	# wuerde null liefern und die Aufgabe scheitern lassen.
	var priority := OrchestratorTask.Priority.NORMAL
	if _priority.selected >= 0:
		priority = _priority.get_item_id(_priority.selected)
	var options := {
		"command": "run" if _command.selected == 0 else "call",
		"function": _function.text.strip_edges(),
		"args": args,
		"input": input_data,
		"priority": priority,
		"target": target,
	}
	# Projektordner: Code wird mitgeschickt, der Worker baut selbst (Cython).
	if _project_dir != "":
		options["script"] = _project_dir.get_file()
	var task_id := ""
	if not _input_files.is_empty():
		# Mit Eingabedateien: die Aufgabe startet erst, wenn alle Daten
		# verifiziert auf dem Rechner liegen (WAITING_FOR_DATA).
		if _project_dir != "":
			var project_files := manager.collect_project_dir(_project_dir)
			options["files"] = project_files
			options["entry"] = manager.guess_entry(project_files)
		task_id = manager.submit_with_files(options, _input_files)
	elif _project_dir != "":
		task_id = manager.submit_project_dir(_project_dir, options)
	else:
		task_id = manager.submit_script_file(path, options)
	if task_id == "":
		_on_log("Aufgabe konnte nicht erstellt werden.")
	else:
		_on_log("Aufgabe %s gestartet%s." % [task_id,
			" (mit %d Eingabedatei(en))" % _input_files.size() if not _input_files.is_empty() else ""])
	_refresh()


## Anzeige der gewaehlten Eingabedateien (kurz, mit Groesse).
func _update_data_label() -> void:
	if _data_label == null:
		return
	if _input_files.is_empty():
		_data_label.text = "keine Datei gewaehlt"
		return
	var names: Array[String] = []
	var total := 0
	for path in _input_files:
		names.append(path.get_file())
		# Nur die Groesse lesen: eine 2-GB-Datei darf nicht in den Speicher.
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			total += file.get_length()
			file.close()
	_data_label.text = "%d Datei(en), %s: %s" % [names.size(),
		_human_bytes(total), ", ".join(names)]


static func _human_bytes(value: int) -> String:
	if value >= 1024 * 1024:
		return "%.1f MB" % (value / 1048576.0)
	if value >= 1024:
		return "%.0f KB" % (value / 1024.0)
	return "%d B" % value


## Laufender Datei-Transfer: Progressbalken aus Textzeichen (kein extra Widget).
func _on_transfer_progress(server_id: String, file_id: String, sent: int, total: int) -> void:
	if _transfer_label == null:
		return
	var fraction := 0.0
	if total > 0:
		fraction = clampf(float(sent) / float(total), 0.0, 1.0)
	var filled := int(fraction * 20.0)
	_transfer_label.text = "Transfer %s: [%s%s] %d %% -> %s" % [
		manager.file_registry.name_of(file_id),
		"#".repeat(filled), "-".repeat(maxi(20 - filled, 0)),
		int(fraction * 100.0), server_id]


func _on_transfer_finished(server_id: String, file_id: String, ok: bool, reason: String) -> void:
	if _transfer_label == null:
		return
	_transfer_label.text = ("Transfer %s fertig (%s)." % [manager.file_registry.name_of(file_id), server_id]
		if ok else "Transfer %s fehlgeschlagen: %s" % [manager.file_registry.name_of(file_id), reason])
	_on_log(_transfer_label.text)
	_refresh()


func _update_mode_label() -> void:
	if _mode_label == null:
		return
	if _project_dir != "":
		_mode_label.text = "Modus: Projektordner (alle Python-Dateien, Build automatisch)"
	else:
		_mode_label.text = "Modus: einzelne Datei"


func _update_command_ui() -> void:
	var is_call := _command != null and _command.selected == 1
	if _function != null:
		_function.editable = is_call
	if _args != null:
		_args.editable = is_call
	if _input_json != null:
		_input_json.editable = not is_call


# ---------------------------------------------------------------- Refresh
func _refresh() -> void:
	if manager == null:
		return
	_refresh_status()
	_refresh_workers()
	_refresh_tasks()
	_refresh_log()


func _refresh_status() -> void:
	var connected := manager.connected_worker_count()
	var total := manager.worker_count()
	_worker_count_label.text = "%d von %d Rechnern verbunden" % [connected, total]
	if connected > 0:
		_set_dot(GOOD)
		_status_label.text = "bereit"
		_status_label.add_theme_color_override("font_color", TEXT)
	elif total > 0:
		_set_dot(WARN)
		_status_label.text = "Rechner gefunden - warte auf Verbindung"
	else:
		_set_dot(MUTED)
		_status_label.text = "suche Rechner im Netz ..."


func _set_dot(color: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.corner_radius_top_left = 7
	sb.corner_radius_top_right = 7
	sb.corner_radius_bottom_left = 7
	sb.corner_radius_bottom_right = 7
	_status_dot.add_theme_stylebox_override("panel", sb)


func _refresh_workers() -> void:
	for child in _worker_box.get_children():
		child.queue_free()
	_target.clear()
	_target.add_item("Automatisch", 0)
	var snapshot := manager.workers_snapshot()
	if snapshot.is_empty():
		_worker_box.add_child(_hint("Noch kein Rechner gefunden.\n\n" +
			"Auf dem anderen PC die Worker-App starten - er meldet sich automatisch."))
		return
	for entry in snapshot:
		_worker_box.add_child(_worker_row(entry))
		if bool(entry.get("connected", false)):
			_target.add_item(str(entry.get("name", entry.get("server_id", ""))))
			_target.set_item_metadata(_target.item_count - 1, str(entry.get("server_id", "")))


func _worker_row(entry: Dictionary) -> Control:
	var row := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_HI
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = BORDER
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	row.add_theme_stylebox_override("panel", sb)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	row.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	box.add_child(head)
	var dot := PanelContainer.new()
	dot.custom_minimum_size = Vector2(12, 12)
	var dsb := StyleBoxFlat.new()
	dsb.bg_color = _state_color(int(entry.get("state", -1)), bool(entry.get("connected", false)))
	dsb.corner_radius_top_left = 6
	dsb.corner_radius_top_right = 6
	dsb.corner_radius_bottom_left = 6
	dsb.corner_radius_bottom_right = 6
	dot.add_theme_stylebox_override("panel", dsb)
	head.add_child(dot)
	head.add_child(_label(str(entry.get("name", "?")), TEXT, 14, true))
	head.add_child(_label(str(entry.get("state_text", "")), MUTED, 12))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	if not bool(entry.get("has_token", false)):
		head.add_child(_button("Token", func() -> void:
			_prompt_token(str(entry.get("server_id", "")), str(entry.get("name", "")))))

	var url := str(entry.get("url", ""))
	box.add_child(_label(url if url != "" else str(entry.get("server_id", "")), MUTED, 12))
	box.add_child(_tls_line(entry))
	if _show_metrics:
		box.add_child(_label(
			"CPU %.0f %%   RAM %.0f %%   Latenz %.0f ms   Queue %d/%d" % [
				float(entry.get("cpu", 0.0)), float(entry.get("ram", 0.0)),
				float(entry.get("latency", 0.0)), int(entry.get("queue_used", 0)),
				int(entry.get("queue_capacity", 0))], MUTED, 12))
	return row


## Eine Zeile je Worker: ist die Verbindung verschluesselt, und wie stark ist
## das Vertrauen? Bei wss ohne Pruefung wird das ausdruecklich gesagt - eine
## "sichere" Anzeige ohne Deckung waere schlimmer als gar keine.
func _tls_line(entry: Dictionary) -> Control:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	var secure := bool(entry.get("secure", false))
	var label := str(entry.get("tls", ""))
	var color := MUTED
	var text := "Ohne Verschluesselung (ws://)"
	if secure:
		match label:
			"geprueft":
				color = GOOD
				text = "TLS, Zertifikat angeheftet und geprueft"
			"verschluesselt":
				color = WARN
				text = "TLS, verschluesselt (Zertifikat nicht geprueft)"
			_:
				color = WARN
				text = "TLS, Systemvertrauen (selbstsigniert scheitert)"
	line.add_child(_label(text, color, 12))
	var fingerprint := str(entry.get("fingerprint", ""))
	if fingerprint != "":
		line.add_child(_label("SHA-256 %s" % fingerprint.substr(0, 16).to_lower()
			+ "...", MUTED, 11))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(spacer)
	if secure:
		line.add_child(_button("Zertifikat", func() -> void:
			_pick_ca(str(entry.get("server_id", "")), str(entry.get("name", "")))))
	return line


## Vertrauensdatei (PEM) des Workers auswaehlen -> echte Zertifikatspruefung.
func _pick_ca(server_id: String, name: String) -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.pem,*.crt,*.cer ; Zertifikat"])
	dialog.use_native_dialog = true
	dialog.title = "Zertifikat von %s waehlen" % (name if name != "" else server_id)
	add_child(dialog)
	dialog.file_selected.connect(func(path: String) -> void:
		manager.set_worker_ca(server_id, path)
		_refresh())
	dialog.popup_centered(Vector2i(680, 460))


func _refresh_tasks() -> void:
	if _task_tree == null:
		return
	_task_tree.clear()
	var root := _task_tree.create_item()
	for task_id in manager.task_ids():
		var snapshot := manager.task_snapshot(task_id)
		if snapshot.is_empty():
			continue
		var item := _task_tree.create_item(root)
		item.set_text(0, str(snapshot.get("script", task_id))
			+ ("  (Projekt)" if bool(snapshot.get("is_project", false)) else ""))
		item.set_text(1, str(snapshot.get("state_text", "?")))
		# Fortschritt: Stufe (Umgebung/Build/Lauf) + Prozent.
		var stage := str(snapshot.get("stage", ""))
		var fraction := float(snapshot.get("progress", 0.0))
		if int(snapshot.get("state", 0)) in [OrchestratorTask.State.COMPLETED,
				OrchestratorTask.State.FAILED, OrchestratorTask.State.CANCELLED]:
			item.set_text(2, "100 %" if int(snapshot.get("state", 0)) \
				== OrchestratorTask.State.COMPLETED else "")
		elif int(snapshot.get("state", 0)) == OrchestratorTask.State.WAITING_FOR_DATA:
			# Ohne diesen Hinweis sieht die Aufgabe aus, als haenge sie.
			item.set_text(2, "Daten werden uebertragen")
			item.set_custom_color(2, WARN)
		elif stage != "":
			item.set_text(2, "%s  %d %%%" % [stage, int(fraction * 100.0)])
		else:
			item.set_text(2, "wartet")
		item.set_text(3, str(snapshot.get("server", "")))
		item.set_text(4, "%d/%d" % [int(snapshot.get("attempts", 0)),
			int(snapshot.get("max_retries", 0)) + 1])
		var build: Dictionary = snapshot.get("build", {})
		if build.is_empty():
			item.set_text(5, "")
		elif bool(build.get("cached", false)):
			item.set_text(5, "Cache")
		elif bool(build.get("built", false)):
			item.set_text(5, "neu gebaut")
		else:
			item.set_text(5, "")
		var error := str(snapshot.get("error", ""))
		var hint := str(snapshot.get("error_hint", ""))
		var result = snapshot.get("result", null)
		if error != "":
			item.set_text(6, error)
			item.set_tooltip_text(6, error if hint == "" else "%s\n\nLoesung: %s" % [error, hint])
		else:
			item.set_text(6, str(result) if result != null else "")
		item.set_custom_color(1, _task_color(int(snapshot.get("state", 0))))


## Das Protokoll hat **eine** Quelle: das Manager-Ereignislog plus die direkt
## gemeldeten Zeilen. Beide werden hier zusammengefuehrt, damit sich nichts
## gegenseitig ueberschreibt.
func _refresh_log() -> void:
	if _log_view == null:
		return
	var events := manager.event_log()
	if events.size() > _event_index:
		for i in range(_event_index, events.size()):
			_log_lines.append(events[i])
		_event_index = events.size()
		_render_log()


func _on_log(text: String) -> void:
	_log_lines.append(text)
	_render_log()


func _render_log() -> void:
	if _log_view == null:
		return
	while _log_lines.size() > 400:
		_log_lines.remove_at(0)
	_log_view.text = "\n".join(_log_lines)
	_log_view.set_caret_line(_log_view.get_line_count())


## TLS-Problem (z. B. selbstsigniertes Zertifikat ohne Freigabe): der Benutzer
## bekommt einen Satz mit Loesung statt eines stillen Reconnects.
func _on_tls_problem(server_id: String, hint: String) -> void:
	_on_log("TLS bei %s: %s" % [server_id, hint])
	_refresh()


func _on_worker_discovered(server_id: String, _info: Dictionary) -> void:
	_refresh()


func _on_worker_needs_token(server_id: String, info: Dictionary) -> void:
	_on_log("Rechner %s gefunden - Token noetig." % str(info.get("name", server_id)))
	_refresh()


func _on_task_finished(task_id: String, ok: bool, value: Variant, error: String) -> void:
	if ok:
		_on_log("Aufgabe %s fertig: %s" % [task_id, str(value)])
	else:
		# Der Text des Workers enthaelt bereits einen Loesungshinweis.
		_on_log("Aufgabe %s fehlgeschlagen: %s" % [task_id, error.replace("\n", " | ")])
	_refresh()


func _on_task_progress(task_id: String, stage: String, _fraction: float, text: String) -> void:
	if text != "":
		_on_log("Aufgabe %s [%s] %s" % [task_id, stage, text])
	_refresh()


func _prompt_token(server_id: String, name: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Token fuer %s" % name
	dialog.dialog_text = "Auf dem Rechner in der Worker-App angezeigtes Token eingeben:"
	var edit := LineEdit.new()
	edit.custom_minimum_size = Vector2(360, 0)
	dialog.add_child(edit)
	dialog.register_text_enter(edit)
	dialog.confirmed.connect(func() -> void:
		manager.set_worker_token(server_id, edit.text.strip_edges()))
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	dialog.confirmed.connect(func() -> void: dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()


# ---------------------------------------------------------------- UI-Helfer
func _card() -> PanelContainer:
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL
	sb.corner_radius_top_left = 14
	sb.corner_radius_top_right = 14
	sb.corner_radius_bottom_left = 14
	sb.corner_radius_bottom_right = 14
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = BORDER
	card.add_theme_stylebox_override("panel", sb)
	return card


func _padded(inner: Control) -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.add_child(inner)
	return margin


func _label(text: String, color: Color, size: int, bold := false) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	if bold:
		label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.4))
	return label


func _hint(text: String) -> Label:
	var label := _label(text, MUTED, 12)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _button(text: String, action: Callable, color := PANEL_HI) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	for state in ["normal", "hover", "pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		match state:
			"normal":
				sb.bg_color = color
			"hover":
				sb.bg_color = color.lightened(0.12)
			"pressed":
				sb.bg_color = color.darkened(0.15)
			_:
				sb.bg_color = Color(0, 0, 0, 0)
		sb.corner_radius_top_left = 10
		sb.corner_radius_top_right = 10
		sb.corner_radius_bottom_left = 10
		sb.corner_radius_bottom_right = 10
		sb.content_margin_left = 14
		sb.content_margin_right = 14
		sb.content_margin_top = 7
		sb.content_margin_bottom = 7
		button.add_theme_stylebox_override(state, sb)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", TEXT)
	button.add_theme_color_override("font_pressed_color", TEXT)
	button.pressed.connect(action)
	return button


func _add_toggle(parent: HBoxContainer, text: String, active: bool,
		changed: Callable) -> void:
	var box := CheckBox.new()
	box.text = text
	box.button_pressed = active
	box.focus_mode = Control.FOCUS_NONE
	box.add_theme_color_override("font_color", MUTED)
	box.add_theme_color_override("font_hover_color", TEXT)
	box.toggled.connect(changed)
	parent.add_child(box)


func _style_input(control: Control) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = BORDER
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	control.add_theme_stylebox_override("normal", sb)
	var focus := sb.duplicate() as StyleBoxFlat
	focus.border_color = ACCENT
	control.add_theme_stylebox_override("focus", focus)
	if control is LineEdit:
		control.add_theme_color_override("font_color", TEXT)
		control.add_theme_color_override("font_placeholder_color", MUTED)
	elif control is OptionButton:
		control.add_theme_color_override("font_color", TEXT)


func _style_text_area(area: TextEdit) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = BORDER
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	area.add_theme_stylebox_override("normal", sb)
	area.add_theme_stylebox_override("read_only", sb)
	area.add_theme_color_override("font_color", TEXT)
	area.add_theme_color_override("font_readonly_color", MUTED)


static func _state_color(state: int, connected: bool) -> Color:
	if not connected:
		return BAD
	match state:
		OrchestratorServer.NodeState.READY:
			return GOOD
		OrchestratorServer.NodeState.LIMITED:
			return WARN
		OrchestratorServer.NodeState.BLOCKED:
			return BAD
		OrchestratorServer.NodeState.UNRESPONSIVE:
			return WARN
	return MUTED


static func _task_color(state: int) -> Color:
	match state:
		OrchestratorTask.State.COMPLETED:
			return GOOD
		OrchestratorTask.State.FAILED:
			return BAD
		OrchestratorTask.State.CANCELLED:
			return MUTED
		OrchestratorTask.State.RUNNING:
			return ACCENT
		OrchestratorTask.State.RETRYING:
			return WARN
	return TEXT
