class_name BridgeProvisioner
extends RefCounted
## Idempotenter Provisionierer als POLL-basierte State-Machine (KEIN Thread).
##
## Hintergrund: `OS.execute` aus einem Worker-Thread haengt auf Windows bei
## bestimmten Kommandos (z. B. pip). Deshalb:
##   - Lange Befehle laufen ueber `OS.create_process` (nicht blockierend).
##   - Der Fortschritt wird pro Frame per `tick()` geprueft (Seiteneffekte:
##     venv-Python existiert? websockets in site-packages?).
##   - Fehler-Diagnose ueber `pip --log <datei>`.
## Alle Dateisystem-Operationen laufen ohnehin auf dem Main-Thread.

enum Phase { IDLE, VENV, PIP, DONE_OK, DONE_ERR }

var _cfg: Dictionary = {}
var _target: Object = null
var _method: String = ""

var _phase: int = Phase.IDLE
var _start_ms: int = 0
var _log: Array[String] = []

var _py: String = ""
var _venv_py: String = ""
var _req_file: String = ""
var _venv_probe_ms: int = -1500  # cooldown clock for the venv readiness probe
var _pip_log: String = ""
var _pip_pid: int = -1
var _pip_exit: int = -1
var _pip_seen_running: bool = false
var _verify_probe_ms: int = -10000  #Cooldown; erster Verify-Probe sofort
var _flatpak: bool = false

func start(cfg: Dictionary, target: Object, method: String) -> void:
	_cfg = cfg
	_target = target
	_method = method
	_flatpak = BridgeProcessManager.in_flatpak()
	if _flatpak:
		_log.append("[PROV] Flatpak erkannt - pip-Fortschritt wird per Verifikation gepollt.")
	_prepare()

func wait() -> void:
	# Kein Thread mehr - nur API-Kompatibilitaet.
	pass

## Muss pro Frame von der Instanz aufgerufen werden, solange _phase aktiv ist.
func tick() -> void:
	var now := Time.get_ticks_msec()
	match _phase:
		Phase.VENV:
			if _venv_ready():
				_log.append("[PROV] venv fertig.")
				_start_pip()
			elif now - _start_ms > 300000:
				_fail("[PROV] venv-Erstellung Timeout (300s). Befehl: %s -m venv %s" % [_py, _venv_py.get_base_dir().get_base_dir()])
		Phase.PIP:
			# flatpak-spawn --host: die Spawn-PID gehoert zum Host-Relay und
			# kehrt sofort zurueck - PID-Tracking ist hier strukturell nutzlos.
			# Die Phase endet stattdessen, wenn die Verifikation tatsaechlich
			# importierbare Pakete findet (Probes mit Cooldown). Im nicht-
			# Flatpak-Fall wartet die Phase wie gehabt auf das reale pip-Ende.
			var handled := false
			if _flatpak:
				if now - _verify_probe_ms >= 2000:
					_verify_probe_ms = now
					# _pip_done() (websockets vorhanden) deckt den Fall ohne
					# Skript-Deps ab: pip installiert websockets immer, das
					# Erscheinen markiert das Installationsende zuverlaessig.
					if _pip_done() and _verify_imports(true):
						_log.append("[PROV] Dependencies ok.")
						_finish(true)
						handled = true
			elif _pip_finished():
				handled = true
				if _pip_exit == 0:
					_log.append("[PROV] Dependencies ok.")
					# Verify that every configured dependency is actually
					# importable in the venv (structured DEPENDENCY_ERROR).
					if not _verify_imports():
						_fail("[PROV] Dependency verification failed. Details in log above.")
						return
					_finish(true)
				else:
					_fail("[PROV] pip install fehlgeschlagen (Exit %d). Log: %s" % [_pip_exit, _pip_log])
			if not handled and now - _start_ms > 300000:
				_fail("[PROV] pip install Timeout (300s). Log: " + _pip_log)

func is_done() -> bool:
	return _phase in [Phase.DONE_OK, Phase.DONE_ERR]

## The venv is only usable once its bundled pip exists: `venv/bin/python`
## appears early during `python -m venv`, while ensurepip bootstraps pip
## afterwards. Starting pip earlier fails with "No module named pip".
## A bare folder check is NOT enough: pip's vendor tree is written over
## several ticks, so a half-written pip can exist (crash:
## "No module named pip._vendor.pyparsing.util"). We therefore probe with
## a real import and a cooldown between probes (no threads, no busy-wait).
func _venv_ready() -> bool:
	if not FileAccess.file_exists(_venv_py):
		return false
	var now := Time.get_ticks_msec()
	if now - _venv_probe_ms < 1500:
		return false  # cooldown: give ensurepip time between probes
	_venv_probe_ms = now
	var out: Array = []
	var code := "import pip, pip._internal.cli.main; print('ok')"
	var ec := BridgeProcessManager.execute(PackedStringArray([
		_venv_py, "-c", code]), out, true)
	if ec == 0:
		return true
	_log.append("[PROV] venv-Probe noch nicht bereit (pip-Import), warte ...")
	return false

func _prepare() -> void:
	var ws: String = str(_cfg.get("workspace_fs",
		ProjectSettings.globalize_path(str(_cfg.get("workspace_dir", "res://python_bridge")))))
	var venv := ws + "/venv"
	var cfg_dir := ws + "/config"
	var scripts_dir := ws + "/scripts"
	var tmp_dir := ws + "/tmp"

	DirAccess.make_dir_recursive_absolute(scripts_dir)
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	DirAccess.make_dir_recursive_absolute(cfg_dir)
	# Der venv-Ordner enthaelt tausende Paketdateien (inkl. Non-Resource-
	# Fixtures wie WAVs), die Godot sonst als Assets importieren will.
	# .gdignore nimmt venv und tmp aus dem Import-Scan heraus; FileAccess
	# ist davon nicht betroffen.
	DirAccess.make_dir_recursive_absolute(venv)
	for rel in ["venv/.gdignore", "tmp/.gdignore"]:
		var f := FileAccess.open(ws + "/" + rel, FileAccess.WRITE)
		if f:
			f.close()

	_py = _detect_python(str(_cfg.get("python_executable", "")))
	if _py == "":
		_fail("[PROV] Kein Python gefunden. Setze python_executable oder installiere Python 3.")
		return
	if not _check_version(_py):
		_fail("[PROV] Python >= 3.8 wird benoetigt.")
		return

	_venv_py = _venv_python(venv)
	_copy_bridge_python(ws + "/bridge")
	_req_file = cfg_dir + "/requirements_combined.txt"
	_pip_log = tmp_dir + "/pip.log"
	_write_requirements(_req_file)

	# Schon alles da? Dann direkt fertig - AUSSER neu deklarierte
	# Skript-Dependencies (__bridge_deps__) fehlen noch in der venv.
	if FileAccess.file_exists(_venv_py) and _pip_done():
		if not _verify_imports():
			_log.append("[PROV] Neue Skript-Dependencies fehlen - pip-Lauf noetig.")
			_start_pip()
			return
		_log.append("[PROV] venv und Dependencies bereits vorhanden.")
		_finish(true)
		return

	if FileAccess.file_exists(_venv_py):
		_log.append("[PROV] venv existiert bereits.")
		_start_pip()
	else:
		_log.append("[PROV] Erstelle venv ...")
		_phase = Phase.VENV
		_start_ms = Time.get_ticks_msec()
		BridgeProcessManager.spawn(PackedStringArray([_py, "-m", "venv", venv]))

func _start_pip() -> void:
	_log.append("[PROV] pip install (websockets + Skript-Dependencies) ...")
	_phase = Phase.PIP
	_start_ms = Time.get_ticks_msec()
	var args := PackedStringArray([
		"-m", "pip", "install",
		"--disable-pip-version-check", "--no-input",
		"--log", _pip_log,
		"-q", "-r", _req_file,
	])
	var argv := PackedStringArray([_venv_py])
	argv.append_array(args)
	_pip_pid = BridgeProcessManager.spawn(argv)
	_pip_exit = -1
	_pip_seen_running = false
	_verify_probe_ms = -10000  # erster Verify-Probe sofort (Flatpak-Pfad)
	if _pip_pid <= 0:
		_fail("[PROV] pip konnte nicht gestartet werden.")

## True, wenn der pip-Prozess beendet ist (Exit-Code wird dann in
## _pip_exit geschrieben). Kein Dateisystem-Proxy: nur das reale Ende des
## Installationsprozesses schliesst die Phase ab. Ein kurzes Grace-Fenster
## fängt den Spawn-Race ab (is_process_running kann einen Tick zu früh
## false liefern, bevor der Prozess registriert ist).
func _pip_finished() -> bool:
	if _pip_pid <= 0:
		return true
	if OS.has_method("is_process_running") and OS.is_process_running(_pip_pid):
		_pip_seen_running = true
		return false
	if not _pip_seen_running and Time.get_ticks_msec() - _start_ms < 2000:
		return false  # Spawn-Registrierung abwarten
	_pip_exit = OS.get_process_exit_code(_pip_pid)
	return true

## Verifies that every combined requirement is present in the venv's
## site-packages (package dir OR *.dist-info - pip's own install record).
##
## Bewusst KEIN Import-Probe mehr per OS.execute: In der Flatpak-Sandbox
## liefert der Umweg ueber flatpak-spawn --host unzuverlaessige Exit-Codes,
## wodurch eine erfolgreiche Installation als fehlend galt (Timeout trotz
## fertigem pip - pip.log beweist "Requirement already satisfied"). Der
## Dateisystem-Nachweis ist shell-agnostisch und genau.
## Restrisiko (Halbgeschriebenes im Extraktionsfenster) deckt der
## Executor-Dependency-Gate zur Laufzeit ab.
## `quiet=true` unterdrueckt FEHLT-Logzeilen (Polling wuerde sie spammen).
func _verify_imports(quiet := false) -> bool:
	# Alle kombinierten Requirements pruefen (inkl. __bridge_deps__ und
	# dependencies.txt), nicht nur die configure()-Liste.
	var deps: Array = []
	for spec in PythonBridgeDependencyManager.combined_requirements(
			str(_cfg.get("workspace_fs", "")), _cfg.get("dependencies", PackedStringArray())):
		deps.append(spec)
	if deps.is_empty():
		return true
	var sp := _site_packages()
	if sp == "":
		if not quiet:
			_log.append("[PROV] site-packages nicht auffindbar.")
		return false
	var ok := true
	for dep in deps:
		var mod := str(dep).split("==")[0].split(">=")[0].split("<")[0].strip_edges()
		if mod == "":
			continue
		if not _dist_present(sp, mod):
			ok = false
			if not quiet:
				_log.append("[PROV] FEHLT: dependency '%s' nicht in site-packages" % mod)
	return ok

## True, wenn ein Paket im site-packages-Ordner nachweisbar installiert
## ist: Paketverzeichnis ODER pip-eigene *.dist-info (Modulname als
## Praefix, case-insensitiv). Wird von _pip_done UND _verify_imports
## genutzt (websockets inklusive - keine hartkodierte Version mehr).
func _dist_present(sp: String, mod: String) -> bool:
	if mod == "":
		return false
	if DirAccess.dir_exists_absolute(sp + "/" + mod):
		return true
	var dir := DirAccess.open(sp)
	if dir == null:
		return false
	var prefix := mod.to_lower() + "-"
	var found := false
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.to_lower().begins_with(prefix) and entry.ends_with(".dist-info"):
			found = true
			break
		entry = dir.get_next()
	dir.list_dir_end()
	return found

func _pip_done() -> bool:
	var sp := _site_packages()
	if sp == "":
		return false
	return _dist_present(sp, "websockets")

func _site_packages() -> String:
	if _venv_py == "":
		return ""
	var venv := _venv_py.get_base_dir().get_base_dir()
	if OS.get_name() == "Windows":
		return venv + "/Lib/site-packages"
	var lib := venv + "/lib"
	var dir := DirAccess.open(lib)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and entry.begins_with("python"):
			return lib + "/" + entry + "/site-packages"
		entry = dir.get_next()
	return ""

func _finish(ok: bool) -> void:
	_phase = Phase.DONE_OK if ok else Phase.DONE_ERR
	if _target:
		_target.call(_method, ok, "\n".join(_log))

func verified_dependencies() -> PackedStringArray:
	"""Kleingeschriebene Import-Namen der kombinierten Requirements (nach
	erfolgreicher Provisionierung alle importierbar). Die Instanz meldet
	diese Liste im HELLO an den Python-Server."""
	var out := PackedStringArray()
	for spec in PythonBridgeDependencyManager.combined_requirements(
			str(_cfg.get("workspace_fs", "")), _cfg.get("dependencies", PackedStringArray())):
		var name := str(spec).split("==")[0].split(">")[0].split("<")[0].strip_edges().to_lower()
		if name != "":
			out.append(name)
	return out

func _fail(msg: String) -> void:
	_log.append(msg)
	_finish(false)

func _detect_python(override: String) -> String:
	# 1) Explizit konfigurierte python_executable hat immer Vorrang.
	if override != "" and FileAccess.file_exists(override):
		return override
	# 2) PYTHON_PATH-Umgebungsvariable als Alternative.
	if OS.has_environment("PYTHON_PATH") and FileAccess.file_exists(OS.get_environment("PYTHON_PATH")):
		return OS.get_environment("PYTHON_PATH")
	# 2.5) Flatpak-Sandbox: der PATH im Container enthaelt nur den Runtime-
	# Interpreter, dessen site-packages nicht mit einer vom Host erstellten
	# venv kompatibel sind. Den Host-Python zuerst probieren.
	if BridgeProcessManager.in_flatpak():
		if FileAccess.file_exists("/run/host/usr/bin/python3"):
			return "/run/host/usr/bin/python3"
		var host_py := _which_unix("python3")
		if host_py != "":
			return host_py
	# 3) Direkte PATH-Suche - braucht weder `sh` noch `where` und
	#    funktioniert damit auch auf Windows ohne Shell-Werkzeuge.
	var found := _search_path_for_python()
	if found != "":
		return found
	# 4) Plattform-Fallback ueber das jeweilige Kommando-Werkzeug.
	if OS.get_name() == "Windows":
		return _which_windows("python")
	return _which_unix("python3")

func _search_path_for_python() -> String:
	var path_env := OS.get_environment("PATH")
	if path_env == "":
		return ""
	var sep := ";" if OS.get_name() == "Windows" else ":"
	var exe_names: Array[String] = ["python.exe", "python3.exe", "python", "python3", "py.exe", "py"]
	for dir_path in path_env.split(sep, false):
		if dir_path == "":
			continue
		for exe in exe_names:
			var full: String = dir_path + "/" + exe
			if FileAccess.file_exists(full):
				return full
	return ""

func _which_windows(cmd: String) -> String:
	# where.exe ist ein echtes Standalone-Programm in System32 (kein CMD-Builtin).
	var out: Array = []
	if OS.execute("where", PackedStringArray([cmd]), out, false) == 0 and not out.is_empty():
		return str(out[0]).strip_edges()
	return ""

func _which_unix(cmd: String) -> String:
	var out: Array = []
	if BridgeProcessManager.execute(PackedStringArray(["sh", "-lc", "command -v " + cmd]), out, false) == 0 and not out.is_empty():
		return str(out[0]).strip_edges()
	return ""

func _check_version(py: String) -> bool:
	var out: Array = []
	if BridgeProcessManager.execute(PackedStringArray([py, "--version"]), out, true) != 0:
		return false
	var version := (str(out[0]) if not out.is_empty() else "").strip_edges()
	if version == "":
		return false
	var regex := RegEx.new()
	regex.compile("[0-9]+\\.[0-9]+")
	var match := regex.search(version)
	if not match:
		return false
	var parts := match.get_string().split(".")
	if int(parts[0]) < 3:
		return false
	if int(parts[0]) == 3 and int(parts[1]) < 8:
		return false
	_log.append("[PROV] Python: " + py + " (" + version + ")")
	return true

func _venv_python(venv: String) -> String:
	if OS.get_name() == "Windows":
		return venv + "/Scripts/python.exe"
	return venv + "/bin/python"

func _copy_bridge_python(dst: String) -> void:
	var src := str(_cfg.get("bridge_python_dir", "res://addons/python_bridge/python"))
	if not DirAccess.dir_exists_absolute(src):
		_log.append("[PROV] Python-Quellordner fehlt: " + src)
		return
	_copy_dir_recursive(src, dst)

func _copy_dir_recursive(src: String, dst: String) -> void:
	var dir := DirAccess.open(src)
	if dir == null:
		return
	# Build-Artifacts nie mitkopieren: __pycache__ enthaelt binaere .pyc-
	# Dateien (kein gueltiges UTF-8) und gehoert in die Distribution nicht
	# hinein - Python erzeugt den Cache im Ziel bei Bedarf selbst.
	if src.get_file() == "__pycache__":
		return
	DirAccess.make_dir_recursive_absolute(dst)
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			if entry != "__pycache__":
				_copy_dir_recursive(src + "/" + entry, dst + "/" + entry)
		else:
			if entry.ends_with(".pyc"):
				entry = dir.get_next()
				continue
			var fin := FileAccess.open(src + "/" + entry, FileAccess.READ)
			if fin:
				# Binaersicher: Rohbytes 1:1 uebernehmen (statt get_as_text/
				# store_string, das an Nicht-UTF-8-Bytes scheitert und pro
				# invalidem Byte einen Unicode-parsing-error spammt).
				var raw := fin.get_buffer(fin.get_length())
				fin.close()
				var fout := FileAccess.open(dst + "/" + entry, FileAccess.WRITE)
				if fout:
					fout.store_buffer(raw)
					fout.close()
		entry = dir.get_next()

func _write_requirements(req_file: String) -> void:
	var base := "websockets>=11\n"
	var extra := ""
	var ws: String = str(_cfg.get("workspace_fs",
		ProjectSettings.globalize_path(str(_cfg.get("workspace_dir", "res://python_bridge")))))
	# NEU: __bridge_deps__-Deklarationen aus allen Workspace-Skripten sind
	# Teil der Requirements (Single Source of Truth im Python-Code).
	for dep in PythonBridgeDependencyManager.combined_requirements(
			ws, _cfg.get("dependencies", PackedStringArray())):
		extra += str(dep) + "\n"
	var out := FileAccess.open(req_file, FileAccess.WRITE)
	if out:
		out.store_string(base + extra)
		out.close()
