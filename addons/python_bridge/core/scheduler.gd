class_name PythonBridgeScheduler
extends RefCounted
## Frame-synchronized dispatch and result delivery (mechanics).
##
## The scheduler is driven from the main thread once per frame (via
## PythonBridge.poll()). It performs the two halves of the sync contract:
##
##   1. Dispatch: up to `max_dispatch_per_frame` units are handed to ready
##      instances, respecting `max_inflight_per_instance` (one batch counts
##      as one unit). Nothing blocks; sending is fire-and-forget on the
##      WebSocket.
##
##   2. Delivery: incoming frames are buffered in a bounded inbox and up to
##      `max_results_per_frame` results are applied to tasks in the sync
##      point. A growing inbox throttles dispatch (backpressure), so results
##      are never dropped silently and the main loop never stalls.
##
## Late results (task already TIMEOUT/CANCELLED) are discarded by the task
## manager; the scheduler additionally sends best-effort CANCEL messages for
## timed-out running tasks.

var _cfg: Dictionary = {}
var _task_manager: PythonBridgeTaskManager = null
var _get_ready_instances: Callable = Callable()   # () -> Array of instances
var _get_instance: Callable = Callable()          # (instance_id) -> instance or null
var _send_message: Callable = Callable()          # (instance, msg) -> Error
var _on_event: Callable = Callable()              # (instance_id, event_msg) -> void

var _inbox: Array = []                            # [{instance_id, parsed}]
var _in_flight_units: Dictionary = {}             # instance -> Array of units
var _warned_inbox: bool = false
var _last_prune_ms: int = 0

func _init(cfg: Dictionary) -> void:
	_cfg = cfg

## Attaches dependencies. Called once by the facade after construction.
func setup(task_manager: PythonBridgeTaskManager, get_ready_instances: Callable, send_message: Callable, on_event: Callable = Callable(), get_instance: Callable = Callable()) -> void:
	_task_manager = task_manager
	_get_ready_instances = get_ready_instances
	_send_message = send_message
	_on_event = on_event
	_get_instance = get_instance

# ------------------------------------------------------------------ Frame
## Main per-frame entry point (sync point). Called from PythonBridge.poll().
func tick() -> void:
	var now := Time.get_ticks_msec()
	_task_manager.tick_windows(now)
	_dispatch(now)
	_process_inbox()
	_check_timeouts(now)

## Buffers a decoded frame arriving from an instance (called by the instance
## layer / connection manager, still on the main thread).
func on_message(instance_id: String, parsed: Dictionary) -> void:
	var msg: Dictionary = parsed.get("msg", {})
	var msg_type := str(msg.get("type", ""))
	match msg_type:
		PythonProtocol.MSG_TASK_RESULT, PythonProtocol.MSG_TASK_ERROR, PythonProtocol.MSG_BATCH_RESULT:
			_inbox.append({"instance_id": instance_id, "parsed": parsed})
		PythonProtocol.MSG_EVENT:
			if _on_event.is_valid():
				_on_event.call(instance_id, msg)
		PythonProtocol.MSG_STATUS:
			print("[Python][%s] status: %s" % [instance_id, JSON.stringify(msg)])
		PythonProtocol.MSG_PONG:
			pass # health monitor consumes pong timing; see health_monitor.gd
		_:
			print("[Python][%s] unhandled message type: %s" % [instance_id, msg_type])

## Fails all in-flight units of a dead instance (crash handling hook).
func on_instance_lost(instance_id: String, err: Dictionary) -> void:
	_task_manager.fail_in_flight(instance_id, err, Time.get_ticks_msec())
	_in_flight_units.erase(instance_id)



# ------------------------------------------------------------------ Dispatch
func _dispatch(now_ms: int) -> void:
	var max_per_frame := int(_cfg.get("max_dispatch_per_frame", 16))
	var dispatched := 0
	var instances: Array = _get_ready_instances.call()
	for instance in instances:
		if dispatched >= max_per_frame:
			return
		var instance_id: String = instance.instance_name
		if _in_flight_count(instance_id) >= int(_cfg.get("max_inflight_per_instance", 1)):
			continue
		if _inbox.size() >= int(_cfg.get("max_inbox_size", 512)):
			if not _warned_inbox:
				push_warning("[Python] Inbox full (%d) - throttling dispatch" % _inbox.size())
				_warned_inbox = true
			return
		_warned_inbox = false

		# Phase 3: Contexts, die gerade in einem Worker dieser Instanz laufen,
		# sind busy - gleiche Contexts werden nicht parallel dispatched.
		var busy: Array = _task_manager.running_contexts(instance_id)
		var unit: Dictionary = _task_manager.next_unit(instance_id, now_ms, busy)
		if unit.get("kind") == "wait" or unit.get("kind") == "none":
			continue
		_task_manager.mark_unit_running(instance_id, unit, now_ms)
		var err: Error = _send_message.call(instance, unit["msg"])
		if err != OK:
			var fail_err := PythonBridgeErrorHandler.make(
				PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR,
				"Send failed on %s: %s" % [instance_id, err], "", instance_id)
			var tasks: Array = []
			if unit.get("kind") == "single":
				tasks.append(unit["task"])
			elif unit.get("kind") == "batch":
				tasks = unit.get("tasks", [])
			_task_manager.fail_tasks(tasks, instance_id, fail_err, now_ms)
			continue
		_record_unit(instance_id, unit)
		dispatched += 1

func _record_unit(instance_id: String, unit: Dictionary) -> void:
	var task_ids: Array = []
	if unit.get("kind") == "single":
		task_ids.append((unit["task"] as PythonBridgeTask).id)
	elif unit.get("kind") == "batch":
		for t in unit.get("tasks", []):
			task_ids.append((t as PythonBridgeTask).id)
	if task_ids.is_empty():
		return
	var msg: Dictionary = unit.get("msg", {})
	var entry := {"msg_id": str(msg.get("id", "")), "task_ids": task_ids}
	var units: Array = _in_flight_units.get(instance_id, [])
	units.append(entry)
	_in_flight_units[instance_id] = units

func _in_flight_count(instance_id: String) -> int:
	return (_in_flight_units.get(instance_id, []) as Array).size()

## Removes units whose tasks are all terminal; called after each inbox batch.
func _prune_units() -> void:
	for instance_id in _in_flight_units.keys():
		var units: Array = _in_flight_units[instance_id]
		for i in range(units.size() - 1, -1, -1):
			var unit: Dictionary = units[i]
			var all_done := true
			for tid in unit.get("task_ids", []):
				var task := _task_manager.get_task(tid)
				# A missing task counts as done (it was pruned after finishing).
				if task != null and not task.is_terminal():
					all_done = false
					break
			if all_done:
				units.remove_at(i)
		if units.is_empty():
			_in_flight_units.erase(instance_id)

# ------------------------------------------------------------------ Inbox
func _process_inbox() -> void:
	var budget := int(_cfg.get("max_results_per_frame", 64))
	var processed := 0
	while not _inbox.is_empty() and processed < budget:
		var entry: Dictionary = _inbox.pop_front()
		_task_manager.resolve_result(entry["instance_id"], entry["parsed"])
		processed += 1
	if processed > 0:
		_prune_units()

# ------------------------------------------------------------------ Timeouts
func _check_timeouts(now_ms: int) -> void:
	# Low-cadence registry cleanup (memory hygiene, no leaks from old tasks).
	if now_ms - _last_prune_ms > 10000:
		_last_prune_ms = now_ms
		_task_manager.prune_terminal(now_ms)
	var timed_out: Array = _task_manager.check_timeouts(now_ms)
	for task_id in timed_out:
		var task := _task_manager.get_task(task_id)
		if task == null:
			continue
		var cancel_msg := {
			"v": PythonProtocol.PROTOCOL_VERSION,
			"type": PythonProtocol.MSG_CANCEL,
			"id": "cancel-" + task_id,
			"target_id": task_id,
		}
		var instance = null
		if _get_instance.is_valid() and task.instance_id != "":
			instance = _get_instance.call(task.instance_id)
		elif _get_instance.is_valid():
			# Auto-assigned task: the owning instance is the one running it.
			for candidate in _get_ready_instances.call():
				if candidate.instance_name == task.instance_id:
					instance = candidate
					break
		if instance != null:
			_send_message.call(instance, cancel_msg)

# ------------------------------------------------------------------ State
func pending_dispatch_count() -> int:
	return _inbox.size()

func in_flight_count(instance_id: String) -> int:
	return _in_flight_count(instance_id)