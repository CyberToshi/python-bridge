class_name OrchestratorConfig
extends RefCounted
## Konfiguration des visuellen Task-Orchestrators.
##
## Alle Grenzwerte sind konfigurierbar und liegen gesammelt hier – nichts ist
## in den Modellen hart verdrahtet. Der Orchestrator selbst führt **keinen**
## Python-Code aus und implementiert keine zweite Kommunikationswelt; er
## entscheidet nur, WO eine bestehende Python-Aufgabe ausgeführt wird und ob
## die nötigen Daten vorliegen.

# --- Heartbeat / Erreichbarkeit (Phase 2) ---------------------------------
const DEFAULT_HEARTBEAT_INTERVAL_MS := 2000
const DEFAULT_UNRESPONSIVE_MS := 6000
const DEFAULT_DISCONNECTED_MS := 20000

# --- Kapazität / Capacity Gate (Phase 4, hier schon konfiguriert) ----------
const DEFAULT_QUEUE_CAPACITY := 8
const DEFAULT_CPU_BLOCK_PCT := 85.0
const DEFAULT_CPU_READY_PCT := 70.0
const DEFAULT_RAM_BLOCK_PCT := 90.0
const DEFAULT_RAM_READY_PCT := 75.0

# --- Tasks / Retry (Phase 3) ----------------------------------------------
const DEFAULT_TASK_TIMEOUT_MS := 120000
const DEFAULT_MAX_RETRIES := 2
const DEFAULT_RETRY_DELAY_MS := 500

# --- Routing / Scheduling (Phase 4) ---------------------------------------
const DEFAULT_ROUTER_LOCALITY_BONUS := 60.0
const DEFAULT_ROUTER_LATENCY_PENALTY_PER_MS := 0.5
const DEFAULT_ROUTER_LOAD_WEIGHT := 1.0

# --- Assignment / ACK (Phase 5) -------------------------------------------
const DEFAULT_ACK_TIMEOUT_MS := 10000
const DEFAULT_MAX_DISPATCH_PER_TICK := 8

# --- Nutzlast (Projekt-/Code-Uebertragung) --------------------------------
## Obergrenze fuer einen Auftrag auf der Leitung. Groessere Projekte werden
## klar abgelehnt statt still zu scheitern (Datei-Transfer folgt spaeter).
const DEFAULT_MAX_PAYLOAD_BYTES := 3 * 1024 * 1024

var heartbeat_interval_ms: int = DEFAULT_HEARTBEAT_INTERVAL_MS
var unresponsive_ms: int = DEFAULT_UNRESPONSIVE_MS
var disconnected_ms: int = DEFAULT_DISCONNECTED_MS

var queue_capacity: int = DEFAULT_QUEUE_CAPACITY
var cpu_block_pct: float = DEFAULT_CPU_BLOCK_PCT
var cpu_ready_pct: float = DEFAULT_CPU_READY_PCT
var ram_block_pct: float = DEFAULT_RAM_BLOCK_PCT
var ram_ready_pct: float = DEFAULT_RAM_READY_PCT

var task_timeout_ms: int = DEFAULT_TASK_TIMEOUT_MS
var max_retries: int = DEFAULT_MAX_RETRIES
var retry_delay_ms: int = DEFAULT_RETRY_DELAY_MS

# Routing-Gewichte (modular, damit die Scheduling-Logik ohne Umbau anpassbar ist).
var router_locality_bonus: float = DEFAULT_ROUTER_LOCALITY_BONUS
var router_latency_penalty_per_ms: float = DEFAULT_ROUTER_LATENCY_PENALTY_PER_MS
var router_load_weight: float = DEFAULT_ROUTER_LOAD_WEIGHT

var ack_timeout_ms: int = DEFAULT_ACK_TIMEOUT_MS
var max_dispatch_per_tick: int = DEFAULT_MAX_DISPATCH_PER_TICK
var max_payload_bytes: int = DEFAULT_MAX_PAYLOAD_BYTES

# --- Sicherheit / Transport -----------------------------------------------
## Shared Secret zwischen Controller und Workern (Pflicht auf Workerseite).
## Bewusst NICHT in describe(): das ist ein Geheimnis, kein Anzeigewert.
var worker_token: String = ""

## TLS (wss://). Zwei ehrliche Betriebsarten, siehe OrchestratorTransport:
##
##   tls_ca_path            Zertifikat/CA-Datei (PEM) des Workers -> echte
##                          Pruefung. Hat Vorrang vor der Bequemlichkeit.
##   tls_allow_self_signed  Selbstsignierte Zertifikate bewusst akzeptieren ->
##                          verschluesselt, aber ohne Identitaetspruefung.
##
## Beides standardmaessig AUS: ohne TLS-Einstellung laeuft alles wie bisher
## unverschluesselt (ws://), und ein wss:// ohne Vertrauen scheitert sichtbar.
var tls_ca_path: String = ""
var tls_allow_self_signed: bool = false

## Standard-Konfiguration.
static func defaults() -> OrchestratorConfig:
	return OrchestratorConfig.new()


## Erzeugt eine Konfiguration aus Defaults + Overrides. Unbekannte Schlüssel
## werden ignoriert (vorwärtskompatibel), Typen werden erzwungen.
static func from_dict(cfg: Dictionary) -> OrchestratorConfig:
	var c := OrchestratorConfig.new()
	c.apply_dict(cfg)
	return c


## Mergt die angegebenen Werte über die aktuellen und normalisiert sie.
func apply_dict(cfg: Dictionary) -> void:
	heartbeat_interval_ms = _as_int(cfg, "heartbeat_interval_ms", heartbeat_interval_ms)
	unresponsive_ms = _as_int(cfg, "unresponsive_ms", unresponsive_ms)
	disconnected_ms = _as_int(cfg, "disconnected_ms", disconnected_ms)
	queue_capacity = _as_int(cfg, "queue_capacity", queue_capacity)
	cpu_block_pct = _as_float(cfg, "cpu_block_pct", cpu_block_pct)
	cpu_ready_pct = _as_float(cfg, "cpu_ready_pct", cpu_ready_pct)
	ram_block_pct = _as_float(cfg, "ram_block_pct", ram_block_pct)
	ram_ready_pct = _as_float(cfg, "ram_ready_pct", ram_ready_pct)
	task_timeout_ms = _as_int(cfg, "task_timeout_ms", task_timeout_ms)
	max_retries = _as_int(cfg, "max_retries", max_retries)
	retry_delay_ms = _as_int(cfg, "retry_delay_ms", retry_delay_ms)
	router_locality_bonus = _as_float(cfg, "router_locality_bonus", router_locality_bonus)
	router_latency_penalty_per_ms = _as_float(cfg, "router_latency_penalty_per_ms", router_latency_penalty_per_ms)
	router_load_weight = _as_float(cfg, "router_load_weight", router_load_weight)
	ack_timeout_ms = _as_int(cfg, "ack_timeout_ms", ack_timeout_ms)
	max_dispatch_per_tick = _as_int(cfg, "max_dispatch_per_tick", max_dispatch_per_tick)
	max_payload_bytes = _as_int(cfg, "max_payload_bytes", max_payload_bytes)
	worker_token = str(cfg.get("worker_token", worker_token)).strip_edges()
	tls_ca_path = str(cfg.get("tls_ca_path", tls_ca_path)).strip_edges()
	tls_allow_self_signed = bool(cfg.get("tls_allow_self_signed", tls_allow_self_signed))
	normalize()


## Erzwingt sinnvolle Wertebereiche (u. a. unresponsive < disconnected).
func normalize() -> void:
	heartbeat_interval_ms = maxi(heartbeat_interval_ms, 100)
	unresponsive_ms = maxi(unresponsive_ms, heartbeat_interval_ms)
	disconnected_ms = maxi(disconnected_ms, unresponsive_ms + 1)
	queue_capacity = maxi(queue_capacity, 1)
	task_timeout_ms = maxi(task_timeout_ms, 1)
	max_retries = maxi(max_retries, 0)
	retry_delay_ms = maxi(retry_delay_ms, 0)
	ack_timeout_ms = maxi(ack_timeout_ms, 100)
	max_dispatch_per_tick = maxi(max_dispatch_per_tick, 1)
	max_payload_bytes = maxi(max_payload_bytes, 65536)
	# READY-Schwelle muss unter der BLOCK-Schwelle liegen, sonst gibt es keine
	# Hysterese.
	cpu_ready_pct = clampf(cpu_ready_pct, 0.0, 100.0)
	cpu_block_pct = clampf(maxf(cpu_block_pct, cpu_ready_pct), 0.0, 100.0)
	ram_ready_pct = clampf(ram_ready_pct, 0.0, 100.0)
	ram_block_pct = clampf(maxf(ram_block_pct, ram_ready_pct), 0.0, 100.0)


func describe() -> Dictionary:
	return {
		"heartbeat_interval_ms": heartbeat_interval_ms,
		"unresponsive_ms": unresponsive_ms,
		"disconnected_ms": disconnected_ms,
		"queue_capacity": queue_capacity,
		"cpu_block_pct": cpu_block_pct,
		"cpu_ready_pct": cpu_ready_pct,
		"ram_block_pct": ram_block_pct,
		"ram_ready_pct": ram_ready_pct,
		"task_timeout_ms": task_timeout_ms,
		"max_retries": max_retries,
		"retry_delay_ms": retry_delay_ms,
		"router_locality_bonus": router_locality_bonus,
		"router_latency_penalty_per_ms": router_latency_penalty_per_ms,
		"router_load_weight": router_load_weight,
		"ack_timeout_ms": ack_timeout_ms,
		"max_dispatch_per_tick": max_dispatch_per_tick,
		"max_payload_bytes": max_payload_bytes,
		"tls_ca_path": tls_ca_path,
		"tls_allow_self_signed": tls_allow_self_signed,
	}


static func _as_int(cfg: Dictionary, key: String, fallback: int) -> int:
	if cfg.has(key):
		return int(cfg[key])
	return fallback


static func _as_float(cfg: Dictionary, key: String, fallback: float) -> float:
	if cfg.has(key):
		return float(cfg[key])
	return fallback
