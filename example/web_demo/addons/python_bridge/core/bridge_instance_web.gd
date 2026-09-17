class_name BridgeWebInstance
extends BridgeInstance
## Web transport: the same bridge API backed by Pyodide in a Web Worker.
##
## Instead of a local Python process + WebSocket, this instance talks to a
## JS Web Worker (addons/python_bridge/web/bridge_worker.js) that runs the
## bridge Python package (python_bridge/browser_host.py) inside Pyodide with
## a virtual filesystem. Protocol v2 frames are identical; only the pipe
## differs.
##
## Reused from BridgeInstance (unchanged semantics, no duplicated logic):
##   - State machine incl. PROVISIONING -> STARTING -> CONNECTING ->
##     HANDSHAKE -> READY and every transition
##   - Restart policy (max_restart_attempts, exponential backoff,
##     stable-uptime reset)
##   - Health monitor wiring (ping/pong; browser_host answers MSG_PING)
##   - Message routing into the facade (message_received signal)
##   - Shutdown handshake (MSG_SHUTDOWN -> SHUTDOWN_ACK -> cleanup -> STOPPED)
##   - Connect timeout via the inherited _connect_start_ms probe
##
## Overridden (transport-specific, minimal):
##   - start(): no venv provisioning; the JS worker IS the runtime
##   - _launch(): BridgeWebConnection instead of process + WebSocket; the
##     shim flips `connected` when the worker reports {type:"ready"} and the
##     inherited CONNECTING poll then runs the normal HELLO handshake
##   - _cleanup_process(): terminates the worker instead of killing a process

var _web_client: BridgeWebConnection = null


func _init(bridge: Node, name_id: String, settings: Dictionary) -> void:
	super(bridge, name_id, settings)


func start() -> void:
	if not OS.has_feature("web"):
		_last_error = "BridgeWebInstance requires a web export (OS.has_feature(\"web\"))."
		_set_state(State.ERROR)
		lost.emit(instance_name, PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_DEPENDENCY_ERROR, _last_error, "", instance_name))
		return
	_set_state(State.PROVISIONING)
	# No venv/pip provisioning in the browser: the Pyodide worker bundles the
	# runtime. PROVISIONING -> STARTING happens without the provisioner tick.
	_launch()


func _launch() -> void:
	_set_state(State.STARTING)
	# Zombie prevention parity: drop a previous worker before making a new
	# one (crash path where only the message flow died).
	if _web_client != null:
		_web_client.connected = false
		_web_client = null
	_web_client = BridgeWebConnection.new(_settings)
	var err := _web_client.start_worker()
	if err != OK:
		_last_error = "Web worker creation failed (%d). Check web_worker_url." % err
		_set_state(State.ERROR)
		lost.emit(instance_name, PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_PROCESS_ERROR, _last_error, "", instance_name))
		return
	_client = _web_client
	_tmp_probe_tries = 0
	_ws_was_open = false
	_connect_start_ms = Time.get_ticks_msec()
	_health.reset()


func _cleanup_process() -> void:
	# Web counterpart of the desktop cleanup: terminate the worker. The
	# inherited _client reference is dropped by the base shutdown paths.
	if _client:
		_client = null
	if _web_client != null:
		_web_client.connected = false
		_web_client = null
	_health.reset()
