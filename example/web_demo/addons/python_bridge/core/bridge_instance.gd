class_name BridgeInstance
extends Node
## One Python instance = one subprocess + one WebSocket channel.
##
## Owns the transport and lifecycle only; task orchestration lives in the
## facade's TaskManager/Scheduler. Incoming task results are forwarded via
## the `message_received` signal; the facade routes them into the scheduler.
##
## State machine:
##   NONE -> PROVISIONING -> STARTING -> CONNECTING -> HANDSHAKE -> READY
##   any -> CRASHED -> RESTARTING -> STARTING (backoff) | ERROR (permanent)
##   any -> STOPPING -> STOPPED
##
## Crash handling: an unexpected WebSocket close or a dead subprocess while
## READY triggers the restart policy (max_restart_attempts, exponential
## backoff, counter reset after stable_uptime_ms). In-flight tasks are failed
## through the `lost` signal so the facade can resolve them.
##
## No threads: provisioning and process launch are poll-based via
## OS.create_process; the WebSocket is polled every frame.

signal state_changed(instance: String, state: String)
signal message_received(instance: String, parsed: Dictionary)
signal lost(instance: String, error: Dictionary)
signal instance_ready(instance: String)

enum State {
	NONE, PROVISIONING, STARTING, CONNECTING, HANDSHAKE, READY,
	CRASHED, RESTARTING, STOPPING, STOPPED, ERROR
}

const PORT_PROBE_MAX := 1800
const PING_INTERVAL_MS := 5000

var instance_name: String = ""
var state: int = State.NONE

var _settings: Dictionary = {}
var _client: BridgeConnectionManager = null
var _provisioner: BridgeProvisioner = null
var _process: BridgeProcessManager = null
var _health: BridgeHealthMonitor = null

var _tmp_probe_tries: int = 0
var _connect_start_ms: int = 0
var _ws_was_open: bool = false
var _port: int = 0
var _pid: int = 0
var _last_error: String = ""

# Restart policy state
var _restart_attempts: int = 0
var _restart_at_ms: int = 0
var _ready_since_ms: int = 0
var _shutdown_started_ms: int = 0
var _shutdown_ack_received: bool = false

func _init(bridge: Node, name_id: String, settings: Dictionary) -> void:
	instance_name = name_id
	_settings = settings
	_health = BridgeHealthMonitor.new(
		int(_settings.get("health_check_interval_ms", PING_INTERVAL_MS)),
		int(_settings.get("health_missed_pong_limit", 3)))

# ------------------------------------------------------------------ Start
func start() -> void:
	_set_state(State.PROVISIONING)
	_provisioner = BridgeProvisioner.new()
	_provisioner.start(_settings, self, "_on_provision_done")

func _on_provision_done(ok: bool, msg: String) -> void:
	if _provisioner:
		_provisioner = null
	if not ok:
		_last_error = msg
		var err := PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_DEPENDENCY_ERROR, msg, "", instance_name)
		_set_state(State.ERROR)
		lost.emit(instance_name, err)
		return
	_launch()

func _launch() -> void:
	_set_state(State.STARTING)
	# Zombie prevention: if a previous process is still around (crash where
	# only the WebSocket died), kill it before starting a new one.
	if _process:
		if _process.is_running():
			_process.kill()
		_process.forget()
	var ws: String = str(_settings.get("workspace_fs", ""))
	var runner: String = str(_settings.get("bridge_python_dir", "")) + "/run_server.py"
	if ws == "" or runner == "/run_server.py":
		_last_error = "Python workspace or bundled runner path is not configured."
		_set_state(State.ERROR)
		lost.emit(instance_name, PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_PROCESS_ERROR, _last_error, "", instance_name))
		return
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
	# Output-/Resultat-Caps: werden beim Start gesetzt, damit der Python-Server
	# stdout/stderr begrenzt erfassen und zu grosse Ergebnisse ablehnen kann.
	cmd.append("--max-stdout-bytes")
	cmd.append(str(int(_settings.get("max_stdout_bytes", 1024 * 1024))))
	cmd.append("--max-stderr-bytes")
	cmd.append(str(int(_settings.get("max_stderr_bytes", 1024 * 1024))))
	cmd.append("--max-result-bytes")
	cmd.append(str(int(_settings.get("max_result_bytes", 256 * 1024 * 1024))))
	# Data-Plane: Schwelle fuer automatische DataRef-Handles grosser Ergebnisse.
	cmd.append("--data-ref-threshold-bytes")
	cmd.append(str(int(_settings.get("data_ref_threshold_bytes", 16 * 1024 * 1024))))
	# Phase 3: Worker-Slots und Watchdog-Grace-Frist (Kill-on-Runaway).
	cmd.append("--workers")
	cmd.append(str(int(_settings.get("workers_per_instance", 1))))
	cmd.append("--runaway-grace-ms")
	cmd.append(str(int(_settings.get("runaway_grace_ms", 10000))))
	# Stale-port protection: remove a leftover port file from a previous run
	# so the STARTING probe cannot connect to a long-dead server.
	var stale_port_file := ws + "/tmp/%s.json" % instance_name
	if FileAccess.file_exists(stale_port_file):
		DirAccess.remove_absolute(stale_port_file)
	_process = BridgeProcessManager.new()
	_process.kill_marker = "--tag " + instance_name
	if not _process.start(cmd):
		_last_error = "Process launch failed."
		_set_state(State.ERROR)
		lost.emit(instance_name, PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_PROCESS_ERROR, _last_error, "", instance_name))
		return
	_client = BridgeConnectionManager.new()
	_tmp_probe_tries = 0
	_ws_was_open = false
	_health.reset()

func _venv_python(ws: String) -> String:
	if OS.get_name() == "Windows":
		return ws + "/venv/Scripts/python.exe"
	return ws + "/venv/bin/python"

# ------------------------------------------------------------------ Poll (per frame)
func tick() -> void:
	if state == State.NONE or state == State.STOPPED or state == State.ERROR:
		return
	var now := Time.get_ticks_msec()

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
				_send_hello()
			elif now - _connect_start_ms > int(_settings.get("connect_timeout_ms", 20000)):
				_on_crash(PythonBridgeErrorHandler.make(
					PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR,
					"Connect timeout after %d ms" % int(_settings.get("connect_timeout_ms", 20000)),
					"", instance_name))
		State.HANDSHAKE, State.READY:
			_client.poll()
			if not _client.is_open():
				if _ws_was_open:
					_on_crash(PythonBridgeErrorHandler.make(
						PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR,
						"Python process disconnected (WebSocket closed)", "", instance_name))
				_ws_was_open = false
				return
			_ws_was_open = true
			# Byte-Budget pro Frame: grosse Antworten werden ueber mehrere Frames
			# verteilt dekodiert statt in einem Frame (Main-Thread-Schutz).
			for parsed in _client.drain(int(_settings.get("max_decode_bytes_per_frame", 16 * 1024 * 1024))):
				_handle_message(parsed)
			if state == State.READY:
				_tick_health(now)
				# A health failure already crashed us; do not double-crash.
				if state != State.READY:
					return
				# Secondary crash signal: subprocess died without closing WS.
				if _process and not _process.is_running():
					_on_crash(PythonBridgeErrorHandler.make(
						PythonBridgeErrorHandler.CATEGORY_PROCESS_ERROR,
						"Python process exited (exit code %d)" % _process.get_exit_code(),
						"", instance_name))
		State.CRASHED:
			if now >= _restart_at_ms:
				_set_state(State.RESTARTING)
				_launch()
		State.RESTARTING:
			pass
		State.STOPPING:
			_finish_shutdown(now)
		_:
			pass

func _tick_health(now_ms: int) -> void:
	# Reset restart counter after a stable uptime.
	if _ready_since_ms > 0 and now_ms - _ready_since_ms > int(_settings.get("stable_uptime_ms", 30000)):
		_restart_attempts = 0
		_ready_since_ms = now_ms # avoid re-resetting every frame

	if _health.should_ping(now_ms):
		_health.record_ping_sent(now_ms)
		if _client and _client.is_open():
			_client.mark_ping_sent()
			_client.send_message({
				"v": PythonProtocol.PROTOCOL_VERSION,
				"type": PythonProtocol.MSG_PING,
				"id": "ping-" + instance_name,
			})
	if not _health.tick(now_ms):
		_on_crash(PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR,
			"Health check failed: %d missed pongs" % _health.missed_windows(),
			"", instance_name))

func _send_hello() -> void:
	var msg := {
		"v": PythonProtocol.PROTOCOL_VERSION,
		"type": PythonProtocol.MSG_HELLO,
		"id": "hello-" + instance_name,
	}
	_client.send_message(msg)

func _probe_temp_file() -> void:
	var tmpf := str(_settings.get("workspace_fs", "res://python_bridge")) + "/tmp/%s.json" % instance_name
	if not FileAccess.file_exists(tmpf):
		_tmp_probe_tries += 1
		if _tmp_probe_tries > PORT_PROBE_MAX:
			_on_crash(PythonBridgeErrorHandler.make(
				PythonBridgeErrorHandler.CATEGORY_PROCESS_ERROR,
				"No port file from subprocess (timeout)", "", instance_name))
		return
	var f := FileAccess.open(tmpf, FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if d is Dictionary and int(d.get("port", 0)) > 0:
		_port = int(d["port"])
		_pid = int(d.get("pid", 0))
		_connect_start_ms = Time.get_ticks_msec()
		_set_state(State.CONNECTING)
		var err := _client.connect_to("127.0.0.1", _port)
		if err != OK:
			_on_crash(PythonBridgeErrorHandler.make(
				PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR,
				"WebSocket connect error: %s" % err, "", instance_name))
	else:
		_tmp_probe_tries += 1
		if _tmp_probe_tries > PORT_PROBE_MAX:
			_on_crash(PythonBridgeErrorHandler.make(
				PythonBridgeErrorHandler.CATEGORY_PROCESS_ERROR,
				"Invalid port file (timeout)", "", instance_name))

# ------------------------------------------------------------------ Messages
func _handle_message(parsed: Dictionary) -> void:
	var msg: Dictionary = parsed.get("msg", {})
	var mtype: String = str(msg.get("type", ""))
	match mtype:
		PythonProtocol.MSG_HELLO_ACK:
			_restart_attempts = 0
			_ready_since_ms = Time.get_ticks_msec()
			_set_state(State.READY)
			instance_ready.emit(instance_name)
		PythonProtocol.MSG_PONG:
			if _client:
				_client.mark_pong_received()
			_health.record_pong()
		PythonProtocol.MSG_SHUTDOWN_ACK:
			_shutdown_ack_received = true
		PythonProtocol.MSG_TASK_RESULT, PythonProtocol.MSG_TASK_ERROR, PythonProtocol.MSG_BATCH_RESULT, PythonProtocol.MSG_EVENT, PythonProtocol.MSG_STATUS, PythonProtocol.MSG_DATA_RESULT, PythonProtocol.MSG_DATA_ACK:
			message_received.emit(instance_name, parsed)
		_:
			print("[Python][%s] unknown message: %s" % [instance_name, JSON.stringify(msg)])

# ------------------------------------------------------------------ Crash / restart
func _on_crash(err: Dictionary) -> void:
	_last_error = str(err.get("message", "Unknown crash"))
	_ws_was_open = false
	if _client:
		_client = null
	lost.emit(instance_name, err)
	var max_attempts := int(_settings.get("max_restart_attempts", 3))
	if _restart_attempts >= max_attempts:
		_set_state(State.ERROR)
		return
	_restart_attempts += 1
	var base := int(_settings.get("restart_base_delay_ms", 500))
	var factor := int(_settings.get("restart_backoff_factor", 2))
	var delay := base * int(pow(factor, _restart_attempts - 1))
	_restart_at_ms = Time.get_ticks_msec() + delay
	_set_state(State.CRASHED)
	push_warning("[Python][%s] crash (%s) - restart %d/%d in %d ms" % [
		instance_name, _last_error, _restart_attempts, max_attempts, delay])

# ------------------------------------------------------------------ Shutdown
## Graceful stop: sends SHUTDOWN, waits up to shutdown_timeout_ms, then
## force-kills the process. Never blocks; completion is polled in tick().
func stop() -> void:
	if state in [State.STOPPING, State.STOPPED, State.NONE]:
		return
	_shutdown_ack_received = false
	if _client and _client.is_open():
		_client.send_message({
			"v": PythonProtocol.PROTOCOL_VERSION,
			"type": PythonProtocol.MSG_SHUTDOWN,
			"id": "shutdown-" + instance_name,
		})
	_set_state(State.STOPPING)
	_shutdown_started_ms = Time.get_ticks_msec()

func _finish_shutdown(now_ms: int) -> void:
	var timeout := int(_settings.get("shutdown_timeout_ms", 3000))
	var done := false
	if not done and _client:
		# Keep polling so the SHUTDOWN_ACK arrives instead of waiting for the
		# full timeout.
		_client.poll()
		for parsed in _client.drain():
			_handle_message(parsed)
		if _shutdown_ack_received:
			done = true
		elif not _client.is_open():
			done = true
	if not done and _process and not _process.is_running():
		done = true
	if not done and now_ms - _shutdown_started_ms > timeout:
		done = true
	if done:
		_cleanup_process()
		_set_state(State.STOPPED)

## Immediate stop (force kill).
func shutdown_now() -> void:
	_cleanup_process()
	_set_state(State.STOPPED)

func _cleanup_process() -> void:
	if _client:
		_client = null
	if _process:
		if _process.is_running():
			_process.kill()
		_process.forget()
	_health.reset()

# ------------------------------------------------------------------ Sending
func send_message(msg: Dictionary) -> Error:
	if not _client or not _client.is_open():
		return ERR_UNAVAILABLE
	return _client.send_message(msg)

# ------------------------------------------------------------------ State
func _set_state(s: int) -> void:
	if state == s:
		return
	state = s
	state_changed.emit(instance_name, status_text())

func status_text() -> String:
	match state:
		State.READY: return "ready"
		State.PROVISIONING: return "provisioning"
		State.STARTING: return "starting"
		State.CONNECTING: return "connecting"
		State.HANDSHAKE: return "handshake"
		State.CRASHED: return "crashed"
		State.RESTARTING: return "restarting"
		State.STOPPING: return "stopping"
		State.STOPPED: return "stopped"
		State.ERROR: return "error"
	return "none"

func is_active() -> bool:
	return state in [State.READY, State.HANDSHAKE, State.CONNECTING,
		State.STARTING, State.PROVISIONING, State.CRASHED, State.RESTARTING]

func is_ready_immediately() -> bool:
	return state == State.READY

func is_ready() -> bool:
	return state == State.READY

func last_error_message() -> String:
	return _last_error

func wait_ready(timeout_sec := 300.0) -> bool:
	if state == State.READY:
		return true
	var waited := 0.0
	while state != State.READY:
		if state in [State.ERROR, State.STOPPED]:
			return false
		if waited >= timeout_sec:
			return false
		await get_tree().process_frame
		waited += 0.016
	return true