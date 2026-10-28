extends SceneTree
## Editor-Verifikation im echten Editor-Kontext (Dock, Tabs, Highlighter,
## Hot-Reload-Robustheit).
## Run: godot --headless --editor --path . --script res://tests/gdscript/verify_editor.gd

func _initialize() -> void:
	await process_frame
	await process_frame
	var ok := true

	# 1) Autoload-Singleton muss existieren.
	var pb := root.get_node_or_null("PythonBridge")
	if pb == null:
		_print_fail("autoload PythonBridge fehlt")
		ok = false
	else:
		print("[VERIFY] OK: autoload PythonBridge vorhanden (", pb.get_script().resource_path, ")")

	# 2) Das Dock muss im Editor UI hängen und aufgebaut sein.
	var panel := _find_named(root, "Python Bridge")
	if panel == null:
		_print_fail("Dock 'Python Bridge' nicht gefunden")
		_print_result(false)
		quit(1)
		return
	print("[VERIFY] OK: Dock gefunden unter ", str(panel).get_slice(":", 1))

	var file_list := _find_class(panel, "ItemList") as ItemList
	var tabs := _find_class(panel, "TabContainer") as TabContainer
	var log_view := _find_class(panel, "RichTextLabel") as RichTextLabel
	if file_list != null and tabs != null and log_view != null:
		print("[VERIFY] OK: UI aufgebaut (Skriptliste + Tabs + Log)")
	else:
		_print_fail("UI unvollständig (Liste=%s Tabs=%s Log=%s)" % [file_list, tabs, log_view])
		ok = false

	# 3) Plugin ist aktiviert.
	var plugins: PackedStringArray = ProjectSettings.get_setting("editor_plugins/enabled", [])
	if "res://addons/python_bridge/plugin.cfg" in plugins:
		print("[VERIFY] OK: Plugin in editor_plugins aktiviert")
	else:
		_print_fail("Plugin nicht aktiviert: " + str(plugins))
		ok = false

	# 4) Temporäres Skript anlegen: Tab + CodeEdit + Highlighter müssen da sein.
	var editor: CodeEdit = null
	if panel.has_method("new_scratch"):
		editor = panel.new_scratch()
		editor.text = "def add(a, b):\n    return a + b  # sum\n"
		if tabs != null and tabs.get_tab_count() == 1:
			print("[VERIFY] OK: Scratch-Tab angelegt (", tabs.get_tab_title(0), ")")
		else:
			_print_fail("Scratch-Tab fehlt")
			ok = false
		var highlighter: Variant = (_find_class(panel, "CodeEdit") as CodeEdit).syntax_highlighter
		if highlighter is PythonBridgeSyntaxHighlighter:
			var regions: Dictionary = (highlighter as PythonBridgeSyntaxHighlighter).highlight_line("x = 1  # note")
			var comment_start := "x = 1  # note".find("#")
			if regions.has(comment_start):
				print("[VERIFY] OK: Python-Highlighter aktiv (Kommentar-Region bei Spalte ", comment_start, ")")
			else:
				_print_fail("Highlighter setzt keine Kommentar-Region")
				ok = false
		else:
			_print_fail("CodeEdit hat keinen Python-Highlighter")
			ok = false

		# 4b) Der Highlighter muss auch über die echte Virtual-Methode
		#     (TextEdit -> Zeilen) korrekt einfärben, inkl. Docstring-Zustand.
		if highlighter is PythonBridgeSyntaxHighlighter:
			var hl := highlighter as PythonBridgeSyntaxHighlighter
			hl.invalidate()
			editor.text = "doc = \"\"\"a\nb\n\"\"\"\nx = 42  # done\n"
			var inside: Dictionary = hl._get_line_syntax_highlighting(1)
			var after: Dictionary = hl._get_line_syntax_highlighting(3)
			var inside_ok: bool = inside.has(0) \
				and inside[0]["color"] == PythonBridgeSyntaxHighlighter.COL_STRING
			var after_ok: bool = after.has(4) \
				and after[4]["color"] == PythonBridgeSyntaxHighlighter.COL_NUMBER \
				and after.has(8)
			if inside_ok and after_ok:
				print("[VERIFY] OK: Highlighting über die echte Virtual-Methode (Docstring + Zahl)")
			else:
				_print_fail("Virtual-Methode färbt falsch (inside=%s after=%s)" % [inside, after])
				ok = false
	else:
		_print_fail("Panel bietet new_scratch() nicht")
		ok = false

	# 5) Hot-Reload-Robustheit: der Editor lädt Dock-Skripte im Betrieb neu.
	#    Der Node überlebt, neue Member sind null. Das Panel muss sich neu
	#    aufbauen UND offene Tabs (inkl. Text) wiederherstellen.
	if panel.has_method("editor_poll"):
		var before := ""
		if editor != null:
			before = editor.text
		panel.set("_tabs", null)
		panel.set("_file_list", null)
		panel.set("_log", null)
		panel.set("_store", null)
		panel.editor_poll()
		panel.refresh_scripts()
		var rebuilt_tabs := _find_class(panel, "TabContainer") as TabContainer
		var rebuilt_edit := _find_class(panel, "CodeEdit") as CodeEdit
		var rebuilt_list := _find_class(panel, "ItemList") as ItemList
		if rebuilt_tabs != null and rebuilt_list != null and rebuilt_edit != null:
			print("[VERIFY] OK: Panel nach simuliertem Reload neu aufgebaut")
			if before != "" and rebuilt_edit.text == before:
				print("[VERIFY] OK: offener Tab inkl. Text wiederhergestellt (", rebuilt_tabs.get_tab_count(), " Tab(s))")
			elif before != "":
				_print_fail("Tab-Text nach Reload verloren")
				ok = false
		else:
			_print_fail("Panel baute UI nach Reload nicht auf")
			ok = false
	else:
		_print_fail("panel.editor_poll() fehlt")
		ok = false

	# 5b) Projekt-Einstellungen: Das Plugin registriert sie, die Facade liest
	#     sie. Ohne diesen Weg waeren Workspace/Python-Pfad/Pakete nur per Code
	#     setzbar - fuer Nutzer kaum auffindbar.
	var defs := PythonBridgeConfig.project_setting_defs()
	var missing_settings: Array = []
	for def in defs:
		if not ProjectSettings.has_setting(str(def["path"])):
			missing_settings.append(str(def["path"]))
	if missing_settings.is_empty():
		print("[VERIFY] OK: %d Projekt-Einstellungen registriert (Abschnitt 'Python Bridge')" % defs.size())
	else:
		_print_fail("nicht registrierte Einstellungen: " + str(missing_settings))
		ok = false

	if pb != null and pb.has_method("reload_config"):
		var autostart_path := "python_bridge/general/autostart"
		var previous_autostart: Variant = ProjectSettings.get_setting(autostart_path, false)
		var previous_ws: Variant = ProjectSettings.get_setting("python_bridge/general/workspace_dir", "")
		ProjectSettings.set_setting(autostart_path, true)
		# Ein gesetzter Workspace darf durch reload_config() NICHT verloren gehen.
		pb.call("reload_config")
		var effective: Dictionary = pb.get("_settings")
		if bool(effective.get("autostart", false)):
			print("[VERIFY] OK: reload_config() übernimmt Projekt-Einstellungen (autostart)")
		else:
			_print_fail("reload_config() ignoriert Projekt-Einstellungen")
			ok = false
		ProjectSettings.set_setting(autostart_path, previous_autostart)
		ProjectSettings.set_setting("python_bridge/general/workspace_dir", previous_ws)

	# 5c) Einstellungen-Dialog im Dock (der Weg ohne Projektfenster).
	if panel.has_method("open_settings"):
		panel.call("open_settings")
		var settings_dialog: Variant = panel.get("_settings_dialog")
		var settings_fields: Variant = panel.get("_settings_fields")
		if settings_dialog != null and settings_fields is Dictionary \
				and (settings_fields as Dictionary).size() == defs.size():
			print("[VERIFY] OK: Einstellungen-Dialog mit %d Feldern" % (settings_fields as Dictionary).size())
			if (settings_dialog as Window).visible:
				print("[VERIFY] OK: Einstellungen-Dialog lässt sich öffnen")
			(settings_dialog as Window).hide()
		else:
			_print_fail("Einstellungen-Dialog unvollständig (fields=%s)" % str(settings_fields))
			ok = false
	else:
		_print_fail("panel.open_settings() fehlt")
		ok = false

	# 6) Echter Datei-Roundtrip über das Dock: anlegen -> öffnen -> bearbeiten
	#    -> speichern -> löschen (inkl. Artefakt-Prüfung). Nutzt einen
	#    temporären Workspace, nicht den Projekt-Workspace.
	if pb != null and panel.has_method("open_script"):
		var workspace := "res://.pb_test_tmp/verify_ws"
		_remove_recursive(".pb_test_tmp")
		pb.call("configure", {"workspace_dir": workspace})
		panel.refresh_scripts()
		pb.call("create_script", "verify_roundtrip", "x = 1\n")
		panel.refresh_scripts()
		var opened := str(panel.open_script("verify_roundtrip"))
		var file_editor := panel.call("_active_editor") as CodeEdit
		if opened != "" and file_editor != null:
			file_editor.text = "x = 2  # gespeichert\n"
			var saved := bool(panel.call("_save_editor", file_editor))
			var on_disk := FileAccess.get_file_as_string(workspace + "/scripts/verify_roundtrip.py")
			if saved and on_disk == "x = 2  # gespeichert\n":
				print("[VERIFY] OK: Speichern über das Dock schreibt exakt den Editor-Inhalt")
			else:
				_print_fail("Speichern über das Dock fehlgeschlagen (saved=%s content=%s)" % [saved, on_disk])
				ok = false
			var closed := bool(panel.call("_is_dirty", file_editor)) == false
			if closed:
				print("[VERIFY] OK: Tab ist nach dem Speichern nicht mehr als geändert markiert")
			else:
				_print_fail("Tab bleibt nach dem Speichern dirty")
				ok = false
		else:
			_print_fail("Datei konnte nicht über das Dock geöffnet werden")
			ok = false
		# Artefakt anlegen und über das Dock löschen.
		var artifact_dir := workspace + "/scripts/__pycache__"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(artifact_dir))
		var pyc := FileAccess.open(artifact_dir + "/verify_roundtrip.cpython-313.pyc", FileAccess.WRITE)
		if pyc != null:
			pyc.store_string("pyc")
			pyc.close()
		var report: Dictionary = panel.call("_delete_script", "verify_roundtrip")
		var source_gone := not FileAccess.file_exists(workspace + "/scripts/verify_roundtrip.py")
		var pyc_gone := not FileAccess.file_exists(artifact_dir + "/verify_roundtrip.cpython-313.pyc")
		if bool(report.get("ok", false)) and source_gone and pyc_gone:
			print("[VERIFY] OK: Löschen über das Dock entfernt Quelle und .pyc")
		else:
			_print_fail("Löschen über das Dock unvollständig: %s" % str(report))
			ok = false
		_remove_recursive(".pb_test_tmp")

	_print_result(ok)
	quit(0 if ok else 1)

func _remove_recursive(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := path.path_join(entry)
		if dir.current_is_dir():
			_remove_recursive(child)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(child))
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(abs)

func _print_fail(message: String) -> void:
	print("[VERIFY] FAIL: ", message)

func _print_result(ok: bool) -> void:
	print("[VERIFY] RESULT: ", "PASS" if ok else "FAIL")

func _find_named(node: Node, node_name: String) -> Node:
	if node.name == node_name:
		return node
	for child in node.get_children():
		var hit := _find_named(child, node_name)
		if hit != null:
			return hit
	return null

func _find_class(node: Node, cls: String) -> Node:
	if node.get_class() == cls:
		return node
	for child in node.get_children():
		var hit := _find_class(child, cls)
		if hit != null:
			return hit
	return null
