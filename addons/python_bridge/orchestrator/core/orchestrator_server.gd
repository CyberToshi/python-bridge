class_name OrchestratorServer
extends RefCounted
## Ein verbundener Worker-Rechner (Server Node, Phase 2).
##
## Reines Datenmodell: Verbindung, Ressourcen-Metriken, Queue-Auslastung und
## der daraus abgeleitete Zustand. Die Zustandsübergänge inkl. Hysterese des
## Capacity Gate liegen hier; das Timeout-/Heartbeat-Timing steuert der
## OrchestratorServerManager.

enum NodeState { DISCONNECTED, UNRESPONSIVE, READY, LIMITED, BLOCKED }

var id: String = ""
var name: String = ""
var host: String = ""
var port: int = 0

## "disconnected" | "connecting" | "connected"
var connection: String = "disconnected"

# --- Live-Metriken (aus dem Heartbeat) ------------------------------------
var cpu_pct: float = 0.0
var ram_pct: float = 0.0
var gpu_pct: float = -1.0          # -1 = unbekannt/keine GPU
var network_mbps: float = 0.0
var latency_ms: float = 0.0
var active_tasks: int = 0
var queue_used: int = 0
var queue_capacity: int = 8
## Vom Orchestrator reservierte, noch nicht abgeschlossene Tasks. Verhindert,
## dass zwischen zwei Heartbeats über die Kapazität hinaus zugewiesen wird (§5).
var reserved: int = 0

var last_heartbeat_ms: int = 0
var state: int = NodeState.DISCONNECTED
var block_reason: String = ""


func _init(p_id: String = "", p_name: String = "", p_host: String = "", p_port: int = 0, p_queue_capacity: int = 8) -> void:
	id = p_id
	name = p_name if p_name != "" else p_id
	host = p_host
	port = p_port
	queue_capacity = maxi(p_queue_capacity, 1)


# ---------------------------------------------------------------- Zustand
## Ob eine aktive Verbindung zum Worker besteht.
## (Nicht `is_connected()` nennen – das kollidiert mit Object.is_connected.)
func is_link_open() -> bool:
	return connection == "connected"


## Wirksame Queue-Belegung: das Maximum aus dem, was der Worker meldet, und
## dem, was der Orchestrator bereits reserviert hat.
func effective_queue_used() -> int:
	return maxi(queue_used, reserved)


## Ob der Server aktuell neue Tasks annehmen darf (Gate offen).
func accepts_new_tasks() -> bool:
	return (state == NodeState.READY or state == NodeState.LIMITED) \
		and effective_queue_used() < queue_capacity


func free_slots() -> int:
	return maxi(queue_capacity - effective_queue_used(), 0)


func load_factor() -> float:
	# Grobe Auslastung für die Scheduling-Entscheidung (Phase 4). Reservierte
	# Tasks zählen dabei wie belegte Plätze.
	var queue_ratio := float(effective_queue_used()) / float(maxi(queue_capacity, 1))
	return maxf(cpu_pct, maxf(ram_pct, queue_ratio * 100.0))


## Wendet einen Heartbeat an (Metriken + Zeitstempel). Der Zustand wird
## anschließend über evaluate_state() neu berechnet.
func apply_heartbeat(metrics: Dictionary, now_ms: int) -> void:
	connection = "connected"
	last_heartbeat_ms = now_ms
	cpu_pct = clampf(float(metrics.get("cpu", cpu_pct)), 0.0, 100.0)
	ram_pct = clampf(float(metrics.get("ram", ram_pct)), 0.0, 100.0)
	gpu_pct = float(metrics.get("gpu", gpu_pct))
	network_mbps = maxf(float(metrics.get("network", network_mbps)), 0.0)
	latency_ms = maxf(float(metrics.get("latency", latency_ms)), 0.0)
	active_tasks = maxi(int(metrics.get("active_tasks", active_tasks)), 0)
	queue_used = maxi(int(metrics.get("queue_used", queue_used)), 0)
	if metrics.has("queue_capacity"):
		queue_capacity = maxi(int(metrics["queue_capacity"]), 1)


## Berechnet den Zielzustand aus Verbindung, Heartbeat-Alter und Metriken.
## Liefert den neuen Zustand und aktualisiert `state`/`block_reason`.
func evaluate_state(now_ms: int, cfg: OrchestratorConfig) -> int:
	state = _evaluate(now_ms, cfg)
	return state


func _evaluate(now_ms: int, cfg: OrchestratorConfig) -> int:
	if connection != "connected":
		block_reason = "nicht verbunden"
		return NodeState.DISCONNECTED
	if last_heartbeat_ms <= 0:
		block_reason = "noch kein Heartbeat"
		return NodeState.DISCONNECTED

	var age := now_ms - last_heartbeat_ms
	if age > cfg.disconnected_ms:
		block_reason = "Heartbeat verloren (> %d ms)" % cfg.disconnected_ms
		return NodeState.DISCONNECTED
	if age > cfg.unresponsive_ms:
		block_reason = "kein Heartbeat seit %d ms" % age
		return NodeState.UNRESPONSIVE

	return _gate_state(cfg)


## Capacity Gate mit Hysterese:
##   * BLOCK, sobald CPU/RAM die Block-Schwelle erreichen oder die Queue voll ist.
##   * Freigabe aus BLOCK erst, wenn wieder **unter** den READY-Schwellen –
##     verhindert Flattern zwischen READY und BLOCK.
##   * Zwischen READY- und BLOCK-Schwelle: LIMITED (nimmt noch an, aber knapp).
func _gate_state(cfg: OrchestratorConfig) -> int:
	var queue_full := effective_queue_used() >= queue_capacity
	var over_block := cpu_pct >= cfg.cpu_block_pct or ram_pct >= cfg.ram_block_pct

	if state == NodeState.BLOCKED:
		if cpu_pct <= cfg.cpu_ready_pct and ram_pct <= cfg.ram_ready_pct and not queue_full:
			block_reason = ""
			return NodeState.READY
		block_reason = _block_reason(cfg, queue_full)
		return NodeState.BLOCKED

	if over_block or queue_full:
		block_reason = _block_reason(cfg, queue_full)
		return NodeState.BLOCKED

	block_reason = ""
	if cpu_pct >= cfg.cpu_ready_pct or ram_pct >= cfg.ram_ready_pct:
		return NodeState.LIMITED
	return NodeState.READY


func _block_reason(cfg: OrchestratorConfig, queue_full: bool) -> String:
	if queue_full:
		return "Queue voll (%d/%d)" % [effective_queue_used(), queue_capacity]
	if cpu_pct >= cfg.cpu_block_pct:
		return "CPU %.0f%% >= %.0f%%" % [cpu_pct, cfg.cpu_block_pct]
	if ram_pct >= cfg.ram_block_pct:
		return "RAM %.0f%% >= %.0f%%" % [ram_pct, cfg.ram_block_pct]
	return "Capacity Gate"


# ---------------------------------------------------------------- Darstellung
static func state_text(s: int) -> String:
	match s:
		NodeState.DISCONNECTED:
			return "DISCONNECTED"
		NodeState.UNRESPONSIVE:
			return "UNRESPONSIVE"
		NodeState.READY:
			return "READY"
		NodeState.LIMITED:
			return "LIMITED"
		NodeState.BLOCKED:
			return "BLOCKED"
	return "UNKNOWN"


static func state_icon(s: int) -> String:
	match s:
		NodeState.READY:
			return "🟢"
		NodeState.LIMITED:
			return "🟡"
		NodeState.BLOCKED:
			return "🔴"
		NodeState.UNRESPONSIVE:
			return "🟠"
		NodeState.DISCONNECTED:
			return "❌"
	return "❔"


func state_text_now() -> String:
	return state_text(state)


func describe() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"host": host,
		"port": port,
		"connection": connection,
		"cpu": cpu_pct,
		"ram": ram_pct,
		"gpu": gpu_pct,
		"network": network_mbps,
		"latency": latency_ms,
		"active_tasks": active_tasks,
		"queue_used": queue_used,
		"queue_reserved": reserved,
		"queue_effective": effective_queue_used(),
		"queue_capacity": queue_capacity,
		"state": state_text(state),
		"block_reason": block_reason,
		"last_heartbeat_ms": last_heartbeat_ms,
	}
