class_name OrchestratorPanel
extends VBoxContainer
## Editor-Dock des visuellen Task-Orchestrators.
##
## Zeigt den Node-Graphen (Task → Router → Server) und aktualisiert die
## Server-/Task-Knoten aus dem Orchestrator-Kern. Das Dock enthält selbst
## **keine** Orchestrierungslogik – es rendert nur das Graph-Modell und ruft
## Server-/Task-Manager, Router und Dispatcher. Damit bleibt die UI austauschbar
## (Auftrag §23).
##
## Registrierung: Das Dock wird direkt vom Haupt-Plugin registriert
## (`plugin.gd`), damit `add_control_to_dock` zuverlässig greift.
##
## Transport: Es gibt hier **keine** zweite Kommunikationswelt. „Dispatch"
## weist wartende Tasks über den Router zu; die Zustellung macht die bestehende
## Bridge über das Signal `dispatcher.dispatch_requested`. Der **Demo-Modus**
## simuliert zusätzlich Heartbeats **und** einen Worker (ACK/Start/Ergebnis),
## damit der Ablauf ohne Netz sichtbar wird – ausdrücklich eine lokale
## Simulation, kein Kommunikationsweg.

const NODE_ROUTER := "router"
const COL_READY := Color(0.35, 0.85, 0.45)
const COL_LIMITED := Color(0.92, 0.80, 0.30)
const COL_BLOCKED := Color(0.92, 0.35, 0.30)
const COL_UNRESPONSIVE := Color(0.95, 0.62, 0.22)
const COL_DISCONNECTED := Color(0.55, 0.55, 0.55)
const COL_TASK := Color(0.55, 0.75, 0.98)

const DEMO_ACK_DELAY_MS := 800
const DEMO_START_DELAY_MS := 800
const DEMO_RESULT_DELAY_MS := 1200
const DEMO_FAILURE_CHANCE := 0.15

const GRAPH_PATH := "res://orchestrator_graph.json"
const WORKERS_PATH := "res://orchestrator_workers.json"

var cfg: OrchestratorConfig
var graph_model: OrchestratorGraphModel
var servers: OrchestratorServerManager
var tasks: OrchestratorTaskManager
var router: OrchestratorRouter
var dispatcher: OrchestratorDispatcher
var transport: OrchestratorTransport

var _graph: GraphEdit = null
var _log: RichTextLabel = null
var _status: Label = null
var _demo_button: Button = null
var _demo_jobs: Array = []
var _demo_mode := false
var _rng := RandomNumberGenerator.new()
var _seeded := false


func _init(p_config: OrchestratorConfig = null) -> void:
	cfg = p_config if p_config != null else OrchestratorConfig.defaults()
	graph_model = OrchestratorGraphModel.new()
	servers = OrchestratorServerManager.new(cfg)
	tasks = OrchestratorTaskManager.new(cfg)
	router = OrchestratorRouter.new(servers, cfg)
	dispatcher = OrchestratorDispatcher.new(servers, tasks, cfg, router)
	transport = OrchestratorTransport.new(servers, dispatcher, cfg)
	_rng.randomize()
	_build_ui()
	_connect_signals()
	_restore_or_seed()
	refresh()


# ---------------------------------------------------------------- Public API
func add_server(id: String, name := "", host := "", port := 0) -> OrchestratorServer:
	var server := servers.add_server(id, name, host, port)
	if server != null:
		graph_model.add_node(_server_node_id(id), OrchestratorGraphModel.NodeType.SERVER, server.name, _next_position())
		refresh()
	return server


func submit_task(python_task: String, priority := OrchestratorTask.Priority.NORMAL,
		required_files: Array = [], requirements: Dictionary = {}, target := "", meta: Dictionary = {}) -> OrchestratorTask:
	var task := dispatcher.submit(python_task, priority, required_files, requirements, target)
	if task == null:
		return null
	task.meta = meta.duplicate(true)
	graph_model.add_node(_task_node_id(task.task_id), OrchestratorGraphModel.NodeType.TASK, python_task, _next_position())
	_log_line("Task %s erstellt (%s → %s)" % [task.task_id, python_task, OrchestratorTask.priority_text(priority)])
	refresh()
	return task


## Öffnet den echten Task-Dialog. Der Dialog erzeugt keinen zweiten Python-
## Interpreter: `meta` wird als vorhandene Bridge-Aufgabe an den Worker
## weitergereicht (`run` oder `call`).
func _task_dialog() -> void:
	var script_edit := LineEdit.new()
	script_edit.placeholder_text = "Script-ID ohne .py, z. B. benchmark"
	script_edit.text = "benchmark"
	var mode := OptionButton.new()
	mode.add_item("run: input → result", 0)
	mode.add_item("call: Funktion aufrufen", 1)
	mode.select(1)
	var function_edit := LineEdit.new()
	function_edit.placeholder_text = "Funktion, z. B. ping"
	function_edit.text = "ping"
	var input_edit := LineEdit.new()
	input_edit.placeholder_text = "JSON input, z. B. {\"value\": 42}"
	input_edit.text = "{}"
	var args_edit := LineEdit.new()
	args_edit.placeholder_text = "JSON Array, z. B. [\"Hallo Worker\"]"
	args_edit.text = "[\"Hallo Worker\"]"
	var priority := OptionButton.new()
	priority.add_item("HIGH", OrchestratorTask.Priority.HIGH)
	priority.add_item("NORMAL", OrchestratorTask.Priority.NORMAL)
	priority.add_item("LOW", OrchestratorTask.Priority.LOW)
	priority.select(1)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(480, 0)
	box.add_child(_form_label("Vorhandenes Python-Script"))
	box.add_child(script_edit)
	box.add_child(_form_label("Aufgabentyp"))
	box.add_child(mode)
	box.add_child(_form_label("Funktion (nur bei call)"))
	box.add_child(function_edit)
	box.add_child(_form_label("Input JSON (run)"))
	box.add_child(input_edit)
	box.add_child(_form_label("Argumente JSON-Array (call)"))
	box.add_child(args_edit)
	box.add_child(_form_label("Priorität"))
	box.add_child(priority)

	var dialog := AcceptDialog.new()
	dialog.title = "Python-Task einreihen"
	dialog.ok_button_text = "Einreihen"
	dialog.add_child(box)
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		var script_id := script_edit.text.strip_edges()
		if script_id == "":
			_log_line("Task abgelehnt: Script-ID fehlt.")
			dialog.queue_free()
			return
		var input_value: Variant = _parse_json_or(input_edit.text, {})
		var args_value: Variant = _parse_json_or(args_edit.text, [])
		if not (args_value is Array):
			_log_line("Task abgelehnt: Argumente müssen ein JSON-Array sein.")
			dialog.queue_free()
			return
		var is_call := mode.selected == 1
		var meta := {
			"command": "call" if is_call else "run",
			"function": function_edit.text.strip_edges() if is_call else "",
			"input": input_value,
			"args": args_value if is_call else [],
			"kwargs": {},
		}
		var task := submit_task(script_id, int(priority.get_selected_id()), [], {}, "", meta)
		if task != null:
			_log_line("Task %s eingereiht – 'Dispatch' zum Senden." % task.task_id)
		dialog.queue_free())
	dialog.popup_centered(Vector2(540, 560))


func _parse_json_or(text: String, fallback: Variant) -> Variant:
	var parsed: Variant = JSON.parse_string(text.strip_edges())
	return parsed if parsed != null else fallback


## Verteilt wartende Tasks über den Router auf geeignete Server.
func dispatch_once() -> int:
	var sent := dispatcher.dispatch()
	_log_line("Dispatch: %d Task(s) verschickt." % sent)
	refresh()
	return sent


func refresh() -> void:
	_rebuild_graph()
	_update_status()


## Pro Frame: Kern ticken (Heartbeats/Timeouts/Retries) und Labels aktualisieren.
func editor_poll() -> void:
	if _graph == null:
		return
	var now := Time.get_ticks_msec()
	transport.poll()
	if _demo_mode and transport.worker_ids().is_empty():
		_simulate_heartbeats()
	dispatcher.tick(now)
	if _demo_mode and transport.worker_ids().is_empty():
		_demo_advance(now)
		dispatcher.dispatch(now + 1)
	_update_node_labels()
	_update_status()


func save_graph(path: String = GRAPH_PATH) -> Error:
	return graph_model.save_json(path)


func load_graph(path: String = GRAPH_PATH) -> bool:
	var loaded := OrchestratorGraphModel.load_json(path)
	if loaded == null:
		return false
	graph_model = loaded
	refresh()
	return true


# ---------------------------------------------------------------- Aufbau
func _connect_signals() -> void:
	servers.server_added.connect(func(_id): refresh())
	servers.server_removed.connect(func(_id): refresh())
	servers.server_state_changed.connect(func(_id, _o, _n): refresh())
	tasks.task_added.connect(func(_id): refresh())
	tasks.task_removed.connect(func(_id): refresh())
	tasks.task_state_changed.connect(func(_id, _o, _n): refresh())
	dispatcher.dispatch_requested.connect(_on_dispatch_requested)
	dispatcher.cancel_requested.connect(_on_cancel_requested)
	dispatcher.task_completed.connect(func(tid: String, sid: String, _r):
		_log_line("Task %s abgeschlossen auf %s" % [tid, sid]))
	dispatcher.task_failed.connect(func(tid: String, sid: String, err: String, hint: String):
		_log_line("Task %s fehlgeschlagen auf %s: %s%s" % [tid, sid, err,
			("  → " + hint) if hint != "" else ""]))
	dispatcher.task_progress.connect(func(tid: String, _sid: String, stage: String, _frac: float, text: String):
		_log_line("Task %s [%s] %s" % [tid, stage, text]))
	dispatcher.server_lost.connect(func(sid: String, ids: Array):
		_log_line("Server %s ausgefallen, %d Task(s) betroffen" % [sid, ids.size()]))
	transport.worker_connected.connect(func(sid: String): _log_line("Worker %s verbunden." % sid))
	transport.worker_disconnected.connect(func(sid: String, reason: String):
		_log_line("Worker %s getrennt: %s" % [sid, reason]))


## Lädt einen gespeicherten Graphen oder legt – wenn nichts existiert – eine
## lauffähige Demo an, damit das Dock nie leer und immer bedienbar ist.
func _restore_or_seed() -> void:
	# 1) Echte Worker haben Vorrang: konfigurierte Rechner verbinden, kein Demo.
	if _connect_configured_workers() > 0:
		return
	if not graph_model.nodes.is_empty():
		return
	# 2) Gespeicherten Graph laden.
	var loaded := OrchestratorGraphModel.load_json(GRAPH_PATH)
	if loaded != null and not loaded.nodes.is_empty():
		graph_model = loaded
		_log_text("Gespeicherten Graph geladen: %s" % GRAPH_PATH)
		return
	# 3) Sonst eine lauffaehige Demo anlegen, damit das Dock nie leer ist.
	_seed_demo()


## Liest `orchestrator_workers.json` und verbindet alle Einträge.
## Format: [{"id":"worker-a","name":"PC 2","url":"ws://192.168.1.42:8765",
##           "token":"..."}]
func _connect_configured_workers() -> int:
	if not FileAccess.file_exists(WORKERS_PATH):
		return 0
	var text := FileAccess.get_file_as_string(WORKERS_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Array):
		push_warning("[Orchestrator] %s ist kein JSON-Array." % WORKERS_PATH)
		return 0
	var count := 0
	for entry in (parsed as Array):
		if not (entry is Dictionary):
			continue
		var e := entry as Dictionary
		var url := str(e.get("url", ""))
		var id := str(e.get("id", ""))
		if url == "" or id == "":
			continue
		if transport.add_worker(id, url, str(e.get("name", "")), int(e.get("capacity", -1)),
				str(e.get("token", ""))):
			graph_model.add_node(_server_node_id(id), OrchestratorGraphModel.NodeType.SERVER, str(e.get("name", id)), _next_position())
			count += 1
	if count > 0:
		_log_text("%d Worker aus %s konfiguriert (echter Transport)." % [count, WORKERS_PATH])
	return count


func _seed_demo() -> void:
	if _seeded:
		return
	_seeded = true
	for i in 3:
		var id := "s%d" % (i + 1)
		var server := servers.add_server(id, "Server %s" % char(65 + i), "127.0.0.1", 8765 + i)
		if server != null:
			graph_model.add_node(_server_node_id(id), OrchestratorGraphModel.NodeType.SERVER, server.name, _next_position())
	submit_task("numpy_bench", OrchestratorTask.Priority.HIGH)
	submit_task("check_data", OrchestratorTask.Priority.NORMAL)
	_demo_mode = true
	_update_demo_button()
	_simulate_heartbeats()
	servers.tick()
	_log_text("Demo angelegt: 3 Server + 2 Tasks, Demo-Modus AN (lokale Simulation, kein Transport).")
	_log_text("→ 'Dispatch' weist die Tasks zu; der Demo-Worker quittiert mit ACK und meldet das Ergebnis.")


# ---------------------------------------------------------------- UI
func _build_ui() -> void:
	custom_minimum_size = Vector2(540, 460)
	add_theme_constant_override("separation", 6)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = "Task Orchestrator"
	title.add_theme_font_size_override("font_size", 15)
	header.add_child(title)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.text = "–"
	header.add_child(_status)
	add_child(header)

	var toolbar := HFlowContainer.new()
	toolbar.add_theme_constant_override("h_separation", 6)
	toolbar.add_theme_constant_override("v_separation", 4)
	add_child(toolbar)

	_add_button(toolbar, "Refresh", func(): refresh())
	_add_button(toolbar, "+ Worker...", func(): _connect_worker_dialog())
	_add_button(toolbar, "+ Server", func(): _add_demo_server())
	_demo_button = _add_button(toolbar, "Demo: AN", func(): _toggle_demo())
	_add_button(toolbar, "+ Task", func(): _task_dialog())
	_add_button(toolbar, "Dispatch", func(): dispatch_once())
	_add_button(toolbar, "Speichern", func(): _save_graph_dialog())
	_add_button(toolbar, "Laden", func(): _load_graph_dialog())

	var split := VSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 4)
	add_child(split)

	_graph = GraphEdit.new()
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph.custom_minimum_size = Vector2(0, 240)
	_graph.minimap_enabled = false
	_graph.show_grid = true
	_graph.show_arrange_button = true
	split.add_child(_graph)

	_log = RichTextLabel.new()
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 130)
	_log.bbcode_enabled = true
	_log.scroll_following = true
	split.add_child(_log)
	split.split_offset = -170

	_log_text("Orchestrator bereit. Knoten sind frei verschiebbar, der Graph ist speicher-/ladbar.")


func _add_button(parent: Control, text: String, cb: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(cb)
	parent.add_child(button)
	return button


func _rebuild_graph() -> void:
	if _graph == null:
		return
	_graph.clear_connections()
	for child in _graph.get_children():
		if child is GraphNode:
			child.queue_free()

	_add_graph_node(NODE_ROUTER, "Router", _position_of(NODE_ROUTER, Vector2(0, 40)), OrchestratorGraphModel.NodeType.ROUTER)
	for server in servers.servers():
		var s := server as OrchestratorServer
		_add_graph_node(_server_node_id(s.id), "%s %s" % [OrchestratorServer.state_icon(s.state), s.name],
			_position_of(_server_node_id(s.id), Vector2(360, 0)), OrchestratorGraphModel.NodeType.SERVER)
	for task in tasks.tasks():
		var t := task as OrchestratorTask
		_add_graph_node(_task_node_id(t.task_id), "%s" % t.task_id,
			_position_of(_task_node_id(t.task_id), Vector2(-330, 0)), OrchestratorGraphModel.NodeType.TASK)
		_graph.connect_node(_task_node_id(t.task_id), 0, NODE_ROUTER, 0)
		if t.assigned_server != "" and servers.has_server(t.assigned_server):
			_graph.connect_node(NODE_ROUTER, 0, _server_node_id(t.assigned_server), 0)
	_update_node_labels()


func _add_graph_node(node_name: String, title: String, position: Vector2, type: int) -> void:
	if _graph == null or _graph.has_node(NodePath(node_name)):
		return
	var node := GraphNode.new()
	node.name = node_name
	node.title = title
	node.position_offset = position
	var label := Label.new()
	label.name = "Body"
	label.text = "–"
	label.add_theme_font_size_override("font_size", 11)
	node.add_child(label)
	node.set_slot(0, true, 0, Color.WHITE, true, 0, Color.WHITE)
	if type == OrchestratorGraphModel.NodeType.TASK:
		node.add_theme_color_override("title_color", COL_TASK)
	_graph.add_child(node)
	if not graph_model.has_node(node_name):
		graph_model.add_node(node_name, type, title, position)


func _update_node_labels() -> void:
	if _graph == null:
		return
	for server in servers.servers():
		var s := server as OrchestratorServer
		var node := _graph.get_node_or_null(NodePath(_server_node_id(s.id))) as GraphNode
		if node == null:
			continue
		node.title = "%s %s" % [OrchestratorServer.state_icon(s.state), s.name]
		node.add_theme_color_override("title_color", _server_color(s.state))
		var body := "State: %s\nCPU: %.0f%%\nRAM: %.0f%%\nQueue: %d/%d\nLatency: %.0f ms" % [
			OrchestratorServer.state_text(s.state), s.cpu_pct, s.ram_pct,
			s.effective_queue_used(), s.queue_capacity, s.latency_ms]
		if s.block_reason != "":
			body += "\n" + s.block_reason
		_set_body(node, body)
	for task in tasks.tasks():
		var t := task as OrchestratorTask
		var tnode := _graph.get_node_or_null(NodePath(_task_node_id(t.task_id))) as GraphNode
		if tnode == null:
			continue
		tnode.title = "%s [%s]" % [t.python_task, OrchestratorTask.priority_text(t.priority)]
		var target := t.assigned_server if t.assigned_server != "" else t.target
		_set_body(tnode, "State: %s\nServer: %s\nVersuche: %d\nFiles: %d\nACK: %s" % [
			t.state_text_now(), (target if target != "" else "–"), t.attempts,
			t.required_files.size(), "ja" if t.ack_received else "nein"])


func _server_color(state: int) -> Color:
	match state:
		OrchestratorServer.NodeState.READY:
			return COL_READY
		OrchestratorServer.NodeState.LIMITED:
			return COL_LIMITED
		OrchestratorServer.NodeState.BLOCKED:
			return COL_BLOCKED
		OrchestratorServer.NodeState.UNRESPONSIVE:
			return COL_UNRESPONSIVE
	return COL_DISCONNECTED


func _set_body(node: GraphNode, text: String) -> void:
	var label := node.get_node_or_null(NodePath("Body")) as Label
	if label != null:
		label.text = text


func _update_status() -> void:
	if _status == null:
		return
	var s := dispatcher.stats()
	_status.text = "Server %d (verfügbar %d) · Tasks %d · QUEUED %d · RUNNING %d · DONE %d · FAILED %d · ACK %d" % [
		servers.server_count(), int(s.get("available_servers", 0)), tasks.task_count(),
		int(s.get("queued", 0)) + int(s.get("retrying", 0)), int(s.get("running", 0)),
		int(s.get("completed", 0)), int(s.get("failed", 0)), int(s.get("pending_ack", 0))]


# ---------------------------------------------------------------- Aktionen
func _add_demo_server() -> void:
	var index := servers.server_count() + 1
	var server := add_server("s%d" % index, "Server %s" % char(64 + index), "127.0.0.1", 8765 + index)
	if server != null:
		_log_line("Server '%s' angelegt." % server.name)


## Verbindet einen echten Worker auf einem anderen Rechner und merkt ihn sich
## in `orchestrator_workers.json`, damit er beim naechsten Start automatisch
## wieder verbunden wird.
func _connect_worker_dialog() -> void:
	var url_edit := LineEdit.new()
	url_edit.placeholder_text = "ws://192.168.1.42:8765"
	url_edit.text = "ws://192.168.1.42:8765"
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "Worker A"
	var token_edit := LineEdit.new()
	token_edit.placeholder_text = "Token vom Worker (--token, Pflicht)"
	token_edit.secret = true

	var box := VBoxContainer.new()
	box.add_child(_form_label("Worker-URL"))
	box.add_child(url_edit)
	box.add_child(_form_label("Anzeigename"))
	box.add_child(name_edit)
	box.add_child(_form_label("Token (wird beim Worker-Start gesetzt)"))
	box.add_child(token_edit)

	var dialog := AcceptDialog.new()
	dialog.title = "Worker verbinden"
	dialog.ok_button_text = "Verbinden"
	dialog.add_child(box)
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		var url := url_edit.text.strip_edges()
		if url == "":
			return
		var name := name_edit.text.strip_edges()
		var id := "w%d" % (transport.worker_ids().size() + 1)
		if transport.add_worker(id, url, name, -1, token_edit.text.strip_edges()):
			graph_model.add_node(_server_node_id(id), OrchestratorGraphModel.NodeType.SERVER,
				(name if name != "" else id), _next_position())
			_demo_mode = false
			_update_demo_button()
			_save_workers_config()
			_log_line("Worker '%s' verbunden: %s" % [id, url])
			# Einladungs-Workflow: Startbefehl fuer den Client-PC direkt
			# kopierbar ins Log (nur lokal sichtbar).
			var invite_token := token_edit.text.strip_edges()
			if invite_token != "":
				_log_line("→ Client-PC startet so (Skripte unter ./scripts):")
				_log_line("    python orchestrator_worker.py --bind 0.0.0.0 --port 8765 --name \"%s\" --token \"%s\" --scripts-dir ./scripts" % [(name if name != "" else id), invite_token])
			refresh()
		else:
			_log_line("Worker %s nicht erreichbar." % url)
		dialog.queue_free())
	dialog.popup_centered(Vector2(460, 260))


func _form_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _save_workers_config() -> void:
	var entries: Array = []
	for id in transport.worker_ids():
		var description: Dictionary = {}
		for entry in transport.describe():
			if str((entry as Dictionary).get("server_id", "")) == id:
				description = entry
				break
		var server := servers.get_server(id)
		entries.append({
			"id": id,
			"name": server.name if server != null else id,
			"url": str(description.get("url", "")),
			"token": transport.get_worker_token(id),
		})
	var file := FileAccess.open(WORKERS_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(entries, "\t"))
	file.close()


func _toggle_demo() -> void:
	_demo_mode = not _demo_mode
	_update_demo_button()
	_log_line("Demo-Modus %s (lokale Simulation von Heartbeat + Worker, kein Transport)." % ("AN" if _demo_mode else "AUS"))
	if _demo_mode and not transport.worker_ids().is_empty():
		_log_line("Hinweis: echte Worker sind verbunden, die Simulation wird übersprungen.")


func _update_demo_button() -> void:
	if _demo_button != null:
		_demo_button.text = "Demo: %s" % ("AN" if _demo_mode else "AUS")


func _simulate_heartbeats() -> void:
	for server in servers.servers():
		var s := server as OrchestratorServer
		var metrics := {
			"cpu": clampf(s.cpu_pct + _rng.randf_range(-12.0, 12.0) + 5.0, 2.0, 98.0),
			"ram": clampf(s.ram_pct + _rng.randf_range(-8.0, 8.0), 5.0, 95.0),
			"latency": maxf(s.latency_ms + _rng.randf_range(-3.0, 3.0), 1.0),
			"queue_used": s.queue_used,
			"active_tasks": s.active_tasks,
		}
		servers.on_heartbeat(s.id, metrics)


## Simuliert den Worker-Lebenszyklus eines verschickten Tasks (ACK → Start →
## Ergebnis) mit Verzögerungen. Nur im Demo-Modus.
func _on_dispatch_requested(task_id: String, server_id: String, _python_task: String, _files: Array) -> void:
	_log_line("→ Führe %s auf %s aus" % [task_id, server_id])
	if not _demo_mode:
		return
	_demo_jobs.append({
		"task_id": task_id,
		"server_id": server_id,
		"stage": 0,
		"due": Time.get_ticks_msec() + DEMO_ACK_DELAY_MS,
	})


func _on_cancel_requested(task_id: String, server_id: String, _attempt: int) -> void:
	_log_line("Abbruch von %s angefordert an %s" % [task_id, server_id])
	if _demo_mode:
		dispatcher.on_cancel_ack(task_id, server_id)


func _demo_advance(now_ms: int) -> void:
	var pending: Array = []
	for job in _demo_jobs:
		if now_ms < int(job["due"]):
			pending.append(job)
			continue
		var task_id := str(job["task_id"])
		var server_id := str(job["server_id"])
		match int(job["stage"]):
			0:
				dispatcher.on_ack(task_id, server_id)
				job["stage"] = 1
				job["due"] = now_ms + DEMO_START_DELAY_MS
				pending.append(job)
			1:
				if dispatcher.on_task_started(task_id, server_id, now_ms):
					var s := servers.get_server(server_id)
					if s != null:
						s.active_tasks += 1
				job["stage"] = 2
				job["due"] = now_ms + DEMO_RESULT_DELAY_MS
				pending.append(job)
			2:
				var s2 := servers.get_server(server_id)
				if s2 != null:
					s2.active_tasks = maxi(s2.active_tasks - 1, 0)
				var roll := _rng.randf()
				var success := roll > DEMO_FAILURE_CHANCE
				dispatcher.on_task_result(task_id, server_id, success,
					{"demo_roll": roll} if success else null,
					"" if success else "simulierter Worker-Fehler")
	_demo_jobs = pending


func _save_graph_dialog() -> void:
	var err := save_graph(GRAPH_PATH)
	_log_line("Graph gespeichert: %s (err=%d)" % [GRAPH_PATH, err])


func _load_graph_dialog() -> void:
	if load_graph(GRAPH_PATH):
		_log_line("Graph geladen.")
	else:
		_log_line("Kein gespeicherter Graph gefunden.")


# ---------------------------------------------------------------- Helfer
func _server_node_id(id: String) -> String:
	return "server_" + id


func _task_node_id(id: String) -> String:
	return "task_" + id.replace("-", "_")


func _position_of(node_id: String, fallback: Vector2) -> Vector2:
	if graph_model.has_node(node_id):
		return graph_model.get_position(node_id)
	return fallback + Vector2(_rng.randf_range(-30, 30), _rng.randf_range(-20, 20))


func _next_position() -> Vector2:
	return Vector2(-330 + _rng.randf_range(-20, 20), 40 + 70 * graph_model.node_count())


func _log_text(text: String) -> void:
	if _log != null:
		_log.append_text(text + "\n")
	print("[Orchestrator] ", text)


func _log_line(text: String) -> void:
	_log_text(text)
