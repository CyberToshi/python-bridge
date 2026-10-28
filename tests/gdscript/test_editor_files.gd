class_name PBTestEditorFiles
extends PBTests
## Tests für die Editor-Bausteine ohne Godot-Editor-Kontext:
##   - ScriptStore: Öffnen/Speichern (inkl. leerer Datei, CRLF, BOM)
##   - ScriptFiles: rückstandsfreies Löschen ALLER Artefakte
##   - Syntax-Highlighter: Farb-Reset + mehrzeilige Strings
##
## Arbeitsordner ist res://.pb_test_tmp (im Projekt, wird vor/nach jedem Test
## gelöscht) - kein Schreiben in den echten Workspace.

const BASE := "res://.pb_test_tmp"

var _scripts := ""
var _wrappers := ""

func test_suite_setup() -> void:
	_rmrf(BASE)
	_scripts = BASE + "/scripts"
	_wrappers = BASE + "/wrappers"
	_mkfile(_scripts + "/.keep_dir_marker", "")
	assert_true(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_scripts)))

# ------------------------------------------------------------------ Id-Regeln
func test_validate_script_id_accepts_module_names() -> void:
	for id in ["mein_modul", "_privat", "modul2", "a"]:
		assert_eq(PythonBridgeScriptFiles.validate_script_id(id), "", "gültig: " + id)

func test_validate_script_id_rejects_junk() -> void:
	for id in ["", " ", "1abc", "a/b", "a\\b", "..", ".hidden", "x.py", "x.pyx", "mit leer", "a-b", "x" + "y".repeat(80)]:
		assert_ne(PythonBridgeScriptFiles.validate_script_id(id), "", "ungültig: " + id)

# ------------------------------------------------------------------ Speichern / Lesen
func test_write_then_read_roundtrip() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	var write := store.write("modul", "print(1)\r\nprint(2)\n")
	assert_true(bool(write.get("ok", false)), "write ok: " + str(write.get("error", "")))
	var read := store.read("modul")
	assert_true(bool(read.get("ok", false)), "read ok")
	assert_eq(str(read.get("text", "")), "print(1)\nprint(2)\n", "CRLF wird zu LF normalisiert")
	assert_eq(str(read.get("ext", "")), "py")

func test_empty_file_is_not_an_error() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	store.write("leer", "")
	var read := store.read("leer")
	assert_true(bool(read.get("ok", false)), "leere Datei ist lesbar")
	assert_eq(str(read.get("text", "")), "", "leerer Inhalt")

func test_read_missing_file_reports_error() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	var read := store.read("gibt_es_nicht")
	assert_false(bool(read.get("ok", false)), "fehlende Datei ist ein Fehler")
	assert_ne(str(read.get("error", "")), "")

func test_bom_is_stripped() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	var path := _scripts + "/mit_bom.py"
	_mkdir(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]) + "x = 1\n".to_utf8_buffer())
	file.close()
	var read := store.read("mit_bom")
	assert_true(bool(read.get("ok", false)))
	assert_eq(str(read.get("text", "")), "x = 1\n", "BOM wird entfernt")

func test_py_and_pyx_never_coexist() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	store.write("dual", "a = 1\n")
	assert_true(FileAccess.file_exists(_scripts + "/dual.py"))
	var to_cython := store.write("dual", "def f():\n    return 1\n", true)
	assert_true(bool(to_cython.get("ok", false)))
	assert_eq(str(to_cython.get("removed_counterpart", "")), _scripts + "/dual.py", "alte .py wird entfernt")
	assert_false(FileAccess.file_exists(_scripts + "/dual.py"), ".py ist weg")
	assert_true(FileAccess.file_exists(_scripts + "/dual.pyx"), ".pyx existiert")
	assert_eq(store.ext_of("dual"), "pyx")
	var back := store.write("dual", "a = 2\n", false)
	assert_true(bool(back.get("ok", false)))
	assert_false(FileAccess.file_exists(_scripts + "/dual.pyx"), ".pyx ist weg")
	assert_eq(store.ext_of("dual"), "py")

func test_list_sorts_and_prefers_py() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	store.write("zebra", "")
	store.write("alpha", "")
	var ids: Array = []
	for entry in store.list():
		ids.append(str(entry.get("id", "")))
	assert_true(ids.has("alpha") and ids.has("zebra"))
	assert_true(ids.find("alpha") < ids.find("zebra"), "alphabetisch sortiert")

# ------------------------------------------------------------------ Löschen
## Regression für "Datenmüll/Rückstände": Quelle, Bytecode, Cython-Build-Reste,
## Wrapper und Zustandseintrag müssen verschwinden - Nachbardateien nicht.
func test_delete_removes_every_artifact() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	store.write("wegdamit", "def f():\n    return 1\n")
	store.write("bleibt", "y = 2\n")
	_mkfile(_scripts + "/wegdamit.c", "/* c */")
	_mkfile(_scripts + "/wegdamit.cp313-win_amd64.pyd", "binary")
	_mkfile(_scripts + "/wegdamit.py.uid", "uid:123")
	_mkfile(_scripts + "/__pycache__/wegdamit.cpython-313.pyc", "pyc")
	_mkfile(_scripts + "/cython_build_tmp/temp.win/Release/wegdamit.obj", "obj")
	_mkfile(_wrappers + "/wegdamit_wrapper.gd", "# generated")
	_mkfile(_wrappers + "/wegdamit_wrapper.gd.uid", "uid:456")
	_mkfile(_scripts + "/.cython_state.json", JSON.stringify({"wegdamit": "hash1", "bleibt": "hash2"}))

	var report := store.delete("wegdamit")
	assert_true(bool(report.get("ok", false)), "Löschen ok: " + str(report.get("error", "")))
	assert_true(bool(report.get("existed", false)), "existed=true")
	var removed: Array = report.get("removed", [])
	assert_true(removed.size() >= 8, "mindestens 8 Artefakte entfernt (war: %d)" % removed.size())
	assert_false(FileAccess.file_exists(_scripts + "/wegdamit.py"), ".py entfernt")
	assert_false(FileAccess.file_exists(_scripts + "/wegdamit.c"), ".c entfernt")
	assert_false(FileAccess.file_exists(_scripts + "/wegdamit.cp313-win_amd64.pyd"), ".pyd entfernt")
	assert_false(FileAccess.file_exists(_scripts + "/wegdamit.py.uid"), "UID-Sidecar entfernt")
	assert_false(FileAccess.file_exists(_scripts + "/__pycache__/wegdamit.cpython-313.pyc"), ".pyc entfernt")
	assert_false(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_scripts + "/__pycache__")),
		"leerer __pycache__-Ordner entfernt")
	assert_false(FileAccess.file_exists(_scripts + "/cython_build_tmp/temp.win/Release/wegdamit.obj"), ".obj entfernt")
	assert_false(FileAccess.file_exists(_wrappers + "/wegdamit_wrapper.gd"), "Wrapper entfernt")
	assert_false(FileAccess.file_exists(_wrappers + "/wegdamit_wrapper.gd.uid"), "Wrapper-UID entfernt")

	# Nachbardateien bleiben unangetastet.
	assert_true(FileAccess.file_exists(_scripts + "/bleibt.py"), "anderes Skript bleibt")
	var state_text := FileAccess.get_file_as_string(_scripts + "/.cython_state.json")
	assert_false(state_text.contains("wegdamit"), "Cython-Zustandseintrag entfernt")
	assert_true(state_text.contains("bleibt"), "fremder Zustandseintrag bleibt")

func test_delete_missing_script_is_not_an_error() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	var report := store.delete("nie_da_gewesen")
	assert_true(bool(report.get("ok", false)), "kein Fehler bei fehlender Datei")
	assert_false(bool(report.get("existed", false)), "existed=false")

func test_delete_rejects_path_escape() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	var report := store.delete("../ausserhalb")
	assert_false(bool(report.get("ok", false)), "Pfad-Ausbruch wird abgelehnt")

# ------------------------------------------------------------------ Umbenennen
func test_rename_moves_content_and_cleans_old_artifacts() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	store.write("alt", "wert = 42\n")
	_mkfile(_scripts + "/alt.pyc", "pyc")
	var result := store.rename("alt", "neu")
	assert_true(bool(result.get("ok", false)), "Umbenennen ok: " + str(result.get("error", "")))
	assert_false(FileAccess.file_exists(_scripts + "/alt.py"), "alte Quelle entfernt")
	assert_false(FileAccess.file_exists(_scripts + "/alt.pyc"), "altes .pyc entfernt")
	var read := store.read("neu")
	assert_true(bool(read.get("ok", false)))
	assert_eq(str(read.get("text", "")), "wert = 42\n", "Inhalt übernommen")

func test_rename_refuses_existing_target() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	store.write("eins", "a = 1\n")
	store.write("zwei", "b = 2\n")
	var result := store.rename("eins", "zwei")
	assert_false(bool(result.get("ok", false)), "Kollision wird abgelehnt")

# ---------------------------------------------- Speichern: keine alten Artefakte
## Regression: Wird ein .pyx-Skript wieder als .py gespeichert, blieb das
## kompilierte .pyd liegen - ein veraltetes Cython-Modul blieb importierbar,
## obwohl die Quelle jetzt normales Python ist.
func test_save_as_py_purges_stale_cython_artifacts() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	store.write("rueckweg", "def f():\n    return 1\n", true)
	assert_true(FileAccess.file_exists(_scripts + "/rueckweg.pyx"), ".pyx angelegt")
	_mkfile(_scripts + "/rueckweg.c", "/* c */")
	_mkfile(_scripts + "/rueckweg.cp313-win_amd64.pyd", "binary")
	_mkfile(_scripts + "/cython_build_tmp/lib_rueckweg/rueckweg.cp313-win_amd64.pyd", "binary")
	_mkfile(_scripts + "/.cython_state.json", JSON.stringify({"rueckweg": "hash1"}))

	var write := store.write("rueckweg", "x = 1\n", false)
	assert_true(bool(write.get("ok", false)), "Speichern ok: " + str(write.get("error", "")))
	assert_eq(str(write.get("ext", "")), "py")
	assert_false(FileAccess.file_exists(_scripts + "/rueckweg.pyd"), ".pyd entfernt")
	assert_false(FileAccess.file_exists(_scripts + "/rueckweg.cp313-win_amd64.pyd"), ".pyd entfernt")
	assert_false(FileAccess.file_exists(_scripts + "/rueckweg.c"), ".c entfernt")
	assert_false(FileAccess.file_exists(_scripts + "/cython_build_tmp/lib_rueckweg/rueckweg.cp313-win_amd64.pyd"),
		"Build-Zwischenstand entfernt")
	assert_false(FileAccess.get_file_as_string(_scripts + "/.cython_state.json").contains("rueckweg"),
		"Build-Hash entfernt")
	var purged: Array = write.get("purged_build", [])
	assert_true(purged.size() >= 3, "purged_build meldet die Aufräumarbeit (war: %d)" % purged.size())
	assert_false(FileAccess.file_exists(_scripts + "/rueckweg.pyx"), "Gegenstück .pyx entfernt")
	assert_eq(FileAccess.get_file_as_string(_scripts + "/rueckweg.py"), "x = 1\n", "neue Quelle geschrieben")

## Gegenrichtung: .py -> .pyx darf keine Build-Artefakte anfassen (es gibt
## keine) und muss die .py entfernen, damit nur EINE Quelle existiert.
func test_save_as_pyx_removes_py_counterpart() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	store.write("nur_eine", "y = 2\n", false)
	var write := store.write("nur_eine", "cdef int y = 2\n", true)
	assert_true(bool(write.get("ok", false)), "Speichern ok")
	assert_eq(str(write.get("ext", "")), "pyx")
	assert_false(FileAccess.file_exists(_scripts + "/nur_eine.py"), ".py entfernt")
	assert_true(FileAccess.file_exists(_scripts + "/nur_eine.pyx"), ".pyx geschrieben")
	assert_eq((write.get("purged_build", []) as Array).size(), 0, "kein Build-Purge bei .pyx")

## Regression für die Reihenfolge: ein gescheiterter Schreibvorgang darf die
## bestehende Datei NICHT kosten (früher wurde das Gegenstück zuerst gelöscht).
func test_failed_write_keeps_existing_counterpart() -> void:
	var store := PythonBridgeScriptStore.new(_scripts, _wrappers)
	store.write("kolli", "z = 3\n", true)
	# .py als Ordner blockiert das Schreiben der Zieldatei.
	_mkdir(_scripts + "/kolli.py")
	var write := store.write("kolli", "z = 4\n", false)
	assert_false(bool(write.get("ok", false)), "Schreiben scheitert")
	assert_true(FileAccess.file_exists(_scripts + "/kolli.pyx"), ".pyx bleibt erhalten")

# ------------------------------------------------------------------ Highlighter
func test_highlighter_resets_colors() -> void:
	var hl := PythonBridgeSyntaxHighlighter.new()
	var line := "x = 42  # note"
	var regions := hl.highlight_line(line)
	assert_eq(regions[0]["color"], PythonBridgeSyntaxHighlighter.COL_DEFAULT, "Spalte 0 = Default")
	assert_eq(regions[4]["color"], PythonBridgeSyntaxHighlighter.COL_NUMBER, "Zahl ab Spalte 4")
	assert_eq(regions[6]["color"], PythonBridgeSyntaxHighlighter.COL_DEFAULT, "nach der Zahl wieder Default")
	assert_eq(regions[8]["color"], PythonBridgeSyntaxHighlighter.COL_COMMENT, "Kommentar ab Spalte 8")

## Regression: nach einem String blieb der Rest der Zeile in String-Farbe.
func test_highlighter_resets_after_string() -> void:
	var hl := PythonBridgeSyntaxHighlighter.new()
	var line := "s = \"hi\" + name"
	var regions := hl.highlight_line(line)
	assert_eq(regions[4]["color"], PythonBridgeSyntaxHighlighter.COL_STRING, "String ab Spalte 4")
	assert_eq(regions[8]["color"], PythonBridgeSyntaxHighlighter.COL_DEFAULT, "nach dem String Default")

func test_highlighter_keywords_and_calls() -> void:
	var hl := PythonBridgeSyntaxHighlighter.new()
	var regions := hl.highlight_line("def berechne(a):")
	assert_eq(regions[0]["color"], PythonBridgeSyntaxHighlighter.COL_KEYWORD, "def = Keyword")
	assert_eq(regions[4]["color"], PythonBridgeSyntaxHighlighter.COL_DEF_NAME, "Funktionsname hervorgehoben")
	var call_regions := hl.highlight_line("    print(berechne(2))")
	assert_eq(call_regions[4]["color"], PythonBridgeSyntaxHighlighter.COL_BUILTIN, "print = Builtin")
	assert_eq(call_regions[10]["color"], PythonBridgeSyntaxHighlighter.COL_CALL, "Funktionsaufruf farbig")

func test_highlighter_triple_quote_state() -> void:
	var hl := PythonBridgeSyntaxHighlighter.new()
	var open := hl.state_after_line("doc = \"\"\"erste Zeile")
	assert_eq(open, "\"\"\"", "offener Docstring erkannt")
	assert_eq(hl.state_after_line("zweite Zeile", open), "\"\"\"", "Zustand läuft weiter")
	assert_eq(hl.state_after_line("ende \"\"\"", open), "", "Docstring geschlossen")
	assert_eq(hl.state_after_line("# doc = \"\"\" nur Kommentar", ""), "",
		"Triple-Quotes im Kommentar öffnen keinen String")
	var inside := hl.highlight_line("zweite Zeile", "\"\"\"")
	assert_eq(inside[0]["color"], PythonBridgeSyntaxHighlighter.COL_STRING, "Fortsetzungszeile ist String")
	var closing := hl.highlight_line("ende \"\"\" tail", "\"\"\"")
	assert_eq(closing[0]["color"], PythonBridgeSyntaxHighlighter.COL_STRING, "Anfang der Schlusszeile ist String")
	assert_eq(closing[8]["color"], PythonBridgeSyntaxHighlighter.COL_DEFAULT, "nach dem Docstring wieder Default")

func test_highlighter_cache_invalidate() -> void:
	var hl := PythonBridgeSyntaxHighlighter.new()
	hl.state_after_line("doc = \"\"\"offen", "")
	hl.invalidate()
	assert_eq(hl.state_after_line("x = 1", ""), "", "nach invalidate wird frisch gescannt")

# ------------------------------------------------------------------ Helpers
func test_suite_cleanup() -> void:
	_rmrf(BASE)

func _mkfile(path: String, content: String) -> void:
	_mkdir(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(content)
		file.close()

func _mkdir(path: String) -> void:
	if path != "":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))

func _rmrf(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var child := path.path_join(name)
		if dir.current_is_dir():
			_rmrf(child)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(child))
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(abs)
