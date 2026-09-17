class_name BridgeWebConnection
extends BridgeConnectionManager
## Transport shim for the web platform.
##
## Extends BridgeConnectionManager so BridgeWebInstance can reuse the entire
## BridgeInstance state machine unchanged (handshake, health ping/pong,
## drain budgets, shutdown handshake). Instead of a WebSocketPeer it talks to
## a JS Web Worker (addons/python_bridge/web/bridge_worker.js) that runs the
## bridge Python package inside Pyodide with a virtual filesystem.
##
## Frame mapping (Protocol v2 is untouched):
##   GDScript -> Worker: {type:"bridge", text:String} for text frames,
##                       {type:"bridge", b64:String} for binary frames
##   Worker -> GDScript: {type:"bridge", text|b64}, plus lifecycle events
##                       {type:"ready"|"log"|"error"}
##
## All JS access goes through JavaScriptBridge and only exists in web builds;
## never instantiate this class on other platforms.

# Inherited members (connected, last_error, ping bookkeeping, _pending_raw)
# are reused; do not redeclare them.

var ready_status: Dictionary = {}

var _cfg: Dictionary = {}
var _worker: JavaScriptObject = null
var _cb_message: JavaScriptObject = null
var _cb_error: JavaScriptObject = null
var _last_logs: Array = []


func _init(cfg: Dictionary = {}) -> void:
	_cfg = cfg
	# The base _init() runs implicitly and creates an unused WebSocketPeer;
	# harmless, and all peer-touching methods are overridden below.


func connect_to(_host: String, _port: int) -> Error:
	# Not used by the web transport; kept for interface parity.
	connected = false
	last_error = OK
	return OK


## Worker events are push-based; nothing to pump. Kept for interface parity.
func poll() -> void:
	pass


## Creates the JS Worker with the configured runtime parameters. The worker
## script must be reachable as a same-origin URL next to the export
## (tools/build_web_bundle.py places it there) or via an absolute URL
## configured in web_worker_url.
func start_worker() -> Error:
	if not OS.has_feature("web"):
		return ERR_UNAVAILABLE
	var url := _worker_url()
	if url == "":
		return ERR_INVALID_PARAMETER
	_cb_message = JavaScriptBridge.create_callback(_on_worker_message)
	_cb_error = JavaScriptBridge.create_callback(_on_worker_error)
	_worker = JavaScriptBridge.create_object("Worker", url)
	if _worker == null:
		return ERR_CANT_CREATE
	_worker.onmessage = _cb_message
	_worker.onerror = _cb_error
	return OK


func _worker_url() -> String:
	var url := str(_cfg.get("web_worker_url", "bridge_worker.js"))
	if url.begins_with("res://"):
		# Files inside the PCK are not fetchable URLs: the build tool copies
		# the worker next to the export, so resolve to a page-relative path.
		url = url.trim_prefix("res://")
	var params := PackedStringArray()
	_append_param(params, "pyodide", str(_cfg.get("web_pyodide_dir", "")))
	_append_param(params, "cdn", str(_cfg.get("web_cdn_url", "")))
	_append_param(params, "bundle", str(_cfg.get("web_bundle_url", "")))
	_append_param(params, "packages", str(_cfg.get("web_packages", "")))
	_append_param(params, "maxStdoutBytes", str(int(_cfg.get("max_stdout_bytes", 0))))
	_append_param(params, "maxStderrBytes", str(int(_cfg.get("max_stderr_bytes", 0))))
	_append_param(params, "maxResultBytes", str(int(_cfg.get("max_result_bytes", 0))))
	_append_param(params, "dataRefThresholdBytes", str(int(_cfg.get("data_ref_threshold_bytes", 0))))
	_append_param(params, "tag", str(_cfg.get("web_tag", "web")))
	if params.is_empty():
		return url
	return url + ("&" if url.contains("?") else "?") + "&".join(params)


func _append_param(params: PackedStringArray, key: String, value: String) -> void:
	if value == "":
		return
	params.append("%s=%s" % [key.uri_encode(), value.uri_encode()])


func is_open() -> bool:
	return connected


## Returns all received frames, parsed via PythonProtocol (same contract as
## the base class drain). `byte_budget` limits the raw bytes decoded per
## call; the front-most frame always goes through.
func drain(byte_budget := -1) -> Array:
	var msgs: Array = []
	var consumed := 0
	while not _pending_raw.is_empty():
		var entry: Dictionary = _pending_raw[0]
		var cost := _raw_cost(entry)
		if byte_budget >= 0 and consumed > 0 and consumed + cost > byte_budget:
			break
		consumed += cost
		_pending_raw.pop_front()
		var parsed: Dictionary
		if entry.has("text"):
			parsed = PythonProtocol.parse_frame(str(entry["text"]))
		else:
			parsed = PythonProtocol.parse_frame(Marshalls.base64_to_raw(str(entry["b64"])))
		if not parsed.is_empty() and (parsed["msg"] as Dictionary).size() > 0:
			msgs.append(parsed)
	last_drain_bytes = consumed
	return msgs


func _raw_cost(entry: Dictionary) -> int:
	if entry.has("text"):
		return str(entry["text"]).length()
	return str(entry["b64"]).length() * 3 / 4


func send_message(msg: Dictionary) -> Error:
	if _worker == null or not connected:
		return ERR_UNAVAILABLE
	var frame: Dictionary = PythonProtocol.build_frame(msg)
	var payload := JavaScriptBridge.create_object("Object")
	payload.type = "bridge"
	if frame.has("binary"):
		payload.b64 = Marshalls.raw_to_base64(frame["binary"] as PackedByteArray)
	else:
		payload.text = str(frame["text"])
	_worker.postMessage(payload)
	return OK


## Terminates the worker when the connection is dropped (crash, shutdown).
## A relaunch simply creates a fresh worker.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _worker != null:
		_worker.terminate()
		_worker = null


# ------------------------------------------------------------------ worker events
func _on_worker_message(args: Array) -> void:
	if args.is_empty():
		return
	var ev := args[0] as JavaScriptObject
	if ev == null:
		return
	var data: Variant = ev.data
	if data == null or not (data is JavaScriptObject):
		return
	var obj := data as JavaScriptObject
	var mtype := String(obj.type) if obj.type != null else ""
	match mtype:
		"ready":
			connected = true
			ready_status = _js_dict(obj.status)
		"log":
			var text := String(obj.text) if obj.text != null else ""
			_last_logs.append(text)
			if _last_logs.size() > 50:
				_last_logs.pop_front()
			print("[PythonBridgeWeb] ", text)
		"error":
			var err_text := String(obj.text) if obj.text != null else "worker error"
			_last_logs.append(err_text)
			connected = false
			push_error("[PythonBridgeWeb] " + err_text)
		"bridge":
			if obj.text != null:
				_pending_raw.append({"text": String(obj.text)})
			elif obj.b64 != null:
				_pending_raw.append({"b64": String(obj.b64)})


func _on_worker_error(args: Array) -> void:
	connected = false
	var detail := ""
	if not args.is_empty() and args[0] != null:
		detail = str(args[0])
	push_error("[PythonBridgeWeb] worker failed: " + detail)


func _js_dict(v: Variant) -> Dictionary:
	if v == null or not (v is JavaScriptObject):
		return {}
	var obj := v as JavaScriptObject
	var out := {}
	for key in ["python", "platform", "version", "workspace"]:
		if obj[key] != null:
			out[key] = String(obj[key])
	return out


func recent_logs() -> Array:
	return _last_logs.duplicate()
