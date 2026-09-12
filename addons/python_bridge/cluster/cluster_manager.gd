class_name ClusterManager
extends Node
## Cluster-Manager (V1): verteilt Python-Aufgaben auf andere PCs im LAN.
##
## Diese Node ist der Einstiegspunkt im Godot-Node-System:
##
##     ClusterManager (Node)
##     ├── Worker(s)     # automatisch erkannte Rechner (Server Manager)
##     ├── Task(s)       # Python-Aufgaben (bestehendes Bridge-Task-Idiom)
##     └── Scheduler     # Router + Dispatcher + Transport
##
## Sie erfindet **keine** zweite Python-Welt: Der Manager entscheidet nur,
## WO eine vorhandene Python-Aufgabe laeuft, und nutzt fuer die Uebertragung
## den bestehenden Orchestrator-Kern (Server-/Task-Manager, Router, Dispatcher)
## mit dem Worker als Ausfuehrungsort.
##
## Benutzung (Beispiel):
##
##     var cluster := ClusterManager.new()
##     add_child(cluster)
##     cluster.task_finished.connect(_on_task_finished)
##     var id := cluster.submit_script_file("res://python_bridge/scripts/benchmark.py",
##             {"command": "call", "function": "ping", "args": ["Hallo"]})
##
## Ohne weitere Konfiguration findet der Manager Worker automatisch per
## LAN-Discovery. Ein Token ist nur noetig, wenn der Worker die automatische
## Kopplung abgeschaltet hat.

signal worker_discovered(server_id: String, info: Dictionary)
signal worker_needs_token(server_id: String, info: Dictionary)
signal worker_connected(server_id: String)
signal worker_disconnected(server_id: String, reason: String)
signal worker_lost(server_id: String)
signal server_state_changed(server_id: String, state: int)
signal task_progress(task_id: String, stage: String, fraction: float, text: String)
signal task_finished(task_id: String, ok: bool, value: Variant, error: String)
## Datei-Transfer (Phase 6-8): Fortschritt und Ende, fuer die Oberflaeche.
signal file_transfer_progress(server_id: String, file_id: String, sent: int, total: int)
signal file_transfer_finished(server_id: String, file_id: String, ok: bool, reason: String)
signal files_changed()
signal log_event(text: String)
## TLS-Vertrauensproblem (z. B. selbstsigniertes Zertifikat ohne Freigabe).
## Die Oberflaeche zeigt daraus einen Hinweis mit Loesung an.
signal tls_problem(server_id: String, hint: String)

const CONFIG_PATH := "user://cluster_workers.json"

## Dateiendungen, die als Projektinhalt uebertragen werden (Textdateien).
const PROJECT_SUFFIXES := [".py", ".pyx", ".pxd", ".pxi", ".txt", ".toml",
	".cfg", ".ini", ".json", ".c", ".h", ".cpp", ".cc", ".hpp", ".md",
	".rst", ".yaml", ".yml"]
const IGNORED_DIRS := ["__pycache__", "venv", ".venv", "env", "build", "dist",
	"node_modules", "site-packages"]
const ENTRY_CANDIDATES := ["main.py", "app.py", "run.py", "start.py", "__main__.py"]
const MAX_PROJECT_FILES := 512
## So viele Ergebnisse werden im Speicher behalten (danach aelteste zuerst).
const MAX_STORED_RESULTS := 200
const MAX_FILE_CHARS := 4 * 1024 * 1024
const MAX_TOTAL_CHARS := 24 * 1024 * 1024

## Discovery im LAN automatisch starten.
@export var auto_discover: bool = true
@export var discovery_port: int = ClusterDiscovery.DEFAULT_PORT
## Erkannte Worker ohne Zutun verbinden (Token kommt aus dem Beacon oder dem
## gespeicherten Token).
@export var auto_connect: bool = true
## Fallback-Token, falls ein Worker kein Token im Beacon mitschickt.
@export var worker_token: String = ""
## Selbstsignierte Zertifikate erlauben (wss:// ohne Identitaetspruefung).
## Bewusst aus: ohne diese Freigabe scheitert ein selbstsignierter Worker
## **sichtbar**, statt unbemerkt ungeprueft zu verbinden.
@export var tls_allow_self_signed: bool = false
## Optionales Vertrauenszertifikat (PEM) fuer alle wss-Worker, deren Worker keine
## eigene Datei zugeordnet ist.
@export var tls_ca_path: String = ""
## Worker/Tasks zusaetzlich als Kind-Nodes im Szenenbaum spiegeln.
@export var mirror_scene: bool = false
## Wo gemerkte Worker + Tokens liegen ("merkt sich" Rechner ueber Neustarts).
@export var state_path: String = CONFIG_PATH

## Grenzwerte, die vor `setup()` gesetzt werden koennen (siehe `configure()`).
var config_overrides: Dictionary = {}

## Wie oft wartende Aufgaben selbsttaetig verteilt werden (Millisekunden).
const DISPATCH_INTERVAL_MS := 250
var _next_dispatch_ms: int = 0

var config: OrchestratorConfig
var servers: OrchestratorServerManager
var tasks: OrchestratorTaskManager
var router: OrchestratorRouter
var dispatcher: OrchestratorDispatcher
var transport: OrchestratorTransport
var discovery: ClusterDiscovery
## Datei-Registry + Chunk-Transfer fuer grosse Eingaben (Phase 6-8).
var file_registry: OrchestratorFileRegistry
var file_transfer: OrchestratorFileTransfer

var _tokens: Dictionary = {}        # server_id -> token (persistiert)
var _known: Dictionary = {}         # server_id -> {url, name, ca} (persistiert)
var _results: Dictionary = {}       # task_id -> {ok, value, error}
var _mirror_root: Node = null


func _ready() -> void:
	setup()


## Initialisiert Kern, gespeicherten Zustand und Discovery. Idempotent, damit
## die Node auch ohne Szenenbaum (Tests, Werkzeuge) benutzt werden kann.
func setup() -> void:
	if config != null:
		return
	_build_core()
	_load_state()
	if auto_discover:
		start_discovery(discovery_port)


func _process(_delta: float) -> void:
	poll()


# ---------------------------------------------------------------- Aufbau
## Setzt Grenzwerte (Timeouts, Limits) - vor oder nach `setup()` aufrufbar.
## Damit muss die Klasse selbst nicht mit jeder Option wachsen.
func configure(overrides: Dictionary) -> void:
	config_overrides.merge(overrides, true)
	if config != null:
		config.apply_dict(overrides)


## Selbstsignierte Zertifikate erlauben/verbieten.
##
## Der Wechsel wirkt sofort: betroffene wss-Worker werden neu verbunden, damit
## die Einstellung nicht erst beim naechsten Neustart greift.
func set_tls_allow_self_signed(enabled: bool) -> void:
	tls_allow_self_signed = enabled
	if config != null:
		config.tls_allow_self_signed = enabled
	_log("Selbstsignierte Zertifikate: %s" % ("erlaubt" if enabled else "nicht erlaubt"))
	_save_state()
	_reconnect_secure()


## Vertrauenszertifikat (PEM) fuer **einen** Worker hinterlegen oder entfernen.
func set_worker_ca(server_id: String, ca_path: String) -> void:
	var known := _known.get(server_id, {}) as Dictionary
	var url := str(known.get("url", ""))
	if url == "":
		var info := _worker_info(server_id)
		url = str(info.get("url", ""))
	if url == "":
		_log("Worker %s unbekannt - Vertrauensdatei nicht gesetzt." % server_id)
		return
	if ca_path == "":
		known.erase("ca")
	else:
		known["ca"] = ca_path
	_known[server_id] = known
	_save_state()
	if ca_path != "":
		var fingerprint := OrchestratorTransport.certificate_fingerprint(ca_path)
		_log("Vertrauensdatei fuer %s gesetzt%s" % [server_id,
			(" (SHA-256 %s)" % fingerprint) if fingerprint != "" else ""])
	# Nur verschluesselte Worker neu aufbauen - Klartext-Worker sind unberuehrt.
	if transport.is_secure(server_id) or url.begins_with("wss://"):
		_reconnect_worker(server_id)


## Vertrauenszertifikat eines Workers (Datei im Benutzerverzeichnis bevorzugt).
func _ca_for(server_id: String) -> String:
	var known := _known.get(server_id, {}) as Dictionary
	var own := str(known.get("ca", ""))
	if own != "":
		return own
	return str(tls_ca_path)


## Alle verschluesselten Worker neu aufbauen (nach Aenderung der TLS-Optionen).
func _reconnect_secure() -> void:
	for server_id in worker_ids():
		if _ca_for(server_id) != "" or _worker_is_secure(server_id):
			_reconnect_worker(server_id)


func _worker_is_secure(server_id: String) -> bool:
	if transport.is_secure(server_id):
		return true
	return str(_worker_info(server_id).get("url", "")).begins_with("wss://")


func _reconnect_worker(server_id: String) -> void:
	var info := _worker_info(server_id)
	if info.is_empty():
		return
	if transport.has_worker(server_id):
		transport.remove_worker(server_id)
	_connect_with(info, str(_tokens.get(server_id, str(info.get("token", "")))))


func _build_core() -> void:
	config = OrchestratorConfig.from_dict(config_overrides)
	if worker_token != "":
		config.worker_token = worker_token
	# @export-Werte gelten nur, wenn sie nicht per configure() ueberschrieben wurden.
	if not config_overrides.has("tls_allow_self_signed"):
		config.tls_allow_self_signed = tls_allow_self_signed
	if not config_overrides.has("tls_ca_path") and tls_ca_path != "":
		config.tls_ca_path = tls_ca_path
	servers = OrchestratorServerManager.new(config)
	tasks = OrchestratorTaskManager.new(config)
	router = OrchestratorRouter.new(servers, config)
	dispatcher = OrchestratorDispatcher.new(servers, tasks, config, router)
	transport = OrchestratorTransport.new(servers, dispatcher, config)
	# Datei-Transfer anschliessen: ab jetzt kann eine Aufgabe auf ihre
	# Eingabedateien warten (WAITING_FOR_DATA), statt sie im Auftrag mitzufuehren.
	file_registry = OrchestratorFileRegistry.new()
	file_transfer = OrchestratorFileTransfer.new(file_registry)
	transport.set_file_transfer(file_transfer)
	dispatcher.file_support = true
	dispatcher.data_requested.connect(_on_data_requested)
	file_transfer.task_files_ready.connect(_on_task_files_ready)
	file_transfer.task_data_failed.connect(_on_task_data_failed)
	file_transfer.transfer_progress.connect(_on_transfer_progress)
	file_transfer.transfer_finished.connect(_on_transfer_finished)
	file_registry.location_changed.connect(_on_file_location_changed)

	dispatcher.task_completed.connect(_on_task_completed)
	dispatcher.task_failed.connect(_on_task_failed)
	dispatcher.task_dispatched.connect(_on_task_dispatched)
	dispatcher.task_progress.connect(_on_task_progress)
	transport.worker_connected.connect(_on_worker_connected)
	transport.worker_disconnected.connect(_on_worker_disconnected)
	transport.send_failed.connect(_on_send_failed)
	transport.tls_problem.connect(_on_tls_problem)
	servers.server_state_changed.connect(_on_server_state_changed)


## Nur fuer Tests/Demo: der Router wird normal ueber `_build_core` erzeugt.
## Wird die Klasse hier falsch referenziert, faellt es sofort beim Start auf.
func router_instance() -> OrchestratorRouter:
	return router


func start_discovery(p_port: int = -1) -> bool:
	if discovery == null:
		discovery = ClusterDiscovery.new()
		discovery.worker_found.connect(_on_discovery_found)
		discovery.worker_updated.connect(_on_discovery_updated)
		discovery.worker_lost.connect(_on_discovery_lost)
	var ok := discovery.start(p_port)
	if ok:
		_log("Discovery gestartet (UDP-Port %d)." % discovery.port)
		# Gespeicherte Worker sofort wieder aufbauen (auch ohne Beacon).
		_reconnect_known()
	else:
		_log("Discovery nicht moeglich - Worker bitte direkt hinzufuegen.")
	return ok


func stop_discovery() -> void:
	if discovery != null:
		discovery.stop()
		_log("Discovery gestoppt.")


func poll() -> void:
	if discovery != null:
		discovery.poll()
	transport.poll()
	if file_transfer != null:
		file_transfer.poll()
	dispatcher.tick()
	_dispatch_due()


## Wartende Aufgaben selbsttaetig verteilen.
##
## Ohne das bliebe eine Aufgabe, die nach einem Worker-Ausfall oder Timeout
## zurueck in die Queue kam, dort liegen, bis der Benutzer von Hand eine neue
## Aufgabe startet - sie wuerde also nie wieder ausgefuehrt. Deshalb wird hier
## regelmaessig (nicht jeden Frame) verteilt, sobald es etwas zu verteilen gibt.
func _dispatch_due() -> void:
	var now := Time.get_ticks_msec()
	if now < _next_dispatch_ms:
		return
	_next_dispatch_ms = now + DISPATCH_INTERVAL_MS
	if tasks.queued_by_priority().is_empty():
		return
	if servers.available_servers().is_empty():
		return
	dispatcher.dispatch(now)


# ---------------------------------------------------------------- Worker
## Manueller Weg (Gastnetz ohne Broadcast): URL + Token direkt eintragen.
## Der Name ist nur ein Anzeigename; die Server-ID wird daraus abgeleitet.
## `ca_path` (optional): PEM-Zertifikat des Workers anheften (wss://).
func add_worker(url: String, token: String, name := "", ca_path := "") -> String:
	var host := OrchestratorTransport._host_of(url)
	var ws_port := OrchestratorTransport._port_of(url)
	if host == "" or ws_port <= 0:
		_log("Ungueltige Worker-Adresse: %s" % url)
		return ""
	var server_id := _unique_id(ClusterDiscovery.safe_id(name if name != "" else host))
	var known := {"url": url, "name": name if name != "" else server_id}
	if ca_path != "":
		known["ca"] = ca_path
	_known[server_id] = known
	if token != "":
		_tokens[server_id] = token
	_save_state()
	_connect(server_id, url, name if name != "" else server_id, -1, token, ca_path)
	return server_id


func disconnect_worker(server_id: String) -> void:
	if transport.has_worker(server_id):
		transport.remove_worker(server_id)
	_log("Worker %s getrennt." % server_id)


## Token fuer einen bereits entdeckten Worker nachtragen (Dialog im Panel).
func set_worker_token(server_id: String, token: String) -> void:
	var info := _worker_info(server_id)
	if info.is_empty():
		return
	if token != "":
		_tokens[server_id] = token
	else:
		_tokens.erase(server_id)
	_save_state()
	if token != "":
		_connect_with(info, token)


func worker_ids() -> Array[String]:
	var ids: Array[String] = []
	if discovery != null:
		ids = discovery.worker_ids()
	for id in transport.worker_ids():
		if not ids.has(id):
			ids.append(id)
	return ids


## Momentaufnahme aller bekannten Worker (entdeckt und/oder verbunden).
func workers_snapshot() -> Array:
	var out: Array = []
	for server_id in worker_ids():
		var server := servers.get_server(server_id)
		var info := _worker_info(server_id)
		var entry := {
			"server_id": server_id,
			"name": server.name if server != null else str(info.get("name", server_id)),
			"url": str(info.get("url", "")),
			"host": server.host if server != null else str(info.get("host", "")),
			"port": server.port if server != null else int(info.get("port", 0)),
			"discovered": discovery != null and discovery.has_worker(server_id),
			"connected": transport.is_connected_to(server_id),
			"secure": _worker_is_secure(server_id),
			"tls": transport.tls_label(server_id) if transport.has_worker(server_id) \
				else ("wss" if _worker_is_secure(server_id) else "offen"),
			"fingerprint": _fingerprint_of(server_id),
			"ca_path": _ca_for(server_id),
			"has_token": _tokens.has(server_id) or str(info.get("token", "")) != "",
			"state": server.state if server != null else OrchestratorServer.NodeState.DISCONNECTED,
			"state_text": _state_text(server.state if server != null else -1),
			"cpu": server.cpu_pct if server != null else 0.0,
			"ram": server.ram_pct if server != null else 0.0,
			"latency": server.latency_ms if server != null else 0.0,
			"queue_used": server.effective_queue_used() if server != null else 0,
			"queue_capacity": server.queue_capacity if server != null else 0,
		}
		out.append(entry)
	return out


func worker_count() -> int:
	return worker_ids().size()


func connected_worker_count() -> int:
	var n := 0
	for id in transport.worker_ids():
		if transport.is_connected_to(id):
			n += 1
	return n


# ---------------------------------------------------------------- Tasks
## Uebergibt eine Python-Aufgabe an den Cluster.
## `script` ist der Name der Aufgabe (wie in der bestehenden Bridge), die
## Ausfuehrungsparameter stecken in `options`:
##
##     command   "run" (input -> result) oder "call" (Funktion aufrufen)
##     input     Dictionary fuer `run`
##     function  Funktionsname fuer `call`
##     args      Array-Argumente fuer `call`
##     kwargs    Dictionary-Argumente fuer `call`
##     source    optionaler Python-Quelltext (wird zum Worker uebertragen)
##     priority  OrchestratorTask.Priority
##     target    gewuenschter Worker ("" = automatisch)
func submit_script(script: String, options: Dictionary = {}) -> String:
	var priority := _as_priority(options.get("priority", OrchestratorTask.Priority.NORMAL))
	var target := str(options.get("target", ""))
	# Eingabedateien (§11): entweder schon registrierte IDs oder (bequemer)
	# lokale Pfade, die hier registriert werden.
	var required: Array = []
	var listed: Variant = options.get("required_files", null)
	if listed is Array:
		required = (listed as Array).duplicate()
	var paths: Variant = options.get("input_files", null)
	if paths is Array and not (paths as Array).is_empty():
		for file_id in register_files(paths):
			required.append(file_id)
	var task := dispatcher.submit(script, priority, required, {}, target)
	if task == null:
		_log("Task '%s' konnte nicht erzeugt werden." % script)
		return ""
	task.meta["command"] = str(options.get("command", "run"))
	task.meta["input"] = options.get("input", {})
	task.meta["function"] = str(options.get("function", ""))
	task.meta["args"] = options.get("args", [])
	task.meta["kwargs"] = options.get("kwargs", {})
	task.meta["source"] = str(options.get("source", ""))
	if options.has("max_retries"):
		task.max_retries = maxi(int(options["max_retries"]), 0)
	# Der Worker bekommt nur logische IDs plus Anzeigename ("model.dat") -
	# niemals absolute Pfade des Hauptrechners (§15).
	if not required.is_empty():
		var entries: Array = []
		for file_id in required:
			entries.append({
				"file_id": str(file_id),
				"name": file_registry.name_of(str(file_id)),
			})
		task.meta["input_files"] = entries
	var files: Variant = options.get("files", null)
	if files is Dictionary and not (files as Dictionary).is_empty():
		# Projekt: Code + optionale Bauanleitung an den Worker.
		var size := JSON.stringify(files).to_utf8_buffer().size()
		if size > int(config.max_payload_bytes):
			_log("Projekt zu gross (%.1f MB, Limit %.1f MB) - bitte verkleinern." % [
				size / 1048576.0, config.max_payload_bytes / 1048576.0])
			tasks.remove_task(task.task_id)
			return ""
		task.meta["files"] = files
		task.meta["entry"] = str(options.get("entry", ""))
		task.meta["requirements"] = str(options.get("requirements", ""))
		task.meta["build"] = str(options.get("build", "auto"))
		_log("Projekt '%s': %d Datei(en), Einstieg '%s'." % [script,
			(files as Dictionary).size(), str(options.get("entry", ""))])
	_log("Task %s erstellt (%s)." % [task.task_id, script])
	dispatch_now()
	return task.task_id


## Uebergibt ein **Projekt** an den Cluster: mehrere Dateien, ein Einstieg und
## optional ein Build-Schritt (Cython/native Extension).
##
## Der Worker richtet Umgebung und Build selbst ein - der Aufrufer muss weder
## pip noch cython noch einen Compiler kennen.
func submit_project(files: Dictionary, options: Dictionary = {}) -> String:
	if files.is_empty():
		_log("Projekt ist leer - bitte einen Ordner mit Python-Dateien waehlen.")
		return ""
	var entry := str(options.get("entry", ""))
	if entry == "":
		entry = _guess_entry(files)
	if entry == "":
		_log("Keine Einstiegsdatei gefunden (erwartet z. B. main.py).")
		return ""
	var requirements := str(options.get("requirements", ""))
	if requirements == "":
		for name in ["requirements.txt", "Requirements.txt"]:
			if files.has(name):
				requirements = str(files[name])
				break
	var opts := options.duplicate(true)
	opts["files"] = files
	opts["entry"] = entry
	opts["requirements"] = requirements
	if not opts.has("build"):
		# auto = Build nur, wenn es .pyx/setup.py gibt.
		opts["build"] = "auto"
	var name := str(options.get("script", entry.get_basename()))
	return submit_script(name if name != "" else "projekt", opts)


## Bequemer Weg fuer die Oberflaeche: liest einen lokalen Projektordner
## (nur Textdateien) und uebergibt ihn wie `submit_project`.
func submit_project_dir(dir_path: String, options: Dictionary = {}) -> String:
	var collected := collect_project_dir(dir_path)
	if collected.is_empty():
		_log("Im Ordner '%s' wurden keine Python-Dateien gefunden." % dir_path)
		return ""
	var opts := options.duplicate(true)
	opts["files"] = collected["files"]
	if not opts.has("entry") and str(collected.get("entry", "")) != "":
		opts["entry"] = str(collected["entry"])
	if not opts.has("requirements") and str(collected.get("requirements", "")) != "":
		opts["requirements"] = str(collected["requirements"])
	return submit_project(collected["files"], opts)


## Liest einen Ordner als Projekt ein (gleiche Auswahl wie der Manager-Dialog).
## Liefert {"files": {...}, "entry": "...", "requirements": "..."}.
func collect_project_dir(dir_path: String) -> Dictionary:
	var abs := ProjectSettings.globalize_path(dir_path) if dir_path.begins_with("res://") \
		else dir_path
	var files: Dictionary = {}
	var state := {"total": 0, "truncated": false}
	_scan_dir(abs, "", files, state)
	if state["truncated"]:
		_log("Projektordner war zu gross - nur die ersten Dateien wurden uebernommen.")
	var requirements := ""
	for name in ["requirements.txt", "Requirements.txt"]:
		if files.has(name):
			requirements = str(files[name])
			break
	return {"files": files, "entry": _guess_entry(files), "requirements": requirements}


## Bequemer Weg: liest eine lokale Python-Datei und schickt den Quelltext als
## Inline-Source mit. Damit braucht der Worker **keine** vorbereiteten Ordner -
## der Manager liefert den Code selbst (V1-Vorgabe).
func submit_script_file(path: String, options: Dictionary = {}) -> String:
	var source := _read_python(path)
	if source == "":
		_log("Quelltext nicht lesbar: %s" % path)
		return ""
	var script := str(options.get("script", _script_name(path)))
	var opts := options.duplicate(true)
	opts["source"] = source
	return submit_script(script, opts)


func dispatch_now() -> int:
	return dispatcher.dispatch()


func cancel_task(task_id: String) -> bool:
	if file_transfer != null:
		file_transfer.cancel_task(task_id)
	return dispatcher.cancel(task_id)


# ---------------------------------------------------------------- Dateien (§11-§14)
## Registriert Eingabedateien (lokale Pfade) und liefert ihre IDs.
## Die ID **ist** der Inhalt (SHA-256): dieselbe Datei auf einem anderen
## Rechner wird erkannt - dann findet kein zweiter Transfer statt (§12).
func register_files(paths: Array) -> Array[String]:
	var ids: Array[String] = []
	for path in paths:
		var file_id := register_file(str(path))
		if file_id != "":
			ids.append(file_id)
	if not ids.is_empty():
		_log("%d Eingabedatei(en) registriert." % ids.size())
	return ids


## Registriert eine einzelne Datei und liefert ihre file_id ("" bei Fehler).
func register_file(path: String) -> String:
	if path.strip_edges() == "":
		return ""
	var abs := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	var file := FileAccess.open(abs, FileAccess.READ)
	if file == null:
		_log("Eingabedatei nicht lesbar: %s" % path)
		return ""
	var size := file.get_length()
	file.close()
	# Groesse **vor** der Pruefsumme begrenzen: das Hashen grosser Dateien
	# blockiert die Oberflaeche, und der Transfer wuerde die Datei ohnehin
	# ablehnen. Ein klarer Hinweis ist besser als minutenlanges Warten.
	if size > OrchestratorFileTransfer.MAX_FILE_BYTES:
		_log("Datei '%s' ist zu gross fuer den Transfer (%.0f MB, Limit %.0f MB)." % [
			abs.get_file(), size / 1048576.0,
			OrchestratorFileTransfer.MAX_FILE_BYTES / 1048576.0])
		return ""
	if size == 0:
		_log("Datei '%s' ist leer - bitte eine Datei mit Inhalt waehlen." % abs.get_file())
		return ""
	var digest := _sha256_file(abs)
	if digest == "":
		_log("Pruefsumme nicht berechenbar: %s" % path)
		return ""
	return file_registry.register(abs.get_file(), size, digest, abs)


## Bequemer Weg fuer die Oberflaeche: Quelldatei(en) mitgeben und die Aufgabe
## einreihen. Der Manager kuemmert sich um Hash, Uebertragung und Pruefung.
## Einstiegsdatei eines Projektordners bestimmen.
##
## Der Worker koennte das auch selbst raten, aber hier ist die Liste der
## denkbaren Einstiege bekannt (`ENTRY_CANDIDATES`) - und der Benutzer sieht in
## der Oberflaeche denselben Namen, den der Worker startet.
func guess_entry(files: Dictionary) -> String:
	if files.is_empty():
		return ""
	for candidate in ENTRY_CANDIDATES:
		if files.has(candidate):
			return candidate
	var top: Array[String] = []
	for name in files.keys():
		var text := str(name)
		if not text.contains("/") and text.ends_with(".py"):
			top.append(text)
	top.sort()
	if top.size() == 1:
		return top[0]
	return ""


## Prioritaet robust lesen: `int(null)` wuerde hier einen Laufzeitfehler werfen
## und die Aufgabe stillschweigend verschlucken. Unbekanntes faellt auf NORMAL
## zurueck, Grenzwerte werden gezogen.
static func _as_priority(value: Variant) -> int:
	if value is int:
		return clampi(int(value), OrchestratorTask.Priority.LOW, OrchestratorTask.Priority.HIGH)
	if value is float:
		return clampi(int(value), OrchestratorTask.Priority.LOW, OrchestratorTask.Priority.HIGH)
	if value is String and (value as String).is_valid_int():
		return clampi(int(value), OrchestratorTask.Priority.LOW, OrchestratorTask.Priority.HIGH)
	return OrchestratorTask.Priority.NORMAL


func submit_with_files(options: Dictionary, input_paths: Array) -> String:
	var ids := register_files(input_paths)
	if ids.is_empty():
		_log("Keine verwertbare Eingabedatei - Aufgabe nicht gestartet.")
		return ""
	var opts := options.duplicate(true)
	opts["required_files"] = ids
	var script := str(options.get("script", "aufgabe"))
	if script == "":
		script = "aufgabe"
	return submit_script(script, opts)


func file_snapshot() -> Array:
	return file_registry.describe_all() if file_registry != null else []


func file_stats() -> Dictionary:
	return file_registry.summary() if file_registry != null else {}


## SHA-256 streamend: grosse Dateien landen nie komplett im Speicher.
static func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return ""
	while true:
		var bytes := file.get_buffer(1024 * 1024)
		if bytes.is_empty():
			break
		ctx.update(bytes)
	file.close()
	var digest := ctx.finish()
	return digest.hex_encode()


func task_ids() -> Array[String]:
	var out: Array[String] = []
	for task in tasks.tasks():
		out.append((task as OrchestratorTask).task_id)
	return out


func get_task(task_id: String) -> OrchestratorTask:
	return tasks.get_task(task_id)


func task_snapshot(task_id: String) -> Dictionary:
	var task := tasks.get_task(task_id)
	if task == null:
		return {}
	return {
		"task_id": task.task_id,
		"script": task.python_task,
		"state": task.state,
		"state_text": OrchestratorTask.state_text(task.state),
		"server": task.assigned_server,
		"priority": OrchestratorTask.priority_text(task.priority),
		"attempts": task.attempts,
		"max_retries": task.max_retries,
		"ack": task.ack_received,
		"error": task.error,
		"error_hint": task.error_hint,
		"result": task.result,
		"progress": task.progress,
		"stage": task.progress_stage,
		"progress_text": task.progress_text,
		"build": task.build,
		"is_project": task.meta.has("files"),
	}


func stats() -> Dictionary:
	var out := dispatcher.stats()
	if file_transfer != null:
		out["transfers"] = file_transfer.stats()
		out["files"] = file_registry.summary()
	return out


func event_log() -> Array[String]:
	return dispatcher.event_log()


func result_of(task_id: String) -> Variant:
	return (_results.get(task_id, {}) as Dictionary).get("value", null)


## Ergebnisse nur begrenzt behalten (lange Sitzungen duerfen nicht wachsen).
func _remember_result(task_id: String, entry: Dictionary) -> void:
	_results[task_id] = entry
	while _results.size() > MAX_STORED_RESULTS:
		_results.erase(_results.keys()[0])


# ---------------------------------------------------------------- Datei-Signale
func _on_data_requested(task_id: String, server_id: String, file_ids: Array) -> void:
	if file_transfer == null:
		dispatcher.notify_files_ready(task_id)
		return
	_log("Task %s wartet auf %d Eingabedatei(en) auf %s." % [task_id, file_ids.size(), server_id])
	file_transfer.request_files(task_id, server_id, file_ids)


func _on_task_files_ready(task_id: String) -> void:
	_log("Task %s: alle Eingabedaten verifiziert." % task_id)
	dispatcher.notify_files_ready(task_id)


func _on_task_data_failed(task_id: String, _server_id: String, reason: String) -> void:
	_log("Task %s: Eingabedaten nicht bereitstellbar - %s" % [task_id, reason])
	dispatcher.on_data_failed(task_id, reason)


func _on_transfer_progress(server_id: String, file_id: String, sent: int, total: int) -> void:
	file_transfer_progress.emit(server_id, file_id, sent, total)


func _on_transfer_finished(server_id: String, file_id: String, ok: bool, reason: String) -> void:
	if ok:
		_log("Datei '%s' nach %s uebertragen." % [file_registry.name_of(file_id), server_id])
	else:
		_log("Datei-Transfer nach %s fehlgeschlagen: %s" % [server_id, reason])
	file_transfer_finished.emit(server_id, file_id, ok, reason)


func _on_file_location_changed(_file_id: String, _server_id: String, _state: int) -> void:
	files_changed.emit()


# ---------------------------------------------------------------- Discovery
func _on_discovery_found(server_id: String, info: Dictionary) -> void:
	_log("Worker gefunden: %s (%s)" % [str(info.get("name", server_id)), str(info.get("url", ""))])
	worker_discovered.emit(server_id, info)
	if not auto_connect:
		return
	var token := str(info.get("token", ""))
	if token == "":
		token = str(_tokens.get(server_id, ""))
	if token == "" and worker_token != "":
		token = worker_token
	if token == "":
		worker_needs_token.emit(server_id, info)
		return
	_connect_with(info, token)


func _on_discovery_updated(server_id: String, info: Dictionary) -> void:
	# Worker neu gestartet (evtl. neues Token) -> Verbindung sauber neu aufbauen.
	if not auto_connect:
		return
	var token := str(info.get("token", ""))
	if token == "":
		token = str(_tokens.get(server_id, ""))
	if token == "":
		return
	if transport.has_worker(server_id) \
			and transport.get_worker_token(server_id) == token \
			and transport.is_connected_to(server_id):
		return
	if transport.has_worker(server_id):
		transport.remove_worker(server_id)
	_connect_with(info, token)


func _on_discovery_lost(server_id: String) -> void:
	_log("Worker %s meldet sich nicht mehr (Discovery)." % server_id)
	worker_lost.emit(server_id)


func _worker_info(server_id: String) -> Dictionary:
	if discovery != null and discovery.has_worker(server_id):
		return discovery.get_worker(server_id)
	var known := _known.get(server_id, {}) as Dictionary
	if known.is_empty():
		return {}
	var url := str(known.get("url", ""))
	return {
		"server_id": server_id,
		"name": str(known.get("name", server_id)),
		"url": url,
		"host": OrchestratorTransport._host_of(url),
		"port": OrchestratorTransport._port_of(url),
		"tls": url.begins_with("wss://"),
		"fingerprint": str(known.get("fp", "")),
		"ca": str(known.get("ca", "")),
		"token": str(_tokens.get(server_id, "")),
	}


## Anzeige-Fingerabdruck eines Workers: zuerst der Wert aus dem Beacon (der
## aktuelle Stand des Workers), danach der Fingerabdruck der hinterlegten
## Vertrauensdatei. Beides ist **kein** Geheimnis - es dient dem Vergleich mit
## der Anzeige in der Worker-App.
func _fingerprint_of(server_id: String) -> String:
	if discovery != null and discovery.has_worker(server_id):
		var found := str(discovery.get_worker(server_id).get("fingerprint", ""))
		if found != "":
			return found
	var ca := _ca_for(server_id)
	if ca != "":
		return OrchestratorTransport.certificate_fingerprint(ca)
	return ""


func _connect_with(info: Dictionary, token: String) -> void:
	var server_id := str(info.get("server_id", ""))
	var url := str(info.get("url", ""))
	if server_id == "" or url == "":
		return
	# Bekannte Angaben zusammenfuehren statt ersetzen: sonst ginge z. B. eine
	# hinterlegte Vertrauensdatei beim naechsten Verbinden verloren.
	var known := (_known.get(server_id, {}) as Dictionary).duplicate()
	var stored := {"url": url, "name": str(info.get("name", server_id))}
	if str(info.get("fingerprint", "")) != "":
		stored["fp"] = str(info["fingerprint"])
	_known[server_id] = known.merged(stored, true)
	if token != "" and str(_tokens.get(server_id, "")) != token:
		_tokens[server_id] = token
		_save_state()
	_connect(server_id, url, str(info.get("name", server_id)),
			int(info.get("queue_capacity", -1)), token, _ca_for(server_id))


func _connect(server_id: String, url: String, name: String, capacity: int,
		token: String, ca_path := "") -> void:
	if transport.has_worker(server_id):
		if transport.get_worker_token(server_id) == token \
				and transport.is_connected_to(server_id):
			return
		transport.remove_worker(server_id)
	# Der reine Vergleich der Token reicht hier nicht: hat sich die
	# Vertrauensdatei geaendert, muss die Verbindung neu aufgebaut werden.
	if transport.add_worker(server_id, url, name, capacity, token, ca_path):
		_log("Verbinde mit %s%s ..." % [url,
			" (TLS angeheftet)" if ca_path != "" else ""])
	else:
		_log("Verbindung zu %s nicht moeglich." % url)


## Gespeicherte Worker schon vor dem ersten Beacon verbinden.
func _reconnect_known() -> void:
	for server_id in _known.keys():
		var known := _known[server_id] as Dictionary
		var url := str(known.get("url", ""))
		if url == "":
			continue
		var token := str(_tokens.get(server_id, ""))
		if token == "":
			continue
		_connect(str(server_id), url, str(known.get("name", server_id)), -1, token,
			_ca_for(str(server_id)))


# ---------------------------------------------------------------- Signale
func _on_worker_connected(server_id: String) -> void:
	var server := servers.get_server(server_id)
	_log("Worker %s verbunden." % (server.name if server != null else server_id))
	worker_connected.emit(server_id)
	_sync_mirror()


func _on_worker_disconnected(server_id: String, reason: String) -> void:
	_log("Worker %s getrennt: %s" % [server_id, reason])
	if file_transfer != null:
		# Laufende Transfers sofort verwerfen: sonst warten sie nur sinnlos in
		# ihren Timeouts, obwohl die Ursache schon bekannt ist.
		file_transfer.cancel_server(server_id)
	worker_disconnected.emit(server_id, reason)
	_sync_mirror()


func _on_server_state_changed(server_id: String, _old_state: int, new_state: int) -> void:
	server_state_changed.emit(server_id, new_state)


func _on_task_dispatched(task_id: String, server_id: String, attempt: int) -> void:
	_log("Task %s -> %s (Versuch %d)" % [task_id, server_id, attempt])
	_sync_mirror()


func _on_task_completed(task_id: String, _server_id: String, result: Variant) -> void:
	_remember_result(task_id, {"ok": true, "value": result, "error": ""})
	var task := tasks.get_task(task_id)
	var build := task.build if task != null else {}
	if not build.is_empty():
		_log("Task %s abgeschlossen%s." % [task_id,
			" (Build aus Cache)" if bool(build.get("cached", false)) else " (neu gebaut)"])
	else:
		_log("Task %s abgeschlossen." % task_id)
	task_finished.emit(task_id, true, result, "")
	_sync_mirror()


func _on_task_failed(task_id: String, _server_id: String, error: String,
		hint: String) -> void:
	_remember_result(task_id, {"ok": false, "value": null, "error": error})
	_log("Task %s fehlgeschlagen: %s" % [task_id, error])
	if hint != "":
		_log("  Loesung: %s" % hint)
	task_finished.emit(task_id, false, null, error if hint == "" else "%s\n%s" % [error, hint])
	_sync_mirror()


func _on_task_progress(task_id: String, _server_id: String, stage: String,
		fraction: float, text: String) -> void:
	if text != "":
		_log("Task %s [%s] %s" % [task_id, stage, text])
	task_progress.emit(task_id, stage, fraction, text)


## Ein Sendefehler wuerde sonst nur als ACK-Timeout auffallen.
func _on_send_failed(server_id: String, reason: String) -> void:
	_log("Uebertragung an %s fehlgeschlagen: %s" % [server_id, reason])


## TLS-Handshake gescheitert: Klartext-Hinweis ins Protokoll und an die
## Oberflaeche - es gibt **keinen** stillen Rueckfall auf unverschluesselt.
func _on_tls_problem(server_id: String, hint: String) -> void:
	_log("TLS-Problem bei %s: %s" % [server_id, hint])
	tls_problem.emit(server_id, hint)


# ---------------------------------------------------------------- Szenen-Spiegel
## Optional (`mirror_scene`): legt pro Worker/Task einen Kind-Node an. Damit
## laesst sich der Cluster wie ein normales Node-System verwenden/abfragen.
func _sync_mirror() -> void:
	if not mirror_scene:
		return
	if _mirror_root == null or not is_instance_valid(_mirror_root):
		_mirror_root = Node.new()
		_mirror_root.name = "ClusterMirror"
		add_child(_mirror_root)
	var wanted: Dictionary = {}
	for entry in workers_snapshot():
		var node_name := "Worker_%s" % ClusterDiscovery._safe_id(str(entry["server_id"]))
		wanted[node_name] = entry
	for task_id in task_ids():
		var snapshot := task_snapshot(task_id)
		var node_name := "Task_%s" % ClusterDiscovery._safe_id(str(task_id))
		wanted[node_name] = snapshot
	for child in _mirror_root.get_children():
		if not wanted.has(child.name):
			child.queue_free()
	for node_name in wanted.keys():
		var node: Node = _mirror_root.get_node_or_null(String(node_name))
		if node == null:
			node = Node.new()
			node.name = String(node_name)
			_mirror_root.add_child(node)
		node.set_meta("cluster", wanted[node_name])


# ---------------------------------------------------------------- Persistenz
func _save_state() -> void:
	var file := FileAccess.open(state_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"tokens": _tokens, "known": _known}, "  "))
	file.close()


func _load_state() -> void:
	if not FileAccess.file_exists(state_path):
		return
	var file := FileAccess.open(state_path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return
	var data := parsed as Dictionary
	var tokens: Variant = data.get("tokens", {})
	if tokens is Dictionary:
		_tokens = tokens
	var known: Variant = data.get("known", {})
	if known is Dictionary:
		_known = known


# ---------------------------------------------------------------- Helfer
## Rekursiv Textdateien einsammeln (gleiche Auswahl wie der Python-Seite).
func _scan_dir(abs_dir: String, prefix: String, out: Dictionary,
		state: Dictionary) -> void:
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with(".") or IGNORED_DIRS.has(entry):
			entry = dir.get_next()
			continue
		if dir.current_is_dir():
			_scan_dir(abs_dir.path_join(entry), prefix + entry + "/", out, state)
		else:
			var ext := "." + entry.get_extension().to_lower()
			if PROJECT_SUFFIXES.has(ext) \
					and out.size() < MAX_PROJECT_FILES \
					and int(state["total"]) < MAX_TOTAL_CHARS:
				var text := _read_text(abs_dir.path_join(entry))
				if text != "" and text.length() <= MAX_FILE_CHARS:
					out[prefix + entry] = text
					state["total"] = int(state["total"]) + text.length()
			elif out.size() >= MAX_PROJECT_FILES:
				state["truncated"] = true
		entry = dir.get_next()
	dir.list_dir_end()


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


## Einstiegsdatei raten - damit "Projekt starten" ohne Nachfrage klappt.
static func _guess_entry(files: Dictionary) -> String:
	for name in ENTRY_CANDIDATES:
		if files.has(name):
			return String(name)
	var top: Array[String] = []
	var nested: Array[String] = []
	for name in files.keys():
		var text := String(name)
		if not text.ends_with(".py"):
			continue
		nested.append(text)
		if not text.contains("/"):
			top.append(text)
	top.sort()
	nested.sort()
	if top.size() == 1:
		return top[0]
	if nested.size() == 1:
		return nested[0]
	return ""


func _read_python(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		if not FileAccess.file_exists(path):
			return ""
		return FileAccess.get_file_as_string(path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


static func _script_name(path: String) -> String:
	var base := path.get_file()
	return base.trim_suffix(".py")


static func _state_text(state: int) -> String:
	match state:
		OrchestratorServer.NodeState.READY:
			return "READY"
		OrchestratorServer.NodeState.LIMITED:
			return "LIMITED"
		OrchestratorServer.NodeState.BLOCKED:
			return "BLOCKED"
		OrchestratorServer.NodeState.UNRESPONSIVE:
			return "UNRESPONSIVE"
		OrchestratorServer.NodeState.DISCONNECTED:
			return "DISCONNECTED"
	return "UNKNOWN"


## Eindeutige, NodePath-taugliche Server-ID fuer manuell eingetragene Worker.
func _unique_id(base: String) -> String:
	var candidate := base if base != "" else "worker"
	if _id_free(candidate):
		return candidate
	var i := 2
	while i < 1000:
		var next_id := "%s_%d" % [candidate, i]
		if _id_free(next_id):
			return next_id
		i += 1
	return "%s_%d" % [candidate, Time.get_ticks_msec()]


func _id_free(candidate: String) -> bool:
	return not servers.has_server(candidate) and not _known.has(candidate) \
		and not transport.has_worker(candidate)


func _log(text: String) -> void:
	log_event.emit(text)
