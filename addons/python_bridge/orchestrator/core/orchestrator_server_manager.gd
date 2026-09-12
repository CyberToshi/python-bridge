class_name OrchestratorServerManager
extends RefCounted
## Verwaltet alle verbundenen Worker-Rechner (Server Nodes, Phase 2).
##
## Registrierung, Heartbeat-Eingang und die automatische Zustandsbewertung
## (READY → UNRESPONSIVE → DISCONNECTED, inkl. Capacity Gate). Die Klasse ist
## transportunabhängig: sie bekommt Herzschläge von außen (on_heartbeat) und
## wird pro Frame getickt (tick). Welche Leitung die Herzschläge liefert,
## entscheidet die spätere Transport-Schicht – hier wird keine zweite
## Kommunikationswelt implementiert.

signal server_added(server_id: String)
signal server_removed(server_id: String)
signal server_state_changed(server_id: String, old_state: int, new_state: int)
signal heartbeat_received(server_id: String)

var cfg: OrchestratorConfig

var _servers: Dictionary = {}      # id -> OrchestratorServer
var _order: Array[String] = []     # Registrierungsreihenfolge (stabile Anzeige)


func _init(config: OrchestratorConfig = null) -> void:
	cfg = config if config != null else OrchestratorConfig.defaults()


# ---------------------------------------------------------------- Registrierung
func add_server(id: String, name := "", host := "", port := 0, queue_capacity := -1) -> OrchestratorServer:
	if id == "":
		return null
	if _servers.has(id):
		return _servers[id] as OrchestratorServer
	var capacity := queue_capacity if queue_capacity > 0 else cfg.queue_capacity
	var server := OrchestratorServer.new(id, name, host, port, capacity)
	_servers[id] = server
	_order.append(id)
	server_added.emit(id)
	return server


func remove_server(id: String) -> bool:
	if not _servers.has(id):
		return false
	_servers.erase(id)
	_order.erase(id)
	server_removed.emit(id)
	return true


func has_server(id: String) -> bool:
	return _servers.has(id)


func get_server(id: String) -> OrchestratorServer:
	return _servers.get(id, null) as OrchestratorServer


func server_count() -> int:
	return _servers.size()


func ids() -> Array[String]:
	return _order.duplicate()


## Alle Server in Registrierungsreihenfolge.
func servers() -> Array:
	var out: Array = []
	for id in _order:
		var s := get_server(id)
		if s != null:
			out.append(s)
	return out


# ---------------------------------------------------------------- Heartbeat / Tick
## Verarbeitet einen Heartbeat und bewertet den Server sofort neu.
## Liefert false, wenn der Server unbekannt ist.
func on_heartbeat(server_id: String, metrics: Dictionary, now_ms: int = -1) -> bool:
	var server := get_server(server_id)
	if server == null:
		return false
	var now := _now(now_ms)
	server.apply_heartbeat(metrics, now)
	_refresh(server, now)
	heartbeat_received.emit(server_id)
	return true


## Markiert einen Server als aktiv getrennt (Verbindungsabbruch).
func mark_disconnected(server_id: String, now_ms: int = -1) -> bool:
	var server := get_server(server_id)
	if server == null:
		return false
	var previous := server.state
	server.connection = "disconnected"
	server.evaluate_state(_now(now_ms), cfg)
	if server.state != previous:
		server_state_changed.emit(server_id, previous, server.state)
	return true


## Muss regelmäßig (pro Frame) aufgerufen werden: bewertet alle Server neu
## und meldet Zustandswechsel (Timeout-Erkennung).
func tick(now_ms: int = -1) -> void:
	var now := _now(now_ms)
	for id in _order:
		var server := get_server(id)
		if server != null:
			_refresh(server, now)


func _refresh(server: OrchestratorServer, now_ms: int) -> void:
	var previous := server.state
	var next := server.evaluate_state(now_ms, cfg)
	if next != previous:
		server_state_changed.emit(server.id, previous, next)


# ---------------------------------------------------------------- Abfragen
## Server, deren Gate offen ist (READY oder LIMITED mit freien Slots).
func available_servers() -> Array:
	var out: Array = []
	for server in servers():
		if (server as OrchestratorServer).accepts_new_tasks():
			out.append(server)
	return out


func ready_servers() -> Array:
	var out: Array = []
	for server in servers():
		if (server as OrchestratorServer).state == OrchestratorServer.NodeState.READY:
			out.append(server)
	return out


func count_in_state(state: int) -> int:
	var n := 0
	for server in servers():
		if (server as OrchestratorServer).state == state:
			n += 1
	return n


func describe_all() -> Array:
	var out: Array = []
	for server in servers():
		out.append((server as OrchestratorServer).describe())
	return out


func reset() -> void:
	_servers.clear()
	_order.clear()


static func _now(now_ms: int) -> int:
	return now_ms if now_ms >= 0 else Time.get_ticks_msec()
