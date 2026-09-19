class_name BridgeCythonManager
extends RefCounted
## Cython-Sonderpfad (Desktop-only): kompiliert .pyx-Dateien im Skript-Ordner
## inkrementell (SHA-256-basiert) über die venv-Python.
##
## Design (Stabilität zuerst):
##  - Kein zweiter Env-Manager: der Build läuft in der bestehenden venv
##    (pip-Pakete cython + setuptools + optional ziglang als Compiler-Fallback).
##  - Asynchron wie der Provisioner: OS.create_process + tick() pro Frame; das
##    Build-Tool schreibt seinen JSON-Report atomar in eine Datei. Der Editor-
##    Thread blockiert nie (OS.execute würde den Main-Thread einfrieren).
##  - Kein Server-/Protokoll-Input: das Tool wird direkt per Prozess gestartet;
##    Bridge-Server, Executor und Protokoll bleiben unangetastet.
##  - Ehrliche Fehler: Timeout, fehlende venv, fehlendes Tool, Prozess-Tod
##    ohne Report - alles strukturiert im Report, nichts still verschluckt.
##
## Web: Pyodide hat keinen C-Compiler - .pyx ist dort nicht unterstützt
## (der Export-Check warnt); dieses Modul wird im Web-Pfad nie aufgerufen.

signal finished(result: Dictionary)

const TOOL_PATH := "res://addons/python_bridge/python/cython_build.py"
const TIMEOUT_MS := 600_000

var _pid: int = -1
var _busy: bool = false
var _start_ms: int = 0
var _report_file: String = ""

func is_busy() -> bool:
	return _busy

## Startet einen Build. Rueckgabe: {"pending": true} wenn der Prozess laeuft,
## sonst sofort ein Fehler-Report ({"ok": false, ...}).
func start_build(scripts_dir: String, stems: PackedStringArray = PackedStringArray(), force := false) -> Dictionary:
	if _busy:
		return _err("Cython-Build laeuft bereits.")
	# Host-Prozesse verstehen kein res:// - immer globalisieren.
	scripts_dir = ProjectSettings.globalize_path(scripts_dir)
	var venv_py := _find_venv_python(scripts_dir)
	if not FileAccess.file_exists(venv_py):
		return _err("venv-Python nicht gefunden: %s - erst PythonBridge.start_instance() ausfuehren." % venv_py)
	var tool := ProjectSettings.globalize_path(TOOL_PATH)
	if not FileAccess.file_exists(tool):
		return _err("Cython-Build-Tool fehlt: " + TOOL_PATH)
	_report_file = scripts_dir + "/.cython_report.json"
	DirAccess.remove_absolute(_report_file)
	var argv := PackedStringArray([venv_py, tool, "--scripts-dir", scripts_dir, "--report", _report_file])
	if not stems.is_empty():
		argv.append("--stems")
		argv.append(",".join(stems))
	if force:
		argv.append("--force")
	_pid = BridgeProcessManager.spawn(argv)
	if _pid < 0:
		return _err("Cython-Build-Prozess konnte nicht gestartet werden.")
	_busy = true
	_start_ms = Time.get_ticks_msec()
	return {"pending": true}

## Muss pro Frame aufgerufen werden (Facade-_process), solange is_busy().
func tick() -> void:
	if not _busy:
		return
	# Die Report-Datei wird vom Tool erst ATOMAR (os.replace) nach Abschluss
	# angelegt - ihr Erscheinen bedeutet "fertig, Inhalt vollstaendig".
	if FileAccess.file_exists(_report_file):
		var res := _read_report()
		_busy = false
		finished.emit(res)
		return
	if not OS.is_process_running(_pid):
		var code: int = OS.get_process_exit_code(_pid)
		_busy = false
		finished.emit(_err("Cython-Build-Prozess endete ohne Report (Exit %d)." % code))
		return
	if Time.get_ticks_msec() - _start_ms > TIMEOUT_MS:
		OS.kill(_pid)
		_busy = false
		finished.emit(_err("Cython-Build-Timeout (%d s)." % int(TIMEOUT_MS / 1000)))

## Blockierende Variante fuer Tests/CLI (NICHT aus dem Editor-UI nutzen -
## friert den Main-Thread fuer die Build-Dauer ein).
func build_blocking(scripts_dir: String, stems: PackedStringArray = PackedStringArray(), force := false) -> Dictionary:
	scripts_dir = ProjectSettings.globalize_path(scripts_dir)
	var venv_py := _find_venv_python(scripts_dir)
	if not FileAccess.file_exists(venv_py):
		return _err("venv-Python nicht gefunden: %s" % venv_py)
	var tool := ProjectSettings.globalize_path(TOOL_PATH)
	if not FileAccess.file_exists(tool):
		return _err("Cython-Build-Tool fehlt: " + TOOL_PATH)
	var argv := PackedStringArray([venv_py, tool, "--scripts-dir", scripts_dir])
	if not stems.is_empty():
		argv.append("--stems")
		argv.append(",".join(stems))
	if force:
		argv.append("--force")
	var out: Array = []
	var code := BridgeProcessManager.execute(argv, out, true)
	var stdout := ""
	for line in out:
		stdout += str(line) + "\n"
	var report := _parse_json_lines(stdout)
	if report.is_empty():
		return _err("Kein JSON-Report vom Build-Tool (Exit %d). Output: %s"
			% [code, stdout.substr(maxi(0, stdout.length() - 800))])
	return report

# ------------------------------------------------------------------ Internal

func _read_report() -> Dictionary:
	var f := FileAccess.open(_report_file, FileAccess.READ)
	if f == null:
		return _err("Report-Datei nicht lesbar: " + _report_file)
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return _err("Report-Datei enthaelt kein JSON-Objekt.")

## Letzte JSON-Zeile aus stdout extrahieren (Blocking-Pfad).
func _parse_json_lines(text: String) -> Dictionary:
	var lines := text.split("\n")
	for i in range(lines.size() - 1, -1, -1):
		var t := str(lines[i]).strip_edges()
		if t.begins_with("{"):
			var parsed = JSON.parse_string(t)
			if parsed is Dictionary:
				return parsed
	return {}

## Sucht die venv-Python vom Skript-Ordner aus (uebliche Layouts):
## <parent>/venv (Standard: python_bridge/scripts + python_bridge/venv),
## <scripts>/venv (scripts_dir = Workspace-Root), <grandparent>/venv.
func _find_venv_python(scripts_dir: String) -> String:
	for base in [scripts_dir.get_base_dir() + "/venv", scripts_dir + "/venv",
			scripts_dir.get_base_dir().get_base_dir() + "/venv"]:
		var py := _venv_python(base)
		if FileAccess.file_exists(py):
			return py
	return _venv_python(scripts_dir.get_base_dir() + "/venv")

func _venv_python(venv: String) -> String:
	if OS.get_name() == "Windows":
		return venv + "/Scripts/python.exe"
	return venv + "/bin/python"

func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "built": [], "skipped": [], "errors": [], "compiler": "none"}
