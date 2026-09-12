class_name OrchestratorTransport
extends RefCounted
## Netzwerk-Anbindung des Orchestrators an entfernte Worker (echter Transport).
##
## Der Kern (Server-/Task-Manager, Router, Dispatcher) ist transportunabhängig.
## Diese Klasse ist die **einzige** Stelle, die tatsächlich über das Netz spricht.
## Sie verbindet jeden Worker als eigenen WebSocketPeer und übersetzt zwischen
## Draht-Protokoll und Kern:
##
##   Worker → Controller:  heartbeat, ack, started, result, cancel_ack, pong
##   Controller → Worker:  run, cancel, ping
##
## Das Gegenstück ist `orchestrator/worker/orchestrator_worker.py`. Damit läuft
## ein Worker auf einem beliebigen anderen Rechner im LAN.
##
## Der Controller verbindet sich **ausgehend** zum Worker. Auf der Workerseite
## muss also nur der Worker-Port erreichbar sein (kein Portforwarding auf der
## Controller-Seite).
##
## VERSCHLUESSELUNG (TLS):
##
##   ws://....   unverschluesselt (Standard im vertrauten LAN)
##   wss://....  TLS. Dafuer gibt es genau zwei ehrliche Vertrauensarten:
##
##     PINNED   Das Zertifikat des Workers wird als Datei hinterlegt
##              (TLSOptions.client) -> echte Pruefung von Signatur und
##              Gueltigkeit. Das ist die starke Variante.
##     UNSAFE   Selbstsignierte Zertifikate werden bewusst akzeptiert
##              (TLSOptions.client_unsafe) -> Verbindung ist verschluesselt,
##              die Identitaet des Gegenuebers aber NICHT geprueft.
##
##   Ohne beides bleibt es beim System-Vertrauensspeicher; ein selbstsignierter
##   Worker scheitert dann sichtbar mit einer Erklaerung (kein stilles
##   Herabsetzen der Sicherheit).
##
##   Grund fuer diese Aufteilung: Godot reicht bei `WebSocketPeer` weder einen
##   eigenen Zertifikatspruefer noch das empfangene Zertifikat durch. Eine
##   "Fingerabdruck-Pruefung" ist damit nicht moeglich - und eine zu behaupten,
##   waere schlimmer als sie nicht zu haben.

signal worker_connected(server_id: String)
signal worker_disconnected(server_id: String, reason: String)
signal worker_message(server_id: String, message_type: String)
## Senden fehlgeschlagen (Verbindung zu, Nutzlast zu gross ...). Die Aufgabe
## laeuft deshalb in den ACK-Timeout; hier gibt es die Erklaerung dafuer.
signal send_failed(server_id: String, reason: String)
## Der TLS-Handshake ist gescheitert oder die Vertrauensart fehlt. Wird genau
## **einmal** je Worker gemeldet, damit der Benutzer eine konkrete Anleitung
## bekommt statt eines endlosen Reconnect-Logs.
signal tls_problem(server_id: String, hint: String)

## Vertrauensarten fuer wss:// (siehe Kopfkommentar).
enum TlsTrust { SYSTEM, PINNED, UNSAFE }

## Muss zu `OrchestratorConfig.max_payload_bytes` passen (etwas groesser, damit
## das JSON-Geruest noch hineinpasst).
const MAX_WIRE_BYTES := 8 * 1024 * 1024
const MAX_QUEUED_PACKETS := 4096
const PING_INTERVAL_MS := 1000
const RECONNECT_DELAY_MS := 1500
## Wiederholte Fehlversuche werden schrittweise langsamer (max. dieser Wert).
## Ohne das wuerde ein dauerhaft abwesender Rechner alle 1,5 s erneut versucht
## und das Log fluten.
const RECONNECT_MAX_DELAY_MS := 30000
const DEFAULT_CAPACITY := 4
## Orchestrator-Node-IDs werden als Godot-Node-Namen verwendet (GraphEdit);
## diese Zeichen sind in NodePaths nicht erlaubt.
const _INVALID_ID_CHARS := ["/", ":", "@", "\"", "%", " "]

var cfg: OrchestratorConfig
var servers: OrchestratorServerManager
var dispatcher: OrchestratorDispatcher
## Optionaler Datei-Transfer (Phase 6-8). Ist er gesetzt, laufen `file_*`-
## Nachrichten hier durch und der Transfer benutzt `send_message` als Sender.
var file_transfer: OrchestratorFileTransfer = null

var _peers: Dictionary = {}    # server_id -> {peer, url, token, connected, authed, last_ping_ms, retry_at_ms, attempts}


func _init(p_servers: OrchestratorServerManager, p_dispatcher: OrchestratorDispatcher,
		p_config: OrchestratorConfig = null) -> void:
	servers = p_servers
	dispatcher = p_dispatcher
	cfg = p_config if p_config != null else OrchestratorConfig.defaults()
	dispatcher.dispatch_payload_requested.connect(_on_dispatch_payload_requested)
	dispatcher.cancel_requested.connect(_on_cancel_requested)


# ---------------------------------------------------------------- Verwaltung
## Verbindet einen Worker. `url` z. B. `ws://192.168.1.42:8765`.
## `token` ist das Shared Secret des Workers (Pflicht dort – siehe
## `orchestrator_worker.py`); ohne Token bricht die Workerseite den
## Handshake mit 4401 ab.
func add_worker(server_id: String, url: String, name := "", capacity := -1,
		token := "", ca_path := "") -> bool:
	if not _valid_id(server_id) or url == "" or _peers.has(server_id):
		return false
	var trust := _trust_for(url, ca_path)
	if trust == TlsTrust.PINNED and _load_ca(ca_path) == null:
		# Lieber ablehnen als unbemerkt schwaecher verbinden. Gemeldet wird das
		# ueber `send_failed` (landet im Protokoll der Oberflaeche) - eine
		# Engine-Fehlermeldung waere hier nur Rauschen.
		push_warning("[Orchestrator] Zertifikat nicht lesbar: %s" % ca_path)
		send_failed.emit(server_id, "Zertifikat nicht lesbar: %s" % ca_path)
		return false
	var peer := WebSocketPeer.new()
	# Projekt-/Code-Uebertragung braucht mehr Puffer als die 64-KB-Standardwerte,
	# sonst scheitert das Senden groesserer Auftraege still.
	peer.inbound_buffer_size = MAX_WIRE_BYTES
	peer.outbound_buffer_size = MAX_WIRE_BYTES
	peer.max_queued_packets = MAX_QUEUED_PACKETS
	if peer.connect_to_url(url, _tls_options(trust, ca_path)) != OK:
		push_warning("[Orchestrator] Worker nicht erreichbar: %s (%s)" % [url, server_id])
		return false
	var cap := capacity if capacity > 0 else DEFAULT_CAPACITY
	if not servers.has_server(server_id):
		servers.add_server(server_id, _sanitize_name(name, server_id), _host_of(url), _port_of(url), cap)
	_peers[server_id] = {
		"peer": peer,
		"url": url,
		"token": token,
		"ca_path": ca_path,
		"trust": trust,
		"secure": url.begins_with("wss://"),
		"connected": false,
		"authed": false,
		"last_ping_ms": 0,
		"retry_at_ms": 0,
		"attempts": 0,
		"tls_hint_sent": false,
	}
	return true


## Vertrauensart eines Workers als Text (fuer Oberflaeche und Protokoll).
func tls_label(server_id: String) -> String:
	var entry: Dictionary = _peers.get(server_id, {})
	if entry.is_empty():
		return ""
	if not bool(entry.get("secure", false)):
		return "offen"
	match int(entry.get("trust", TlsTrust.SYSTEM)):
		TlsTrust.PINNED:
			return "geprueft"
		TlsTrust.UNSAFE:
			return "verschluesselt"
	return "System"


func is_secure(server_id: String) -> bool:
	return bool((_peers.get(server_id, {}) as Dictionary).get("secure", false))


## Vertrauensart bestimmen: eigene Datei schlaegt die globale Bequemlichkeit.
func _trust_for(url: String, ca_path: String) -> TlsTrust:
	if not url.begins_with("wss://"):
		return TlsTrust.SYSTEM
	if ca_path != "":
		return TlsTrust.PINNED
	if cfg != null and cfg.tls_allow_self_signed:
		return TlsTrust.UNSAFE
	return TlsTrust.SYSTEM


## TLSOptions passend zur Vertrauensart (null = Godot-Standard).
func _tls_options(trust: int, ca_path: String) -> TLSOptions:
	match trust:
		TlsTrust.PINNED:
			var ca := _load_ca(ca_path)
			if ca != null:
				return TLSOptions.client(ca)
			return null
		TlsTrust.UNSAFE:
			# Verschlüsselung ohne Identitaetspruefung - bewusst und sichtbar.
			return TLSOptions.client_unsafe()
	return null


## Zertifikat/CA aus einer PEM-Datei laden (einmalig, wird nicht gespeichert).
##
## Existenz und Groesse werden **vorher** geprueft: `X509Certificate.load`
## schreibt sonst eine schwer lesbare Engine-Fehlermeldung, obwohl ein
## falscher Pfad ein ganz normaler Benutzerfehler ist.
func _load_ca(path: String) -> X509Certificate:
	if path == "":
		return null
	if not FileAccess.file_exists(path):
		return null
	if FileAccess.get_file_as_bytes(path).is_empty():
		return null
	var cert := X509Certificate.new()
	if cert.load(path) != OK:
		return null
	return cert


## Fingerabdruck (SHA-256, hex) einer PEM-Datei - zum Vergleich mit dem
## Fingerabdruck, den die Worker-App anzeigt.
static func certificate_fingerprint(path: String) -> String:
	var pem := FileAccess.get_file_as_string(path)
	if pem == "":
		return ""
	var der := _pem_der(pem, "CERTIFICATE")
	if der.is_empty():
		return ""
	return _sha256_hex(der)


static func _pem_der(pem: String, label: String) -> PackedByteArray:
	var begin := "-----BEGIN %s-----" % label
	var finish := "-----END %s-----" % label
	var start := pem.find(begin)
	var stop := pem.find(finish)
	if start < 0 or stop < 0:
		return PackedByteArray()
	var body := pem.substr(start + begin.length(), stop - start - begin.length())
	body = body.replace("\r", "").replace("\n", "").replace(" ", "").replace("\t", "")
	return Marshalls.base64_to_raw(body)


## SHA-256 ueber Bytes. Godot bringt keinen freien Hash-Dienst mit, deshalb der
## Weg ueber einen kurzen Crypto-Zugriff pro Aufruf (nur bei Bedarf benutzt).
static func _sha256_hex(data: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(data) != OK:
		return ""
	return context.finish().hex_encode()


func remove_worker(server_id: String) -> bool:
	var entry: Dictionary = _peers.get(server_id, {})
	if entry.is_empty():
		return false
	var peer := entry.get("peer", null) as WebSocketPeer
	if peer != null:
		peer.close()
	_peers.erase(server_id)
	servers.mark_disconnected(server_id)
	return true


## Datei-Transfer anschliessen: ab jetzt laufen `file_begin/chunk/end` ueber
## diese Verbindung und eingehende `file_ack`/`file_have` hierher.
func set_file_transfer(transfer: OrchestratorFileTransfer) -> void:
	file_transfer = transfer
	if transfer != null:
		transfer.set_sender(Callable(self, "send_message"))


## Oeffentliche Sende-Funktion (fuer den Datei-Transfer).
func send_message(server_id: String, payload: Dictionary) -> bool:
	return _send(server_id, payload)


func worker_ids() -> Array[String]:
	var out: Array[String] = []
	for id in _peers.keys():
		out.append(str(id))
	return out


func has_worker(server_id: String) -> bool:
	return _peers.has(server_id)


func is_connected_to(server_id: String) -> bool:
	var entry: Dictionary = _peers.get(server_id, {})
	return bool(entry.get("connected", false))


## Gespeichertes Token eines Workers (fuer Persistenz im Dock).
func get_worker_token(server_id: String) -> String:
	var entry: Dictionary = _peers.get(server_id, {})
	return str(entry.get("token", ""))


func close_all() -> void:
	for server_id in _peers.keys().duplicate():
		var peer := (_peers[server_id] as Dictionary).get("peer", null) as WebSocketPeer
		if peer != null:
			peer.close()
	_peers.clear()


# ---------------------------------------------------------------- Poll
## Pro Frame aufrufen. Verbindet, liest Nachrichten, hält Latenz aktuell.
func poll() -> void:
	var now := Time.get_ticks_msec()
	for server_id in _peers.keys().duplicate():
		if not _peers.has(server_id):
			continue
		var entry: Dictionary = _peers[server_id]
		var peer := entry.get("peer", null) as WebSocketPeer
		if peer == null:
			continue
		if peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			if now >= int(entry.get("retry_at_ms", 0)):
				_start_reconnect(server_id, entry, now)
			continue
		peer.poll()
		match peer.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				if not bool(entry["connected"]):
					entry["connected"] = true
					entry["attempts"] = 0
					worker_connected.emit(server_id)
					entry["last_ping_ms"] = now
				if not bool(entry["authed"]):
					_send_auth(server_id, entry)
				_drain(server_id, peer)
				if now - int(entry["last_ping_ms"]) >= PING_INTERVAL_MS:
					entry["last_ping_ms"] = now
					_send(server_id, {"t": "ping", "ts": now})
			WebSocketPeer.STATE_CLOSED:
				_handle_disconnect(server_id, entry, peer, now)
func _handle_disconnect(server_id: String, entry: Dictionary, peer: WebSocketPeer, now_ms: int) -> void:
	var was_connected := bool(entry.get("connected", false))
	var reason := peer.get_close_reason()
	entry["connected"] = false
	entry["authed"] = false
	entry["attempts"] = int(entry.get("attempts", 0)) + 1
	entry["retry_at_ms"] = now_ms + _reconnect_delay(int(entry["attempts"]))
	if was_connected:
		servers.mark_disconnected(server_id, now_ms)
		worker_disconnected.emit(server_id, reason if reason != "" else "Verbindung geschlossen")
		return
	_explain_tls_failure(server_id, entry, reason)


## Ein gescheiterter Handshake darf nicht als "Worker offline" verschwinden.
## Typisch ist ein selbstsigniertes Zertifikat, das Godot korrekterweise
## ablehnt - der Benutzer braucht dann einen Satz, was zu tun ist.
func _explain_tls_failure(server_id: String, entry: Dictionary, reason: String) -> void:
	if bool(entry.get("tls_hint_sent", false)):
		return
	if not bool(entry.get("secure", false)):
		return
	if int(entry.get("trust", TlsTrust.SYSTEM)) != TlsTrust.SYSTEM:
		return
	entry["tls_hint_sent"] = true
	var hint := ("TLS-Handshake mit %s fehlgeschlagen. Bei einem selbstsignierten "
		% server_id) + ("Zertifikat: in den Cluster-Einstellungen \"Selbstsignierte " +
		"Zertifikate erlauben\" einschalten oder das Zertifikat des Workers " +
		"(worker-cert.pem) als Vertrauensdatei hinterlegen.")
	if reason != "":
		hint += " Meldung: %s" % reason
	push_warning("[Orchestrator] " + hint)
	tls_problem.emit(server_id, hint)


func _start_reconnect(server_id: String, entry: Dictionary, now_ms: int) -> void:
	var old_peer := entry.get("peer", null) as WebSocketPeer
	if old_peer != null:
		old_peer.close()
	var attempt := int(entry.get("attempts", 0))
	_entry_delay(entry, now_ms, attempt)
	var peer := WebSocketPeer.new()
	# Puffer erneut setzen: der neue Peer ist ein frisches Objekt.
	peer.inbound_buffer_size = MAX_WIRE_BYTES
	peer.outbound_buffer_size = MAX_WIRE_BYTES
	peer.max_queued_packets = MAX_QUEUED_PACKETS
	# TLS-Vertrauen muss beim Neuverbinden identisch bleiben - sonst wuerde ein
	# Reconnect unbemerkt anders (oder gar ungeprueft) aufbauen.
	var trust := int(entry.get("trust", TlsTrust.SYSTEM))
	var err := peer.connect_to_url(str(entry.get("url", "")),
		_tls_options(trust, str(entry.get("ca_path", ""))))
	if err != OK:
		return
	entry["peer"] = peer
	entry["connected"] = false
	entry["authed"] = false
	_log_reconnect(server_id, attempt)


## Wartezeit vor dem naechsten Versuch: waechst mit der Versuchszahl.
static func _reconnect_delay(attempts: int) -> int:
	var delay := RECONNECT_DELAY_MS * maxi(attempts, 1)
	return mini(delay, RECONNECT_MAX_DELAY_MS)


func _entry_delay(entry: Dictionary, now_ms: int, attempts: int) -> void:
	entry["retry_at_ms"] = now_ms + _reconnect_delay(attempts)


## Nur den ersten Versuch und danach jeden 8. melden: ein dauerhaft abwesender
## Rechner darf das Protokoll nicht zumuellen.
func _log_reconnect(server_id: String, attempt: int) -> void:
	if attempt <= 1 or attempt % 8 == 0:
		print("[Orchestrator] Verbinde erneut mit %s (Versuch %d)" % [server_id, attempt])


func _drain(server_id: String, peer: WebSocketPeer) -> void:
	var entry: Dictionary = _peers.get(server_id, {})
	while peer.get_available_packet_count() > 0:
		var text := peer.get_packet().get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(text)
		if not (parsed is Dictionary):
			continue
		var msg := parsed as Dictionary
		if not bool(entry.get("authed", false)):
			# Vor dem Auth-Handshake wird nur `hello` akzeptiert (Auth-Bestätigung
			# der Workerseite); alles andere wird verworfen – kein Datenleck.
			if str(msg.get("t", "")) == "hello" and str(msg.get("auth", "")) == "ok":
				entry["authed"] = true
				_on_hello(server_id, msg)
				_log_auth_ok(server_id)
			continue
		_handle(server_id, msg)


# ---------------------------------------------------------------- Nachrichten
func _handle(server_id: String, msg: Dictionary) -> void:
	var kind := str(msg.get("t", ""))
	match kind:
		"hello":
			_on_hello(server_id, msg)
		"heartbeat":
			servers.on_heartbeat(server_id, {
				"cpu": float(msg.get("cpu", 0.0)),
				"ram": float(msg.get("ram", 0.0)),
				"gpu": float(msg.get("gpu", -1.0)),
				"active_tasks": int(msg.get("active_tasks", 0)),
				"queue_used": int(msg.get("queue_used", 0)),
				"queue_capacity": int(msg.get("queue_capacity", DEFAULT_CAPACITY)),
			})
			# Aktive Tasks des Workers in die Kapazitätsrechnung übernehmen.
			var server := servers.get_server(server_id)
			if server != null:
				server.active_tasks = int(msg.get("active_tasks", 0))
		"pong":
			var stamp := int(msg.get("ts", 0))
			var server := servers.get_server(server_id)
			if stamp > 0 and server != null:
				server.latency_ms = float(maxi(Time.get_ticks_msec() - stamp, 0))
		"ack":
			dispatcher.on_ack(str(msg.get("task_id", "")), server_id, int(msg.get("attempt", -1)))
		"started":
			dispatcher.on_task_started(str(msg.get("task_id", "")), server_id, -1, int(msg.get("attempt", -1)))
		"progress":
			dispatcher.on_task_progress(str(msg.get("task_id", "")), server_id,
				str(msg.get("stage", "")), float(msg.get("fraction", 0.0)),
				str(msg.get("text", "")), int(msg.get("attempt", -1)))
		"result":
			var build: Dictionary = msg.get("build", {}) if msg.get("build") is Dictionary else {}
			dispatcher.on_task_result(str(msg.get("task_id", "")), server_id,
				bool(msg.get("ok", false)), msg.get("value"), str(msg.get("error", "")), -1,
				int(msg.get("attempt", -1)), str(msg.get("error_hint", "")), build)
		"cancel_ack":
			dispatcher.on_cancel_ack(str(msg.get("task_id", "")), server_id)
		"file_ack", "file_have":
			# Datei-Uebertragung (Phase 6-8) - nur, wenn sie angeschlossen ist.
			if file_transfer != null:
				file_transfer.on_message(server_id, msg)
	worker_message.emit(server_id, kind)


func _on_hello(server_id: String, msg: Dictionary) -> void:
	var server := servers.get_server(server_id)
	if server == null:
		return
	if msg.has("worker") and str(msg["worker"]) != "":
		server.name = str(msg["worker"])
	if msg.has("queue_capacity"):
		server.queue_capacity = maxi(int(msg["queue_capacity"]), 1)


# ---------------------------------------------------------------- Senden
func _send_auth(server_id: String, entry: Dictionary) -> void:
	var token := str(entry.get("token", ""))
	if token == "":
		# Ohne Token weiß der Worker, dass er sofort trennen muss (4401).
		_send(server_id, {"t": "hello_auth", "token": ""})
		return
	_send(server_id, {"t": "hello_auth", "token": token})


func _on_dispatch_payload_requested(_task_id: String, server_id: String, payload: Dictionary) -> void:
	if _peers.has(server_id):
		_send(server_id, payload)


func _on_cancel_requested(task_id: String, server_id: String, attempt: int) -> void:
	if _peers.has(server_id):
		# Versuchsnummer mitschicken: der Worker darf damit nur den passenden
		# (aelteren) Lauf beenden, nicht einen schon gestarteten neuen.
		_send(server_id, {"t": "cancel", "task_id": task_id, "attempt": attempt})


func _send(server_id: String, payload: Dictionary) -> bool:
	var entry: Dictionary = _peers.get(server_id, {})
	var peer := entry.get("peer", null) as WebSocketPeer
	if peer == null or peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	# Rueckgabewert pruefen: ein stilles Scheitern wuerde nur als ACK-Timeout
	# auffallen - der Benutzer haette dann keine Erklaerung.
	var err := peer.send_text(JSON.stringify(payload))
	if err != OK:
		send_failed.emit(server_id, "Senden fehlgeschlagen (Fehler %d, %d Bytes)" % [
			err, JSON.stringify(payload).length()])
		return false
	return true


# ---------------------------------------------------------------- Darstellung
func describe() -> Array:
	var out: Array = []
	for server_id in _peers.keys().duplicate():
		if not _peers.has(server_id):
			continue
		var entry: Dictionary = _peers[server_id]
		var peer := entry.get("peer", null) as WebSocketPeer
		out.append({
			"server_id": server_id,
			"url": entry.get("url", ""),
			"connected": bool(entry.get("connected", false)),
			"state": peer.get_ready_state() if peer != null else -1,
			"secure": bool(entry.get("secure", false)),
			"tls": tls_label(server_id),
			"ca_path": entry.get("ca_path", ""),
		})
	return out


# ---------------------------------------------------------------- Helfer
func _log_auth_ok(server_id: String) -> void:
	print("[Orchestrator] Worker %s authentifiziert." % server_id)


## Orchestrator-IDs landen als Godot-Node-Namen im Graph; NodePath-sonderzeichen
## und Steuerzeichen sind dort tabu.
static func _valid_id(id: String) -> bool:
	if id == "" or id.length() > 64:
		return false
	for ch in _INVALID_ID_CHARS:
		if id.contains(ch):
			return false
	return true


## Anzeigenamen auf druckbare, einzeilige Zeichen kürzen (Worker-Namen kommen
## aus dem Netz; sie landen in Labels und Logs).
static func _sanitize_name(name: String, fallback: String) -> String:
	var cleaned := name.strip_edges()
	var out := ""
	for i in cleaned.length():
		var ch := cleaned[i]
		if ch != "\n" and ch != "\r" and ch != "\t":
			out += ch
	out = out.strip_edges()
	if out.length() > 64:
		out = out.substr(0, 64)
	return out if out != "" else fallback


static func _host_of(url: String) -> String:
	var rest := url
	var scheme := rest.find("://")
	if scheme >= 0:
		rest = rest.substr(scheme + 3)
	var colon := rest.rfind(":")
	if colon > 0:
		return rest.substr(0, colon)
	return rest


static func _port_of(url: String) -> int:
	var rest := url
	var scheme := rest.find("://")
	if scheme >= 0:
		rest = rest.substr(scheme + 3)
	var colon := rest.rfind(":")
	if colon > 0:
		return int(rest.substr(colon + 1))
	return 0
