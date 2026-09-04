class_name BridgeInstance
extends Node
## Eine Python-Instanz = genau ein Python-Subprozess + ein WebSocket-Kanal.
## Steuert die gesamte Zustandsmaschine vom Provisionieren bis READY und
## verantwortet Request/Response-Zuordnung (+ Timeout + Reconnect).
##
## KEIN Thread: Provisioning und Prozess-Launch laufen ueber nicht-blockierende
## OS.create_process-Aufrufe und werden pro Frame gepollt (siehe tick()).

signal instance_ready
signal state_changed(instance: String, state: String)

enum State {
	NONE, PROVISIONING, STARTING, CONNECTING, HANDSHAKE, READY, ERROR, STOPPED
}

const MAX_RECONNECTS := 2
const CONNECT_TIMEOUT_MS := 20000
const PORT_PROBE_MAX := 1800

var instance_name: String = ""
var state: int = State.NONE

var _bridge: Node = null
var _settings: Dictionary = {}
var _client: BridgeWsClient = null
var _provisioner: BridgeProvisioner = null
var _process: BridgeProcess = null

var _pending: Dictionary = {}          # request_id -> PendingRequest
var _req_counter: int = 0
var _context_counter: int = 0

var _tmp_probe_tries: int = 0
var _connect_start_ms: int = 0
var _ws_was_open: bool = false
var _reconnect_left: int = MAX_RECONNECTS
var _port: int = 0
var _pid: int = 0
var _last_error: String = ""

func _init(bridge: Node, name_id: String, settings: Dictionary) -> void:
	instance_name = name_id
	_bridge = bridge
	_settings = settings

# ------------------------------------------------------------------ Start
func start() -> void:
	_set_state(State.PROVISIONING)
	_provisioner = BridgeProvisioner.new()
	_provisioner.start(_settings, self, "_on_provision_done")

func _on_provision_done(ok: bool, msg: String) -> void:
	if _provisioner:
		_provisioner = null
	if not ok:
		_set_error("[Provision] " + msg)
		return
	_launch()

func _launch() -> void:
	_set_state(State.STARTING)
	# workspace_fs = echter Dateisystem-Pfad (res:// versteht nur Godot selbst).
	var ws := str(_settings.get("workspace_fs", _settings.get("workspace_dir", "res://python_bridge")))
	var runner := ws + "/bridge/run_server.py"
	var cmd := PackedStringArray()
	cmd.append(_venv_python(ws))
	cmd.append(runner)
	cmd.append("--bind")
	cmd.append("127.0.0.1")
	cmd.append("--port")
	cmd.append("0")
	cmd.append("--tmpdir")
	cmd.append(ws + "/tmp")
	cmd.append("--tag")
	cmd.append(instance_name)
	_process = BridgeProcess.new()
	if not _process.start(cmd):
		_set_error("Prozessstart fehlgeschlagen.")
		return
	_client = BridgeWsClient.new()
	_tmp_probe_tries = 0
	_ws_was_open = false

func _venv_python(ws: String) -> String:
	if OS.get_name() == "Windows":
		return ws + "/venv/Scripts/python.exe"
	return ws + "/venv/bin/python"

func _try_reconnect() -> void:
	if _reconnect_left <= 0:
		_set_error("Keine Reconnect-Versuche mehr.")
		return
	_reconnect_left -= 1
	_launch()

# ------------------------------------------------------------------ Poll (pro Frame)
func tick() -> void:
	match state:
		State.PROVISIONING:
			if _provisioner:
				_provisioner.tick()
		State.STARTING:
			_probe_temp_file()
		State.CONNECTING:
			_client.poll()
			if _client.is_open():
				_set_state(State.HANDSHAKE)
				_client.poll()
				_send_hello()
			elif Time.get_ticks_msec() - _connect_start_ms > CONNECT_TIMEOUT_MS:
				_try_reconnect()
		State.HANDSHAKE, State.READY:
			_client.poll()
			if not _client.is_open():
				if _ws_was_open:
					_fail_all_pending("down", "Python-Prozess getrennt (WebSocket geschlossen)")
					_try_reconnect()
				_ws_was_open = false
				return
			_ws_was_open = true
			for parsed in _client.drain():
				_handle_message(parsed)
		_:
			pass
	_check_timeouts()

func _send_hello() -> void:
	# Handshake: Godot meldet sich beim Python-Server an. Erst nach der
	# hello_ack-Antwort gilt die Instanz als READY.
	var msg := {
		"v": PythonProtocol.PROTOCOL_VERSION,
		"type": "hello",
		"id": "hello-" + instance_name,
	}
	_client.send_message(msg)

func _probe_temp_file() -> void:
	var tmpf := str(_settings.get("workspace_fs", _settings.get("workspace_dir", "res://python_bridge"))) + "/tmp/%s.json" % instance_name
	if not FileAccess.file_exists(tmpf):
		_tmp_probe_tries += 1
		if _tmp_probe_tries > PORT_PROBE_MAX:
			_set_error("Kein Port vom Subprozess erhalten (Timeout).")
		return
	var f := FileAccess.open(tmpf, FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	# Der Server schreibt die Datei nicht atomar - beim Lesen waehrend des
	# Schreibens kann sie leer oder unvollstaendig sein. Dann weiter proben,
	# erst nach Ablauf des Timeouts hart fehlschlagen.
	if d is Dictionary and int(d.get("port", 0)) > 0:
		_port = int(d["port"])
		_pid = int(d.get("pid", 0))
		_connect_start_ms = Time.get_ticks_msec()
		_set_state(State.CONNECTING)
		var err := _client.connect_to("127.0.0.1", _port)
		if err != OK:
			_set_error("WebSocket-Verbindungsfehler: " + str(err))
	else:
		_tmp_probe_tries += 1
		if _tmp_probe_tries > PORT_PROBE_MAX:
			_set_error("Ungültige Port-Datei (Timeout).")

# ------------------------------------------------------------------ Requests
func run(context_id: String, source: String, input: Variant,
		command := "run", function := "", args := [], kwargs := {},
		timeout_sec := 30.0) -> PythonBridgeResult:
	if state != State.READY:
		if not await wait_ready():
			return PythonBridgeResult.failed("not_ready", "Instanz nicht bereit: " + status_text())
	var payload := {
		"context": context_id,
		"source": source,
		"command": command,
		"timeout_ms": int(timeout_sec * 1000.0),
	}
	if command == "call":
		payload["function"] = function
		payload["args"] = args
		payload["kwargs"] = kwargs
	elif input != null:
		payload["input"] = input
	var req := _submit("execute", payload, timeout_sec)
	return await req.done

func _submit(op: String, payload: Dictionary, timeout_sec: float) -> PendingRequest:
	_req_counter += 1
	var req := PendingRequest.new()
	req.id = "%s-%d" % [instance_name, _req_counter]
	req.created = Time.get_ticks_msec()
	req.timeout_ms = int(timeout_sec * 1000.0)
	_pending[req.id] = req

	var msg := {"v": PythonProtocol.PROTOCOL_VERSION, "type": op, "id": req.id}
	for k in payload:
		msg[k] = payload[k]
	var err := _client.send_message(msg)
	if err != OK:
		_pending.erase(req.id)
		req.done.emit(PythonBridgeResult.failed("internal", "Sendefehler: " + str(err)))
	return req

func _handle_message(parsed: Dictionary) -> void:
	var msg: Dictionary = parsed["msg"]
	var mtype: String = str(msg.get("type", ""))
	match mtype:
		"hello_ack":
			_reconnect_left = MAX_RECONNECTS
			_set_state(State.READY)
			instance_ready.emit()
		"response":
			_handle_response(msg, parsed.get("data"))
		"event":
			print("[Python] event %s: %s" % [msg.get("kind", ""), JSON.stringify(msg.get("data", {}))])
		"status":
			print("[Python] status: " + JSON.stringify(msg))
		"pong":
			pass
		_:
			print("[Python] unbekannte Nachricht: " + JSON.stringify(msg))

func _handle_response(msg: Dictionary, data: Variant) -> void:
	var rid := str(msg.get("id", ""))
	if not _pending.has(rid):
		return
	var req: PendingRequest = _pending[rid]
	_pending.erase(rid)
	var status: String = str(msg.get("status", "error"))
	var result: PythonBridgeResult
	if status == "ok":
		result = PythonBridgeResult.success(data, {
			"duration_ms": float(msg.get("ms", 0)), "request_id": rid})
	else:
		var err: Dictionary = msg.get("error", {}) if (msg.get("error") is Dictionary) else {}
		result = PythonBridgeResult.failed("error", str(err.get("message", "Python-Fehler")), err)
	result.request_id = rid
	req.done.emit(result)

func _check_timeouts() -> void:
	var now := Time.get_ticks_msec()
	for rid in _pending.keys():
		var req: PendingRequest = _pending[rid]
		if now - req.created > req.timeout_ms:
			_pending.erase(rid)
			var res := PythonBridgeResult.failed("timeout", "Request-Timeout")
			res.request_id = rid
			req.done.emit(res)

func _fail_all_pending(status: String, message: String) -> void:
	for rid in _pending.keys():
		var res := PythonBridgeResult.failed(status, message)
		res.request_id = rid
		_pending[rid].done.emit(res)
	_pending.clear()

# ------------------------------------------------------------------ Zustand / Lifecycle
func _set_state(s: int) -> void:
	state = s
	state_changed.emit(instance_name, status_text())

func status_text() -> String:
	match state:
		State.READY: return "ready"
		State.PROVISIONING: return "provisioning"
		State.STARTING: return "starting"
		State.CONNECTING: return "connecting"
		State.HANDSHAKE: return "handshake"
		State.ERROR: return "error"
		State.STOPPED: return "stopped"
	return "none"

func is_active() -> bool:
	return state in [State.READY, State.HANDSHAKE, State.CONNECTING, State.STARTING, State.PROVISIONING]

func is_ready_immediately() -> bool:
	return state == State.READY

func last_error_message() -> String:
	return _last_error

func _set_error(msg: String) -> void:
	_last_error = msg
	_set_state(State.ERROR)
	push_error("[Python] " + msg)

func next_context_id() -> int:
	_context_counter += 1
	return _context_counter

func wait_ready(timeout_sec := 180.0) -> bool:
	if state == State.READY:
		return true
	var waited := 0.0
	while state != State.READY:
		if state in [State.ERROR, State.STOPPED]:
			return false
		if waited >= timeout_sec:
			return false
		if not _bridge:
			return false
		await _bridge.pulse
		waited += 0.05
	return true

func stop() -> void:
	_fail_all_pending("down", "Instanz gestoppt")
	if _client and _client.is_open():
		_client.send_message({"v": 1, "type": "shutdown", "id": "shutdown"})
	if _process:
		_process.kill()
	_set_state(State.STOPPED)

func shutdown_now() -> void:
	_fail_all_pending("down", "Instanz gestoppt")
	_set_state(State.STOPPED)
	if _process:
		_process.kill()
