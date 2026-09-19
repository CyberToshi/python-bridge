@tool
extends EditorExportPlugin
## Packt die Python-Dateien der Bridge in jeden Godot-Export.
##
## Problem: Godots Standard-Export ("all_resources") schliesst nicht-
## importierbare Dateien (.py, .txt) aus - im Export fehlen damit die
## Bridge-Python-Runtime (addons/python_bridge/python) und alle Workspace-
## Skripte (python_bridge/scripts). Im Editor funktioniert alles (echtes
## Dateisystem), im Export startet die Bridge nicht.
##
## Loesung: Dieser EditorExportPlugin-Hook liest die Dateien direkt aus dem
## Projektverzeichnis und fuegt sie mit add_file() dem PCK hinzu. Die Pfade
## bleiben die res://-Pfade, damit die Bridge sie im Export genauso findet
## wie im Editor. venv/tmp/__pycache__ werden bewusst ausgeschlossen (riesig
## bzw. regenerierbar); die venv entsteht im Export-Lauf neu im schreibbaren
## user://-Workspace (siehe PythonBridge._instance_settings()).

const ROOTS := [
	"res://addons/python_bridge/python",
	"res://python_bridge",
]
const EXTENSIONS := [".py", ".pyx", ".txt", ".json"]
const SKIP_DIRS := ["venv", "tmp", "__pycache__", "cython_build_tmp", ".gdignore"]
const MAX_FILE_BYTES := 8 * 1024 * 1024  # Schutz gegen versehentliche Riesen-Dateien


func _get_name() -> String:
	return "PythonBridge"

func _export_begin(features: PackedStringArray, is_debug: bool, _path: String, _flags: int) -> void:
	var count := _collect_files()
	print("[PythonBridge] Export-Plugin: %d Python-/Config-Datei(en) ins PCK aufgenommen (debug=%s, features=%s)"
		% [count, str(is_debug), ",".join(features)])


func _collect_files() -> int:
	var count := 0
	for root in ROOTS:
		count += _append_dir(root)
	return count


func _append_dir(dir_path: String) -> int:
	var count := 0
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := dir_path + "/" + entry
		if dir.current_is_dir():
			if not (entry in SKIP_DIRS):
				count += _append_dir(full)
		else:
			var keep := false
			for e in EXTENSIONS:
				if entry.ends_with(str(e)):
					keep = true
					break
			if keep:
				var f := FileAccess.open(full, FileAccess.READ)
				if f:
					var size := f.get_length()
					if size <= MAX_FILE_BYTES:
						var bytes := f.get_buffer(size)
						f.close()
						# add_file(path, bytes, remap) - Pfad bleibt res://
						add_file(full, bytes, false)
						count += 1
					else:
						push_warning("[PythonBridge] Export ueberspringt grosse Datei: %s (%d Bytes)" % [full, size])
					f = null
		entry = dir.get_next()
	dir.list_dir_end()
	return count
