class_name BridgeWsClient
extends RefCounted
## Wrapper um Godots WebSocketPeer (Client), mit Polling- und Frame-Handling.

const PROTOCOL_VERSION := 1

var peer: WebSocketPeer
var last_error: Error = OK
var connected: bool = false

func _init() -> void:
	peer = WebSocketPeer.new()
	peer.supported_protocols = PackedStringArray(["pybridge-v" + str(PROTOCOL_VERSION)])
	# Große Binär-Payloads (NumPy-Arrays, Bilder) zulassen.
	peer.inbound_buffer_size = 512 * 1024 * 1024
	peer.outbound_buffer_size = 512 * 1024 * 1024
	peer.max_queued_packets = 4096

func connect_to(host: String, port: int) -> Error:
	connected = false
	return peer.connect_to_url("ws://%s:%d" % [host, port])

## Muss pro Frame (oder in _process) gepollt werden.
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

## Liefere alle empfangenen, entschlüsselten Nachrichten.
## WICHTIG (Godot 4.7): Text-Frames kommen bei get_packet() als
## PackedByteArray an - was_string_packet() unterscheidet Text von Binär.
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