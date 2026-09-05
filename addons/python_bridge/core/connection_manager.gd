class_name BridgeConnectionManager
extends RefCounted
## WebSocket client wrapper (transport only) with frame-level handling.
##
## The instance owns the connection lifecycle (connect, poll, reconnect);
## this class wraps Godot's WebSocketPeer and converts raw packets into
## parsed frames via PythonProtocol. Ping/pong timing is tracked here so the
## health monitor can measure missed pongs without extra bookkeeping.
##
## All methods must be called from the main thread (poll model).

const PROTOCOL_VERSION: int = PythonProtocol.PROTOCOL_VERSION

var peer: WebSocketPeer
var last_error: Error = OK
var connected: bool = false

# Ping/pong bookkeeping (ms since epoch via Time.get_ticks_msec())
var last_ping_ms: int = 0
var last_pong_ms: int = 0
var pending_ping: bool = false

func _init() -> void:
	peer = WebSocketPeer.new()
	peer.supported_protocols = PackedStringArray(["pybridge-v" + str(PROTOCOL_VERSION)])
	# Large binary payloads (NumPy arrays, images) must fit.
	peer.inbound_buffer_size = 512 * 1024 * 1024
	peer.outbound_buffer_size = 512 * 1024 * 1024
	peer.max_queued_packets = 4096

func connect_to(host: String, port: int) -> Error:
	connected = false
	last_error = OK
	last_ping_ms = 0
	last_pong_ms = 0
	pending_ping = false
	return peer.connect_to_url("ws://%s:%d" % [host, port])

## Must be called every frame (or in _process) while the instance is active.
func poll() -> void:
	peer.poll()
	connected = peer.get_ready_state() == WebSocketPeer.STATE_OPEN
	if not connected and peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		last_error = peer.get_packet_error()

func is_open() -> bool:
	return connected

func send_message(msg: Dictionary) -> Error:
	var frame: Dictionary = PythonProtocol.build_frame(msg)
	if frame.has("binary"):
		return peer.send(frame["binary"] as PackedByteArray)
	return peer.send_text(frame["text"])

## Returns all received, decoded frames as Array of {"msg": ..., "data": ...}.
## IMPORTANT (Godot 4): text packets arrive as PackedByteArray via
## get_packet(); was_string_packet() distinguishes text from binary.
func drain() -> Array:
	var msgs: Array = []
	while peer.get_available_packet_count() > 0:
		var pkt: Variant = peer.get_packet()
		var parsed: Dictionary
		if peer.was_string_packet():
			var text := (pkt as PackedByteArray).get_string_from_utf8() if pkt is PackedByteArray else str(pkt)
			parsed = PythonProtocol.parse_frame(text)
		else:
			parsed = PythonProtocol.parse_frame(pkt)
		if not parsed.is_empty() and (parsed["msg"] as Dictionary).size() > 0:
			msgs.append(parsed)
	return msgs

## Marks a ping as sent (called by the health monitor).
func mark_ping_sent() -> void:
	last_ping_ms = Time.get_ticks_msec()
	pending_ping = true

## Marks a pong as received (called by the instance on MSG_PONG).
func mark_pong_received() -> void:
	last_pong_ms = Time.get_ticks_msec()
	pending_ping = false