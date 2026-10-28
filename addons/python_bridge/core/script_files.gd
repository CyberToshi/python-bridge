class_name PythonBridgeScriptFiles
extends RefCounted
## Datei-Artefakte persistenter Python-Skripte: auflisten, finden und
## RÜCKSTANDSFREI löschen.
##
## Ein Skript hinterlässt je nach Verwendung mehr als eine Datei:
##   - <id>.py / <id>.pyx            (Quelle)
##   - <id>.py.uid                   (Godot-UID-Sidecar, falls angelegt)
##   - <id>.c                        (Cython-Zwischenstand)
##   - <id>.cp313-win_amd64.pyd      (kompiliertes Cython-Modul, Windows)
##   - <id>.cpython-313-*.so         (kompiliertes Cython-Modul, Linux)
##   - __pycache__/<id>.*.pyc        (Bytecode)
##   - cython_build_tmp/**.obj       (Compiler-Zwischendateien, aus dem Build)
##   - wrappers/<id>_wrapper.gd      (generierter GDScript-Wrapper)
##   - wrappers/<id>_wrapper.gd.uid
##
## `delete_script()` entfernt genau diese Artefakte - nichts anderes. Der
## Skript-Ordner enthält keine Fremddateien, die dabei verloren gehen könnten.
##
## Die Klasse ist bewusst ein reiner RefCounted-Helper ohne Bridge-Abhängigkeit
## (nutzbar aus dem Editor-Dock UND aus der Facade und damit headless testbar).

const CYTHON_STATE_FILE := ".cython_state.json"
const CYTHON_TMP_DIR := "cython_build_tmp"
const PYCACHE_DIR := "__pycache__"
## Endungen von Build-/Bytecode-Artefakten, die zu einem Skript-Stem gehören.
const COMPILED_EXTS := ["so", "pyd", "c", "o", "obj"]
const SOURCE_EXTS := ["py", "pyx"]
const MAX_TMP_SCAN_DEPTH := 6

# ------------------------------------------------------------------ Id-Regeln
## Prüft eine NEUE Script-Id (Anlegen/Umbenennen). Rückgabe: "" = gültig,
## sonst eine Meldung für das UI. Vorhandene Dateien mit anderen Namen bleiben
## les- und löschbar - diese Prüfung gilt nur für neues Material.
static func validate_script_id(script_id: String) -> String:
	if script_id == "":
		return "Script-Id darf nicht leer sein."
	if script_id != script_id.strip_edges():
		return "Script-Id darf nicht mit Leerzeichen beginnen oder enden."
	if script_id.begins_with("."):
		return "Script-Id darf nicht mit einem Punkt beginnen."
	if script_id.contains("/") or script_id.contains("\\") or script_id.contains(".."):
		return "Script-Id darf keine Pfadanteile enthalten."
	if script_id.ends_with(".py") or script_id.ends_with(".pyx"):
		return "Script-Id ohne Dateiendung angeben (z. B. \"mein_modul\")."
	if script_id.length() > 64:
		return "Script-Id ist zu lang (max. 64 Zeichen)."
	var first := script_id.substr(0, 1)
	if not (first == "_" or _is_alpha(first)):
		return "Script-Id muss mit einem Buchstaben oder _ beginnen."
	for i in script_id.length():
		var c := script_id.substr(i, 1)
		if not (c == "_" or _is_alpha(c) or _is_digit(c)):
			return "Nur Buchstaben, Ziffern und _ sind erlaubt."
	return ""

## Interne Sicherheitsprüfung für Löschen/Umbenennen: lehnt Ids ab, die den
## Skript-Ordner verlassen könnten. Bestehende Namen mit Sonderzeichen (z. B.
## "alt-test") bleiben erlaubt.
static func _reject_unsafe_id(script_id: String) -> String:
	if script_id.strip_edges() == "":
		return "Script-Id ist leer."
	if script_id.begins_with("/") or script_id.contains("://"):
		return "Script-Id muss eine Id im Workspace sein, kein absoluter Pfad."
	for part in script_id.split("/", false):
		if part == "..":
			return "Script-Id darf \"..\" nicht enthalten."
	return ""

# ------------------------------------------------------------------ Auflisten
## Alle im Ordner liegenden Skripte: [{id, ext, path}], alphabetisch,
## .py gewinnt gegen .pyx, wenn beide existieren.
static func list_scripts(scripts_dir: String) -> Array:
	var found := {}
	var dir := DirAccess.open(scripts_dir)
	if dir == null:
		return []
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			var ext := name.get_extension().to_lower()
			if SOURCE_EXTS.has(ext):
				var id := name.get_basename()
				if not found.has(id) or ext == "py":
					found[id] = {"id": id, "ext": ext, "path": scripts_dir.path_join(name)}
		name = dir.get_next()
	dir.list_dir_end()
	var out: Array = found.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["id"]).naturalnocasecmp_to(str(b["id"])) < 0)
	return out

# ------------------------------------------------------------------ Artefakte
## Alle existierenden Artefakte eines Skripts (nur vorhandene Pfade).
static func script_artifacts(scripts_dir: String, wrappers_dir: String, script_id: String) -> PackedStringArray:
	var out := PackedStringArray()
	if _reject_unsafe_id(script_id) != "":
		return out
	var stem := script_id.get_file()
	if stem == "":
		return out
	var dir := scripts_dir.path_join(script_id).get_base_dir()

	# Quelle + UID-Sidecar + direkte Artefaktnamen.
	for ext in SOURCE_EXTS + COMPILED_EXTS + ["pyc", "uid"]:
		var p := dir.path_join(stem + "." + ext)
		if FileAccess.file_exists(p):
			out.append(p)
	# Godot legt für Skripte ein <datei>.uid an (z. B. wrapper.gd.uid).
	var py_uid := dir.path_join(stem + ".py.uid")
	if FileAccess.file_exists(py_uid):
		out.append(py_uid)

	# ABI-tragende Build-Ausgaben: <stem>.<tag>.pyd/.so/.c/.o/.obj
	var listing := DirAccess.open(dir)
	if listing != null:
		listing.list_dir_begin()
		var name := listing.get_next()
		while name != "":
			if not listing.current_is_dir() and name.begins_with(stem + "."):
				var ext := name.get_extension().to_lower()
				if COMPILED_EXTS.has(ext):
					var p := dir.path_join(name)
					if not out.has(p):
						out.append(p)
			name = listing.get_next()
		listing.list_dir_end()

	# Bytecode-Cache.
	var pyc_dir := dir.path_join(PYCACHE_DIR)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(pyc_dir)):
		var pc := DirAccess.open(pyc_dir)
		if pc != null:
			pc.list_dir_begin()
			var n := pc.get_next()
			while n != "":
				if not pc.current_is_dir() and n.begins_with(stem + ".") and n.ends_with(".pyc"):
					out.append(pyc_dir.path_join(n))
				n = pc.get_next()
			pc.list_dir_end()

	# Generierter Wrapper (+ dessen UID-Sidecar).
	if wrappers_dir != "":
		var wrapper := wrappers_dir.path_join(stem + "_wrapper.gd")
		if FileAccess.file_exists(wrapper):
			out.append(wrapper)
		var wrapper_uid := wrapper + ".uid"
		if FileAccess.file_exists(wrapper_uid):
			out.append(wrapper_uid)
	return out

# ------------------------------------------------------------------ Löschen
## Löscht Quelle + ALLE Artefakte eines Skripts. Rückgabe:
##   {ok: bool, existed: bool, removed: [path], failed: [{path, error}],
##    error: String, cython_state_cleared: bool}
## `ok` ist true, wenn nichts übrig blieb (fehlende Dateien sind kein Fehler).
static func delete_script(scripts_dir: String, wrappers_dir: String, script_id: String) -> Dictionary:
	var unsafe := _reject_unsafe_id(script_id)
	if unsafe != "":
		return _result(false, false, [], [], unsafe, false)
	var artifacts := script_artifacts(scripts_dir, wrappers_dir, script_id)
	var removed := PackedStringArray()
	var failed: Array = []
	for path in artifacts:
		var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if err == OK:
			removed.append(path)
		elif err == ERR_FILE_NOT_FOUND:
			pass  # bereits weg - kein Fehler
		else:
			failed.append({"path": path, "error": error_string(err)})

	# Compiler-Zwischenstände unter cython_build_tmp/<target>/...
	removed.append_array(_purge_cython_tmp(scripts_dir, script_id.get_file()))
	# Hash-Eintrag aus dem Cython-Zustandsfile (sonst bleibt eine Leiche).
	var state_cleared := forget_cython_state(scripts_dir, script_id.get_file())

	# Leere Hilfsordner aufräumen (nur die bekannten, nur wenn leer).
	_prune_empty_dir(scripts_dir.path_join(script_id).get_base_dir().path_join(PYCACHE_DIR))
	_prune_empty_dir(scripts_dir.path_join(CYTHON_TMP_DIR))

	return _result(failed.is_empty(), not artifacts.is_empty(), removed, failed, "", state_cleared)

## Entfernt NUR die Build-Artefakte eines Skripts (Quelle und Wrapper bleiben
## unangetastet): .c, .so/.pyd, .o/.obj, Bytecode, cython_build_tmp-Reste und
## den Build-Hash-Eintrag.
##
## Wird beim Speichern als .py aufgerufen: ein früheres Cython-Modul darf
## nicht als veraltetes .so/.pyd weiter importierbar bleiben, obwohl die
## Quelle inzwischen normales Python ist.
## Rückgabe: {ok, removed[], failed[], cython_state_cleared}
static func purge_build_artifacts(scripts_dir: String, script_id: String) -> Dictionary:
	var dir := scripts_dir.path_join(script_id).get_base_dir()
	var stem := script_id.get_file()
	var keep := PackedStringArray([
		dir.path_join(stem + ".py"),
		dir.path_join(stem + ".pyx"),
		dir.path_join(stem + ".py.uid"),
	])
	var removed := PackedStringArray()
	var failed: Array = []
	for path in script_artifacts(scripts_dir, "", script_id):
		if keep.has(path):
			continue
		var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if err == OK:
			removed.append(path)
		elif err != ERR_FILE_NOT_FOUND:
			failed.append({"path": path, "error": error_string(err)})
	removed.append_array(_purge_cython_tmp(scripts_dir, stem))
	var state_cleared := forget_cython_state(scripts_dir, stem)
	_prune_empty_dir(dir.path_join(PYCACHE_DIR))
	_prune_empty_dir(scripts_dir.path_join(CYTHON_TMP_DIR))
	return {"ok": failed.is_empty(), "removed": removed, "failed": failed,
		"cython_state_cleared": state_cleared}

## Entfernt den Build-Zustandseintrag eines Stems. Rückgabe: true, wenn ein
## Eintrag tatsächlich entfernt wurde.
static func forget_cython_state(scripts_dir: String, stem: String) -> bool:
	var path := scripts_dir.path_join(CYTHON_STATE_FILE)
	if stem == "" or not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return false
	var state: Dictionary = parsed
	if not state.has(stem):
		return false
	state.erase(stem)
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		return false
	out.store_string(JSON.stringify(state, " ", false))
	out.close()
	return true

# ------------------------------------------------------------------ Internal
static func _purge_cython_tmp(scripts_dir: String, stem: String) -> PackedStringArray:
	var removed := PackedStringArray()
	if stem == "":
		return removed
	var root := scripts_dir.path_join(CYTHON_TMP_DIR)
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(root)):
		return removed
	_walk_purge(root, stem, removed, 0)
	return removed

static func _walk_purge(dir_path: String, stem: String, removed: PackedStringArray, depth: int) -> void:
	if depth > MAX_TMP_SCAN_DEPTH:
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var subdirs := PackedStringArray()
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir():
			subdirs.append(dir_path.path_join(name))
		elif name.begins_with(stem + ".") or name.get_basename() == stem:
			var p := dir_path.path_join(name)
			if DirAccess.remove_absolute(ProjectSettings.globalize_path(p)) == OK:
				removed.append(p)
		name = dir.get_next()
	dir.list_dir_end()
	for sub in subdirs:
		_walk_purge(sub, stem, removed, depth + 1)
		_prune_empty_dir(sub)

static func _prune_empty_dir(dir_path: String) -> void:
	var abs := ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var count := 0
	dir.list_dir_begin()
	while dir.get_next() != "":
		count += 1
	dir.list_dir_end()
	if count == 0:
		DirAccess.remove_absolute(abs)

static func _result(ok: bool, existed: bool, removed: PackedStringArray, failed: Array, err: String, state_cleared: bool) -> Dictionary:
	return {
		"ok": ok,
		"existed": existed,
		"removed": removed,
		"failed": failed,
		"error": err,
		"cython_state_cleared": state_cleared,
	}

static func _is_alpha(c: String) -> bool:
	return c.to_lower() != c.to_upper()

static func _is_digit(c: String) -> bool:
	return c.is_valid_int()
