class_name PythonBridgeScriptStore
extends RefCounted
## Dateischicht des Editor-Docks: Listen, Lesen, Schreiben, Umbenennen und
## Löschen persistenter Python-Skripte.
##
## Bewusst OHNE Bridge-/Editor-Abhängigkeit (reines RefCounted + FileAccess),
## damit "Öffnen und Speichern" headless testbar ist und ein Fehler im UI nie
## zu einem halb geschriebenen Zustand führt.
##
## Konventionen:
##   - Quelltext wird als UTF-8 gelesen/geschrieben, Zeilenenden als "\n"
##     normalisiert und ein führendes BOM entfernt (sonst steht es als
##     unsichtbares Zeichen im Editor).
##   - `write()` liefert `removed_counterpart`, wenn die jeweils andere
##     Variante (.py <-> .pyx) entfernt wurde. Ein Skript existiert nie
##     doppelt - `resolve_script_path()` würde sonst die falsche Datei laden.
##   - `read()` unterscheidet "leere Datei" (ok, text == "") von "nicht
##     lesbar" (ok == false + error). Die frühere Fassung verwechselte beides.

var scripts_dir: String = ""
var wrappers_dir: String = ""

func _init(p_scripts_dir := "", p_wrappers_dir := "") -> void:
	configure(p_scripts_dir, p_wrappers_dir)

func configure(p_scripts_dir: String, p_wrappers_dir := "") -> void:
	scripts_dir = p_scripts_dir
	wrappers_dir = p_wrappers_dir

func is_configured() -> bool:
	return scripts_dir.strip_edges() != ""

# ------------------------------------------------------------------ Abfragen
## [{id, ext, path}] - nur .py/.pyx im Skript-Ordner, alphabetisch.
func list() -> Array:
	if not is_configured():
		return []
	return PythonBridgeScriptFiles.list_scripts(scripts_dir)

func ext_of(script_id: String) -> String:
	for ext in ["pyx", "py"]:
		if FileAccess.file_exists(path_for(script_id, ext)):
			return ext
	return ""

func exists(script_id: String) -> bool:
	return ext_of(script_id) != ""

## Pfad der Id; `prefer_ext` wählt bei vorhandenen Dateien die Variante.
func path_for(script_id: String, prefer_ext := "") -> String:
	if prefer_ext != "":
		return scripts_dir.path_join(script_id + "." + prefer_ext)
	var pyx := scripts_dir.path_join(script_id + ".pyx")
	if FileAccess.file_exists(pyx):
		return pyx
	return scripts_dir.path_join(script_id + ".py")

## Prüft eine neue Id inkl. Kollision. Rückgabe: "" = verwendbar.
func validate_new_id(script_id: String) -> String:
	var err := PythonBridgeScriptFiles.validate_script_id(script_id)
	if err != "":
		return err
	if exists(script_id):
		return "Es gibt bereits ein Skript \"%s\"." % script_id
	return ""

func mtime(script_id: String) -> int:
	var path := path_for(script_id)
	if not FileAccess.file_exists(path):
		return -1
	return FileAccess.get_modified_time(path)

# ------------------------------------------------------------------ Lesen
## {ok, text, path, ext, error}
func read(script_id: String) -> Dictionary:
	if not is_configured():
		return _err("Der Workspace ist noch nicht bekannt (Bridge nicht bereit).")
	var ext := ext_of(script_id)
	if ext == "":
		return _err("Datei nicht gefunden: %s" % script_id)
	var path := path_for(script_id, ext)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _err("Öffnen fehlgeschlagen (%s): %s" % [
			error_string(FileAccess.get_open_error()), path])
	var text := file.get_as_text()
	var read_err := file.get_error()
	file.close()
	if read_err != OK:
		return _err("Lesen fehlgeschlagen (%s): %s" % [error_string(read_err), path])
	# BOM + CRLF normalisieren: ein BOM wäre im CodeEdit ein unsichtbares
	# Zeichen vor dem ersten Token, CRLF würde als \r im Text stehen.
	if text.begins_with("\uFEFF"):
		text = text.substr(1)
	text = text.replace("\r\n", "\n").replace("\r", "\n")
	return {"ok": true, "text": text, "path": path, "ext": ext, "error": ""}

# ------------------------------------------------------------------ Schreiben
## {ok, path, ext, removed_counterpart, error}
func write(script_id: String, text: String, as_cython := false) -> Dictionary:
	if not is_configured():
		return _err("Der Workspace ist noch nicht bekannt (Bridge nicht bereit).")
	var unsafe := _reject_unsafe_id(script_id)
	if unsafe != "":
		return _err(unsafe)
	var ext := "pyx" if as_cython else "py"
	var path := path_for(script_id, ext)
	var dir_abs := ProjectSettings.globalize_path(path.get_base_dir())
	if DirAccess.make_dir_recursive_absolute(dir_abs) != OK \
			and not DirAccess.dir_exists_absolute(dir_abs):
		return _err("Ordner konnte nicht angelegt werden: " + path.get_base_dir())

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _err("Schreiben fehlgeschlagen (%s): %s" % [
			error_string(FileAccess.get_open_error()), path])
	var wrote := file.store_string(text)
	var write_err := file.get_error()
	file.close()
	if not wrote or write_err != OK:
		return _err("Schreiben fehlgeschlagen (%s): %s" % [
			error_string(write_err), path])

	# Erst NACH erfolgreichem Schreiben das Gegenstück entfernen: ein
	# gescheiterter Schreibvorgang darf die bestehende Datei nicht kosten.
	# (.py und .pyx desselben Stems dürfen nicht parallel existieren, weil
	# resolve_script_path() .pyx bevorzugt und ein Save in die .py dann
	# wirkungslos wäre.)
	var removed_counterpart := ""
	var other := path_for(script_id, "py" if as_cython else "pyx")
	if other != path and FileAccess.file_exists(other):
		if DirAccess.remove_absolute(ProjectSettings.globalize_path(other)) == OK:
			removed_counterpart = other

	# Ziel .py: Build-Reste eines früheren Cython-Lebens aufräumen. Sonst
	# bliebe ein veraltetes .so/.pyd importierbar, obwohl die Quelle jetzt
	# normales Python ist, und der Build-Hash bliebe stehen.
	var purged: Array = []
	if not as_cython:
		var purge := PythonBridgeScriptFiles.purge_build_artifacts(scripts_dir, script_id)
		purged = Array(purge.get("removed", []))
	return {
		"ok": true, "path": path, "ext": ext,
		"removed_counterpart": removed_counterpart,
		"purged_build": purged, "error": "",
	}

# ------------------------------------------------------------------ Umbenennen
## Liest die Quelle, schreibt sie unter neuer Id und räumt die alte Id
## rückstandsfrei ab. {ok, path, ext, removed, error}
func rename(old_id: String, new_id: String) -> Dictionary:
	if old_id == new_id:
		return {"ok": true, "path": path_for(old_id), "ext": ext_of(old_id), "removed": [], "error": ""}
	var invalid := validate_new_id(new_id)
	if invalid != "":
		return _err(invalid)
	var read_res := read(old_id)
	if not bool(read_res.get("ok", false)):
		return _err(str(read_res.get("error", "Quelle nicht lesbar.")))
	var write_res := write(new_id, str(read_res.get("text", "")), str(read_res.get("ext", "py")) == "pyx")
	if not bool(write_res.get("ok", false)):
		return _err(str(write_res.get("error", "Schreiben fehlgeschlagen.")))
	var del := delete(old_id)
	if not bool(del.get("ok", false)):
		# Neue Datei steht bereits; die alte konnte nicht vollständig
		# entfernt werden - das wird sichtbar gemeldet statt verschwiegen.
		return _err("Umbenannt, aber alte Dateien nicht vollständig entfernt: " + str(del.get("error", "")))
	return {
		"ok": true,
		"path": write_res.get("path", ""),
		"ext": write_res.get("ext", "py"),
		"removed": del.get("removed", []),
		"error": "",
	}

# ------------------------------------------------------------------ Löschen
## Rückstandsfrei: Quelle, .pyc, Cython-Build-Reste, Wrapper, UID-Sidecars.
func delete(script_id: String) -> Dictionary:
	if not is_configured():
		return _err("Der Workspace ist noch nicht bekannt (Bridge nicht bereit).")
	return PythonBridgeScriptFiles.delete_script(scripts_dir, wrappers_dir, script_id)

# ------------------------------------------------------------------ Internal
func _err(message: String) -> Dictionary:
	return {"ok": false, "text": "", "path": "", "ext": "", "error": message}

func _reject_unsafe_id(script_id: String) -> String:
	if script_id.strip_edges() == "":
		return "Script-Id ist leer."
	if script_id.begins_with("/") or script_id.contains("://"):
		return "Script-Id muss eine Id im Workspace sein, kein absoluter Pfad."
	for part in script_id.split("/", false):
		if part == "..":
			return "Script-Id darf \"..\" nicht enthalten."
	return ""
