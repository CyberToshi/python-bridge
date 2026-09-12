class_name OrchestratorRouter
extends RefCounted
## Auswahl-/Schedulinglogik des Orchestrators (Phase 4).
##
## Der Router ist die **einzige** Stelle, die entscheidet, welcher Server einen
## Task bekommt (§4, §17). Er ist bewusst modular aufgebaut:
##
##   * Harte Kriterien (**Eignung**) sind von der Bewertung (**Score**) getrennt.
##   * Die Bewertung lässt sich über Hooks erweitern, ohne den Kern umzubauen
##     (`score_hook` für eigene Scheduling-Ideen, `file_locality` für die
##     Data-Locality aus Phase 6/7).
##
## Es gibt hier keine komplizierten Optimierungsalgorithmen: nur eine
## nachvollziehbare, gewichtete Heuristik ("robuster kleiner Kern").

signal routed(task_id: String, server_id: String)
signal unroutable(task_id: String, reason: String)

var cfg: OrchestratorConfig
var servers: OrchestratorServerManager

## Data-Locality-Hook (Phase 6/7): f(file_id: String, server_id: String) -> bool.
## Ist er gesetzt und liegen **alle** `required_files` eines Tasks bereits auf
## dem Server, bekommt dieser den Lokalitäts-Bonus. Fehlt der Hook, werden
## Dateien als übertragbar behandelt (siehe §17) – dann entscheidet nur die Last.
var file_locality: Callable = Callable()

## Optionaler Score-Hook: f(server, task, base_score: float) -> float.
## Erlaubt eigene Scheduling-Ideen, ohne diese Klasse zu ändern.
var score_hook: Callable = Callable()


func _init(p_servers: OrchestratorServerManager, p_config: OrchestratorConfig = null) -> void:
	servers = p_servers
	cfg = p_config if p_config != null else OrchestratorConfig.defaults()


# ---------------------------------------------------------------- Eignung
## Harte Kriterien: Nur ein Server mit offenem Capacity Gate, freien Slots,
## passendem Ziel-Pin und erfüllten Task-Anforderungen kommt infrage.
func is_eligible(server: OrchestratorServer, task: OrchestratorTask) -> bool:
	if server == null or task == null:
		return false
	if not server.accepts_new_tasks():
		return false
	if server.free_slots() <= 0:
		return false
	if task.target != "" and server.id != task.target:
		return false
	return _meets_requirements(server, task)


func _meets_requirements(server: OrchestratorServer, task: OrchestratorTask) -> bool:
	var req: Dictionary = task.requirements
	if req.is_empty():
		return true
	if req.has("gpu") and bool(req["gpu"]) and server.gpu_pct < 0.0:
		return false
	if req.has("min_free_ram_pct") and (100.0 - server.ram_pct) < float(req["min_free_ram_pct"]):
		return false
	if req.has("min_free_slots") and server.free_slots() < int(req["min_free_slots"]):
		return false
	if req.has("max_cpu_pct") and server.cpu_pct > float(req["max_cpu_pct"]):
		return false
	return true


## Ob der Server bereits alle benötigten Dateien eines Tasks besitzt.
func files_present(server: OrchestratorServer, task: OrchestratorTask) -> bool:
	if not file_locality.is_valid() or task.required_files.is_empty():
		return false
	for f in task.required_files:
		if not bool(file_locality.call(str(f), server.id)):
			return false
	return true


# ---------------------------------------------------------------- Bewertung
## Score eines Servers für einen Task. Höher ist besser.
##
## Gewichte und Strafen liegen in `OrchestratorConfig` und sind damit
## konfigurierbar statt hart verdrahtet.
func score(server: OrchestratorServer, task: OrchestratorTask) -> float:
	var s := 100.0
	s -= cfg.router_load_weight * server.load_factor()                 # Auslastung
	s -= cfg.router_latency_penalty_per_ms * server.latency_ms         # Latenz
	s += minf(float(server.free_slots()), 4.0) * 2.0                   # freie Plätze
	if server.state == OrchestratorServer.NodeState.READY:
		s += 10.0                                                      # READY vor LIMITED
	if files_present(server, task):
		s += cfg.router_locality_bonus                                 # Data Locality
	if score_hook.is_valid():
		s = float(score_hook.call(server, task, s))
	return s


## Alle geeigneten Server, bester zuerst. Jeder Eintrag ist ein Dictionary
## `{server_id, name, score, latency_ms, state}`.
##
## Sortierung ist deterministisch: Score absteigend, bei Gleichstand
## Server-ID aufsteigend (stabile Anzeige/Reproduzierbarkeit in Tests).
func rank(task: OrchestratorTask) -> Array:
	var scored: Array = []
	for server in servers.servers():
		var s := server as OrchestratorServer
		if not is_eligible(s, task):
			continue
		scored.append({
			"server_id": s.id,
			"name": s.name,
			"score": score(s, task),
			"latency_ms": s.latency_ms,
			"state": s.state,
		})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a["score"]) != float(b["score"]):
			return float(a["score"]) > float(b["score"])
		return str(a["server_id"]) < str(b["server_id"]))
	return scored


# ---------------------------------------------------------------- Auswahl
## Wählt den besten geeigneten Server. Liefert "" wenn keiner infrage kommt und
## meldet dann `unroutable` mit Begründung.
func select(task: OrchestratorTask) -> String:
	if task == null:
		return ""
	var candidates := rank(task)
	if candidates.is_empty():
		unroutable.emit(task.task_id, explain_no_route(task))
		return ""
	var chosen := str((candidates[0] as Dictionary)["server_id"])
	routed.emit(task.task_id, chosen)
	return chosen


## Menschlich lesbare Begründung, wenn kein Server geeignet ist.
func explain_no_route(task: OrchestratorTask) -> String:
	if servers.server_count() == 0:
		return "keine Server registriert"
	if task.target != "":
		var pinned := servers.get_server(task.target)
		if pinned == null:
			return "Zielserver '%s' unbekannt" % task.target
		if not pinned.accepts_new_tasks():
			return "Zielserver '%s' gesperrt (%s)" % [task.target, pinned.block_reason if pinned.block_reason != "" else pinned.state_text_now()]
	if servers.available_servers().is_empty():
		return "kein Server mit offenem Capacity Gate"
	return "kein Server erfüllt die Task-Anforderungen"


func describe_decision(task: OrchestratorTask) -> Dictionary:
	return {
		"task_id": task.task_id,
		"target": task.target,
		"candidates": rank(task),
		"reason": explain_no_route(task),
	}
