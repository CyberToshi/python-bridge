class_name ClusterDiscovery
extends RefCounted
## LAN-Discovery der Cluster-Worker (V1).
##
## Getrennt von der Aufgaben-Kommunikation: hier wird nur **erkannt**, welcher
## Rechner im lokalen Netz als Worker laeuft. Die eigentliche Arbeit laeuft
## danach ueber den WebSocket-Transport (siehe OrchestratorTransport).
##
## Ablauf:
##
##   Worker  ──UDP-Broadcast──►  {"t":"python_bridge_worker", "proto":1,
##                                "name":..., "port":8765, "pair":true,
##                                "queue_capacity":4, "token":"...",
##                                "tls":true, "scheme":"wss", "fp":"<sha256>"}
##   Manager ──UDP-Broadcast──►  {"t":"python_bridge_discover"}   (Suchanfrage)
##
## Laeuft der Worker verschluesselt (`wss://`), kuendigt er das im Beacon an. Der
## Manager uebernimmt daraus Schema **und** Fingerabdruck: der Fingerabdruck wird
## angezeigt, damit er mit der Worker-App verglichen werden kann.
##
## Die Discovery verwendet **kein** neues Netzwerk-Setup: ein UDP-Broadcast im
## eigenen LAN braucht weder Router-Konfiguration noch Portfreigaben. Faellt der
## Broadcast in einem Netz aus (manche Gastnetze), kann der Worker auch direkt
## per URL eingetragen werden – die Discovery ist nur der bequeme Weg.

signal worker_found(server_id: String, info: Dictionary)
signal worker_updated(server_id: String, info: Dictionary)
signal worker_lost(server_id: String)

const PROTOCOL := 1
const BEACON_TYPE := "python_bridge_worker"
const REQUEST_TYPE := "python_bridge_discover"
const DEFAULT_PORT := 8766
## Wie oft eine aktive Suchanfrage gesendet wird (beschleunigt den Start auf
## beiden Seiten, weil sich Bestands-Worker sofort melden).
const REQUEST_INTERVAL_MS := 4000
## Nach dieser Zeit ohne Beacon gilt ein Worker als verschwunden.
const LOST_AFTER_MS := 8000
const MAX_WORKERS := 64

var port: int = DEFAULT_PORT
## Beacons ohne Token werden gemeldet, aber als `needs_token` markiert.
var _socket: PacketPeerUDP
var _workers: Dictionary = {}          # server_id -> info
var _order: Array[String] = []
var _next_request_ms: int = 0
var _running := false


func start(p_port: int = -1) -> bool:
	if p_port > 0:
		port = p_port
	if _running:
		return true
	_socket = PacketPeerUDP.new()
	_socket.set_broadcast_enabled(true)
	var err := _socket.bind(port, "*")
	if err != OK:
		push_warning("[Cluster] Discovery-Port %d nicht belegbar (Fehler %d)" % [port, err])
		_socket = null
		return false
	_running = true
	_next_request_ms = 0
	return true


func stop() -> void:
	if _socket != null:
		_socket.close()
	_socket = null
	_running = false
	_workers.clear()
	_order.clear()


func is_running() -> bool:
	return _running


## Jeden Frame aufrufen: Pakete lesen, Zeitüberschreitungen erkennen.
func poll(now_ms: int = -1) -> void:
	if not _running or _socket == null:
		return
	var now := _now(now_ms)
	_read_packets()
	if now >= _next_request_ms:
		_next_request_ms = now + REQUEST_INTERVAL_MS
		_send_request()
	_expire(now)


## Erzwingt eine sofortige Suchanfrage (z. B. beim Start der Oberflaeche).
func request_scan(now_ms: int = -1) -> void:
	if _running:
		_next_request_ms = _now(now_ms) + REQUEST_INTERVAL_MS
		_send_request()


# ---------------------------------------------------------------- Abfragen
func worker_ids() -> Array[String]:
	return _order.duplicate()


func worker_count() -> int:
	return _order.size()


func get_worker(server_id: String) -> Dictionary:
	return (_workers.get(server_id, {}) as Dictionary).duplicate()


func workers() -> Array:
	var out: Array = []
	for id in _order:
		var info := _workers.get(id, {}) as Dictionary
		if not info.is_empty():
			out.append(info.duplicate())
	return out


func has_worker(server_id: String) -> bool:
	return _workers.has(server_id)


## Entfernt einen Worker aus der Discovery-Liste (nach manuellem Trennen).
func forget(server_id: String) -> void:
	if _workers.erase(server_id):
		_order.erase(server_id)


# ---------------------------------------------------------------- Intern
func _read_packets() -> void:
	while _socket.get_available_packet_count() > 0:
		var data := _socket.get_packet()
		var ip := _socket.get_packet_ip()
		_handle_packet(data, ip)


func _handle_packet(data: PackedByteArray, ip: String) -> void:
	if data.size() == 0 or data.size() > 8192:
		return
	# Frueh abbrechen, wenn es kein JSON-Objekt sein kann: spart Parsing und
	# verhindert Fehlermeldungen bei fremden Paketen (z. B. von anderen Diensten
	# auf demselben Port).
	var text := data.get_string_from_utf8().strip_edges()
	if text == "" or text[0] != "{":
		return
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return
	var msg := parsed as Dictionary
	if str(msg.get("t", "")) != BEACON_TYPE:
		return
	if int(msg.get("proto", PROTOCOL)) != PROTOCOL:
		return
	var ws_port := int(msg.get("port", 0))
	if ws_port <= 0 or ws_port > 65535:
		return
	var host := ip if ip != "" else str(msg.get("host", ""))
	if host == "":
		return
	var name := _sanitize_name(str(msg.get("name", "")))
	var server_id := _server_id_for(host, ws_port, name)
	# Nur bekannte Schemata uebernehmen; alles andere wird als Klartext behandelt.
	var tls := bool(msg.get("tls", false)) and str(msg.get("scheme", "wss")) != "ws"
	var info := {
		"server_id": server_id,
		"name": name if name != "" else server_id,
		"host": host,
		"port": ws_port,
		"url": "%s://%s:%d" % ["wss" if tls else "ws", host, ws_port],
		"tls": tls,
		"fingerprint": str(msg.get("fp", "")).strip_edges().to_lower(),
		"queue_capacity": maxi(int(msg.get("queue_capacity", 0)), 1),
		"token": str(msg.get("token", "")),
		"pair": bool(msg.get("pair", false)),
		"last_seen_ms": _now(-1),
	}
	if info["token"] == "":
		info["needs_token"] = true
	if not _workers.has(server_id):
		if _workers.size() >= MAX_WORKERS:
			return
		_workers[server_id] = info
		_order.append(server_id)
		worker_found.emit(server_id, info.duplicate())
		return
	var previous := _workers[server_id] as Dictionary
	var changed := str(previous.get("url", "")) != str(info["url"]) \
		or str(previous.get("token", "")) != str(info["token"]) \
		or str(previous.get("fingerprint", "")) != str(info.get("fingerprint", ""))
	info["needs_token"] = str(info["token"]) == ""
	_workers[server_id] = info
	if changed:
		worker_updated.emit(server_id, info.duplicate())


func _expire(now_ms: int) -> void:
	for server_id in _order.duplicate():
		var info := _workers.get(server_id, {}) as Dictionary
		if info.is_empty():
			continue
		if now_ms - int(info.get("last_seen_ms", 0)) <= LOST_AFTER_MS:
			continue
		_workers.erase(server_id)
		_order.erase(server_id)
		worker_lost.emit(str(server_id))


func _send_request() -> void:
	if _socket == null:
		return
	var payload := JSON.stringify({"t": REQUEST_TYPE, "proto": PROTOCOL}).to_utf8_buffer()
	_socket.set_dest_address("255.255.255.255", port)
	_socket.put_packet(payload)


## Oeffentlicher Helfer fuer andere Klassen (ClusterManager).
static func safe_id(raw: String) -> String:
	return _safe_id(raw)


## Stabile, GraphEdit-taugliche Server-ID aus Name + Endpunkt.
## Gleicher Name auf zwei Rechnern erzeugt bewusst zwei IDs (Host im Suffix).
func _server_id_for(host: String, ws_port: int, name: String) -> String:
	var base := _safe_id(name)
	if base == "":
		base = "worker"
	var candidate := base
	if _workers.has(candidate):
		var existing := _workers[candidate] as Dictionary
		if str(existing.get("host", "")) != host or int(existing.get("port", 0)) != ws_port:
			candidate = "%s-%s" % [base, _safe_id(host)]
			if _workers.has(candidate):
				candidate = "%s-%s-%d" % [base, _safe_id(host), ws_port]
	return candidate


## Entfernt Zeichen, die in Node-Namen/NodePaths nicht erlaubt sind.
static func _safe_id(raw: String) -> String:
	var out := ""
	for i in raw.length():
		var ch := raw[i]
		if ch == " " or ch == "-":
			out += "_"
		elif (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") \
				or (ch >= "0" and ch <= "9") or ch == "_" or ch == ".":
			out += ch
	out = out.strip_edges()
	if out.length() > 48:
		out = out.substr(0, 48)
	return out


static func _sanitize_name(raw: String) -> String:
	var out := ""
	for i in raw.length():
		var ch := raw[i]
		if ch != "\n" and ch != "\r" and ch != "\t":
			out += ch
	out = out.strip_edges()
	if out.length() > 64:
		out = out.substr(0, 64)
	return out


static func _now(now_ms: int) -> int:
	return now_ms if now_ms >= 0 else Time.get_ticks_msec()
