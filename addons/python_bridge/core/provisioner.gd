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
var _pip_log: String = ""

func start(cfg: Dictionary, target: Object, method: String) -> void:
	_cfg = cfg
	_target = target
	_method = method
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
			if _pip_done():
				_log.append("[PROV] Dependencies ok.")
				# Verify that every configured dependency is actually importable
				# in the venv (structured DEPENDENCY_ERROR on failure).
				if not _verify_imports():
					_fail("[PROV] Dependency verification failed. Details in log above.")
					return
				_finish(true)
			elif now - _start_ms > 300000:
				_fail("[PROV] pip install Timeout (300s). Log: " + _pip_log)

func is_done() -> bool:
	return _phase in [Phase.DONE_OK, Phase.DONE_ERR]

## The venv is only usable once its bundled pip exists: `venv/bin/python`
## appears early during `python -m venv`, while ensurepip bootstraps pip
## afterwards. Starting pip earlier fails with "No module named pip".
func _venv_ready() -> bool:
	if not FileAccess.file_exists(_venv_py):
		return false
	var sp := _site_packages()
	if sp == "":
		return false
	return DirAccess.dir_exists_absolute(sp + "/pip")

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

	# Schon alles da? Dann direkt fertig.
	if FileAccess.file_exists(_venv_py) and _pip_done():
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
	_log.append("[PROV] pip install (websockets + Entwickler-Dependencies) ...")
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
	BridgeProcessManager.spawn(argv)

## Verifies that the configured dependencies can be imported with the venv
## Python. Uses a short, blocking OS.execute call - this is acceptable here
## because provisioning runs once at startup and never on the hot path.
## Returns true when every dependency imports, false otherwise.
func _verify_imports() -> bool:
	var deps: Array = _cfg.get("dependencies", [])
	if deps.is_empty():
		return true
	var ok := true
	for dep in deps:
		var mod := str(dep).split("==")[0].split(">=")[0].split("<")[0].strip_edges()
		if mod == "":
			continue
		var out: Array = []
		var exit_code := BridgeProcessManager.execute(PackedStringArray([
			_venv_py, "-c", "import importlib; importlib.import_module(%s)" % JSON.stringify(mod)]),
			out, true)
		if exit_code != 0:
			ok = false
			_log.append("[PROV] FEHLT: dependency '%s' konnte nicht importiert werden" % mod)
	return ok

func _pip_done() -> bool:
	var sp := _site_packages()
	if sp == "":
		return false
	return DirAccess.dir_exists_absolute(sp + "/websockets") \
		or FileAccess.file_exists(sp + "/websockets-17.1.dist-info")

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
	var dep_path := ws + "/config/dependencies.txt"
	if FileAccess.file_exists(dep_path):
		var file := FileAccess.open(dep_path, FileAccess.READ)
		extra += file.get_as_text()
		file.close()
	for dep in _cfg.get("dependencies", []):
		extra += str(dep) + "\n"
	var out := FileAccess.open(req_file, FileAccess.WRITE)
	if out:
		out.store_string(base + extra)
		out.close()
