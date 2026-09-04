class_name PythonBridgeTaskManager
extends RefCounted
## Central task queue with priority, backpressure, cancellation, retry and
## the batching window policy.
##
## Responsibilities (policy) - the scheduler owns the frame mechanics:
##   - submit: backpressure checks (max_queued_tasks, max_payload_bytes)
##   - priority ordered queue (lower priority value = higher priority)
##   - cancel: queued tasks are removed immediately; running tasks are marked
##     and their (possibly late) result is discarded
##   - retry: connection/process errors can requeue a task (configurable)
##   - batching: when >= 2 compatible batchable tasks target the same
##     instance, a window of max_batch_delay_ms is opened; the window closes
##     early when it reaches max_batch_size or a higher-priority task appears
##   - instance targeting: tasks with explicit instance_id go there, empty
##     instance_id means "any ready instance" (assigned at dispatch time)
##
## All state is touched only from the main thread (poll model), so no locks
## are needed. Tasks are resolved exclusively through `resolve_result()` /
## `check_timeouts()` / `fail_in_flight()`; the `done` signal fires exactly
## once per terminal task.

var _cfg: Dictionary = {}
var _queue: Array[PythonBridgeTask] = []     # QUEUED tasks, sorted by (priority, seq)
var _by_id: Dictionary = {}                  # task_id -> PythonBridgeTask
var _seq: int = 0
var _batch_seq: int = 0
var _batch_windows: Dictionary = {}          # instance_id -> {priority, start_ms, tasks, msg_id}

func _init(cfg: Dictionary) -> void:
	_cfg = cfg

# ------------------------------------------------------------------ Submit
## Queues a task or rejects it (backpressure). Returns an ok result when the
## task was accepted; the task's `done` signal carries the final result.
func submit(task: PythonBridgeTask, now_ms: int) -> PythonBridgeResult:
	if task.id == "" or _by_id.has(task.id):
		return PythonBridgeResult.failed_with_error(
			PythonBridgeErrorHandler.make(
				PythonBridgeErrorHandler.CATEGORY_TASK_ERROR,
				"Duplicate or empty task id: '%s'" % task.id, task.id))
	if task.is_terminal():
		return PythonBridgeResult.failed_with_error(
			PythonBridgeErrorHandler.make(
				PythonBridgeErrorHandler.CATEGORY_TASK_ERROR,
				"Task is already terminal (%s)" % task.state_text(), task.id))
	if pending_count() >= int(_cfg.get("max_queued_tasks", 1000)):
		return PythonBridgeResult.failed_with_error(
			PythonBridgeErrorHandler.make(
				PythonBridgeErrorHandler.CATEGORY_TASK_ERROR,
				"Task queue full (%d queued)" % pending_count(), task.id))
	var payload := _estimate_payload_bytes(task)
	var max_payload := int(_cfg.get("max_payload_bytes", 64 * 1024 * 1024))
	if payload > max_payload:
		return PythonBridgeResult.failed_with_error(
			PythonBridgeErrorHandler.make(
				PythonBridgeErrorHandler.CATEGORY_TASK_ERROR,
				"Task payload too large (%d bytes > %d)" % [payload, max_payload],
				task.id))
	task.created_at_ms = now_ms
	task.max_retries = int(_cfg.get("max_retries", 0))
	task.retries_left = task.max_retries
	task.retry_policy = str(_cfg.get("retry_policy", "connection_error"))
	_seq += 1
	task._seq = _seq
	task.state = PythonBridgeTask.State.QUEUED
	_by_id[task.id] = task
	_insert_sorted(task)
	return PythonBridgeResult.success({"task_id": task.id})

# ------------------------------------------------------------------ Query
func get_task(task_id: String) -> PythonBridgeTask:
	return _by_id.get(task_id, null) as PythonBridgeTask

## Queued tasks in the priority queue plus tasks held in open batch windows.
func pending_count() -> int:
	var count := _queue.size()
	for window in _batch_windows.values():
		count += (window["tasks"] as Array).size()
	return count

func running_count() -> int:
	var count := 0
	for t in _by_id.values():
		if (t as PythonBridgeTask).state == PythonBridgeTask.State.RUNNING:
			count += 1
	return count

# ------------------------------------------------------------------ Cancel
## Cancels a task. Returns true when the task existed and was not terminal.
## Queued tasks (including window members) become CANCELLED immediately;
## running tasks are marked and complete as CANCELLED when their result
## arrives (late results are discarded).
func cancel(task_id: String) -> bool:
	var task := get_task(task_id)
	if task == null or task.is_terminal():
		return false
	if task.state == PythonBridgeTask.State.QUEUED:
		_queue.erase(task)
		_finish(task, PythonBridgeResult.cancelled(task.id))
	else:
		task.cancel_requested = true
	return true

# ------------------------------------------------------------------ Dispatch
## Computes the next dispatch unit for `instance_id`.
## Returns a Dictionary:
##   {"kind": "none"}                               - nothing queued
##   {"kind": "wait"}                               - batch window open
##   {"kind": "single", "task": Task, "msg": Dict}  - one task message
##   {"kind": "batch", "tasks": Array, "msg": Dict} - batch message
##
## Respects retry delays (_next_attempt_ms in the future keeps the task
## queued). Tasks match the instance when their instance_id equals it or is
## empty (auto).
func next_unit(instance_id: String, now_ms: int) -> Dictionary:
	# 1) Open window: flush on preemption, size or delay; otherwise wait.
	if _batch_windows.has(instance_id):
		var window: Dictionary = _batch_windows[instance_id]
		var front := _peek_front_for(instance_id)
		if front != null and front.priority < int(window["priority"]):
			return _flush_window(instance_id)
		if (window["tasks"] as Array).size() >= int(_cfg.get("max_batch_size", 32)) \
				or now_ms - int(window["start_ms"]) >= int(_cfg.get("max_batch_delay_ms", 32)):
			return _flush_window(instance_id)
		return {"kind": "wait"}

	# 2) No window: collect compatible batchable candidates at the queue front.
	var candidates := _peek_batch_candidates(instance_id)
	var max_size := int(_cfg.get("max_batch_size", 32))
	if candidates.size() >= 2:
		if candidates.size() >= max_size:
			return _build_batch(candidates, instance_id)
		# Open a window; the candidates are owned by the window now.
		var first: PythonBridgeTask = candidates[0]
		_batch_windows[instance_id] = {
			"priority": first.priority,
			"start_ms": now_ms,
			"tasks": candidates,
			"msg_id": "batch-%d" % _batch_seq,
		}
		_batch_seq += 1
		for t in candidates:
			_queue.erase(t)
		return {"kind": "wait"}

	# 3) A single task dispatches immediately (never waits for a batch).
	var task := _pop_front_for(instance_id)
	if task == null:
		return {"kind": "none"}
	return {"kind": "single", "task": task, "msg": _build_task_msg(task)}

## Called by the scheduler once per frame: lets queued compatible tasks join
## open batch windows (up to max_batch_size). Flushing is decided in
## next_unit() so the returned unit can actually be sent.
func tick_windows(_now_ms: int) -> void:
	for instance_id in _batch_windows.keys():
		var window: Dictionary = _batch_windows[instance_id]
		var tasks: Array = window["tasks"]
		var max_size := int(_cfg.get("max_batch_size", 32))
		var win_priority: int = window["priority"]
		# Collect matches in queue order, then remove them (removal while
		# iterating forward would skip elements).
		var joined: Array = []
		for task in _queue:
			if tasks.size() + joined.size() >= max_size:
				break
			if task.priority != win_priority:
				continue
			if not task.batchable or task._next_attempt_ms > 0:
				continue
			if not _targets(task, instance_id):
				continue
			joined.append(task)
		for task in joined:
			_queue.erase(task)
		for task in joined:
			tasks.append(task)

## Called by the scheduler every frame to check timeouts. Returns the list of
## task ids that timed out while RUNNING so the scheduler can send
## best-effort CANCEL messages.
func check_timeouts(now_ms: int) -> Array:
	var timed_out: Array = []
	for t in _by_id.values():
		var task := t as PythonBridgeTask
		if task.is_terminal():
			continue
		if task.timeout_ms > 0 and now_ms - task.created_at_ms > task.timeout_ms:
			if task.state == PythonBridgeTask.State.RUNNING:
				timed_out.append(task.id)
			else:
				# Queued task timed out: drop it from the queue as well.
				_queue.erase(task)
			_finish(task, PythonBridgeResult.failed_with_error(
				PythonBridgeErrorHandler.make(
					PythonBridgeErrorHandler.CATEGORY_TIMEOUT_ERROR,
					"Task timeout after %d ms" % task.timeout_ms, task.id), task.id))
	return timed_out

## Called by the scheduler when a frame arrives from an instance.
## `parsed` is the result of PythonProtocol.parse_frame().
func resolve_result(_instance_id: String, parsed: Dictionary) -> void:
	var msg: Dictionary = parsed.get("msg", {})
	var msg_type := str(msg.get("type", ""))
	if msg_type == PythonProtocol.MSG_TASK_RESULT or msg_type == PythonProtocol.MSG_TASK_ERROR:
		_resolve_single(str(msg.get("id", "")), msg)
	elif msg_type == PythonProtocol.MSG_BATCH_RESULT:
		var items: Array = msg.get(PythonProtocol.FIELD_ITEMS, [])
		for item in items:
			if item is Dictionary:
				_resolve_single(str(item.get("id", "")), item)

func _resolve_single(task_id: String, msg: Dictionary) -> void:
	var task := get_task(task_id)
	if task == null or task.is_terminal():
		return # late / already resolved result
	var status := str(msg.get("status", "error"))
	var data: Variant = msg.get("data", null)
	if status == "ok":
		if task.cancel_requested:
			_finish(task, PythonBridgeResult.cancelled(task.id))
		else:
			_finish(task, PythonBridgeResult.success(data, {
				"duration_ms": float(msg.get("ms", 0)),
				"request_id": task_id,
				"instance_id": task.instance_id,
			}))
		return
	var err: Dictionary = msg.get("error", {}) if msg.get("error") is Dictionary else {}
	err = PythonBridgeErrorHandler.normalize(err, task_id, task.instance_id)
	if task.cancel_requested:
		_finish(task, PythonBridgeResult.cancelled(task.id))
		return
	if _should_retry(task, err):
		_requeue(task)
		return
	_finish(task, PythonBridgeResult.failed_with_error(err, task_id, task.instance_id))

## Fails a specific set of tasks (send errors etc.). Retry policy applies.
func fail_tasks(tasks: Array, instance_id: String, err: Dictionary) -> void:
	for t in tasks:
		var task := t as PythonBridgeTask
		if task == null or task.state != PythonBridgeTask.State.RUNNING:
			continue
		if _should_retry(task, err):
			_requeue(task)
		else:
			_finish(task, PythonBridgeResult.failed_with_error(
				err, task.id, instance_id))

## Fails all RUNNING tasks of an instance (crash / disconnect). The scheduler
## calls this when an instance dies so no task hangs forever.
func fail_in_flight(instance_id: String, err: Dictionary) -> void:
	for t in _by_id.values():
		var task := t as PythonBridgeTask
		if task.state == PythonBridgeTask.State.RUNNING and (
				task.instance_id == instance_id or task.instance_id == ""):
			if _should_retry(task, err):
				_requeue(task)
			else:
				_finish(task, PythonBridgeResult.failed_with_error(
					err, task.id, instance_id))
	# Also drop window members of the dead instance (they were never sent).
	if _batch_windows.has(instance_id):
		var window: Dictionary = _batch_windows[instance_id]
		for t in window["tasks"]:
			var task2 := t as PythonBridgeTask
			_finish(task2, PythonBridgeResult.failed_with_error(
				err, task2.id, instance_id))
		_batch_windows.erase(instance_id)

## Marks the tasks of a dispatched unit as RUNNING. `instance_id` is the
## concrete instance the scheduler chose (resolves auto-assignment).
func mark_unit_running(instance_id: String, unit: Dictionary) -> void:
	if unit.get("kind") == "single":
		var task: PythonBridgeTask = unit["task"]
		task.state = PythonBridgeTask.State.RUNNING
		task.instance_id = instance_id
	elif unit.get("kind") == "batch":
		for t in unit.get("tasks", []):
			var task2 := t as PythonBridgeTask
			task2.state = PythonBridgeTask.State.RUNNING
			task2.instance_id = instance_id

# ------------------------------------------------------------------ Batching
func _peek_batch_candidates(instance_id: String) -> Array:
	var candidates: Array = []
	for t in _queue:
		var task := t as PythonBridgeTask
		if not _targets(task, instance_id):
			continue
		if not task.batchable or task._next_attempt_ms > 0:
			break # non-batchable or delayed task blocks the front
		if candidates.is_empty():
			candidates.append(task)
		elif task.priority == (candidates[0] as PythonBridgeTask).priority:
			candidates.append(task)
		else:
			break
	return candidates

func _build_batch(tasks: Array, instance_id: String) -> Dictionary:
	var msg := {
		"v": PythonProtocol.PROTOCOL_VERSION,
		"type": PythonProtocol.MSG_BATCH,
		"id": "batch-%d" % _batch_seq,
		PythonProtocol.FIELD_ITEMS: [],
	}
	_batch_seq += 1
	var items: Array = msg[PythonProtocol.FIELD_ITEMS]
	for t in tasks:
		var task := t as PythonBridgeTask
		items.append(_task_item(task))
		_queue.erase(task)
	return {"kind": "batch", "tasks": tasks, "msg": msg, "instance_id": instance_id}

func _flush_window(instance_id: String) -> Dictionary:
	var window: Dictionary = _batch_windows.get(instance_id, {})
	if window.is_empty():
		return {"kind": "none"}
	_batch_windows.erase(instance_id)
	var tasks: Array = window.get("tasks", [])
	# Drop cancelled / terminal members (cancel() finished them already).
	var live: Array = []
	for t in tasks:
		var task := t as PythonBridgeTask
		if not task.is_terminal():
			live.append(task)
	if live.is_empty():
		return {"kind": "none"}
	return _build_batch(live, instance_id)

# ------------------------------------------------------------------ Retry
func _should_retry(task: PythonBridgeTask, err: Dictionary) -> bool:
	if task.retries_left <= 0:
		return false
	var code := str(err.get("code", ""))
	match str(task.retry_policy):
		"all":
			return true
		"connection_error":
			return code == PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR
		"process_error":
			return code == PythonBridgeErrorHandler.CATEGORY_PROCESS_ERROR
	return false

func _requeue(task: PythonBridgeTask) -> void:
	task.retries_left -= 1
	task.state = PythonBridgeTask.State.QUEUED
	task._next_attempt_ms = Time.get_ticks_msec() + int(_cfg.get("retry_delay_ms", 250))
	_insert_sorted(task)

# ------------------------------------------------------------------ Internal
func _finish(task: PythonBridgeTask, result: PythonBridgeResult) -> void:
	task.result = result
	match result.status:
		PythonBridgeErrorHandler.STATUS_OK:
			task.state = PythonBridgeTask.State.COMPLETED
		PythonBridgeErrorHandler.STATUS_TIMEOUT:
			task.state = PythonBridgeTask.State.TIMEOUT
		PythonBridgeErrorHandler.STATUS_CANCELLED:
			task.state = PythonBridgeTask.State.CANCELLED
		_:
			task.state = PythonBridgeTask.State.FAILED
	task.done.emit(result)

func _targets(task: PythonBridgeTask, instance_id: String) -> bool:
	return task.instance_id == "" or task.instance_id == instance_id

func _pop_front_for(instance_id: String) -> PythonBridgeTask:
	for i in _queue.size():
		var task: PythonBridgeTask = _queue[i]
		if task._next_attempt_ms > 0:
			continue
		if task.instance_id == instance_id or task.instance_id == "":
			_queue.remove_at(i)
			return task
	return null

func _peek_front_for(instance_id: String) -> PythonBridgeTask:
	for t in _queue:
		var task := t as PythonBridgeTask
		if task.instance_id == instance_id or task.instance_id == "":
			return task
	return null

func _insert_sorted(task: PythonBridgeTask) -> void:
	# Stable sort by (priority, seq); keeps submission order for equal priority.
	var lo := 0
	var hi := _queue.size() - 1
	while lo <= hi:
		var mid := (lo + hi) / 2
		var other: PythonBridgeTask = _queue[mid]
		if other.priority < task.priority or (
				other.priority == task.priority and other._seq <= task._seq):
			lo = mid + 1
		else:
			hi = mid - 1
	_queue.insert(lo, task)

func _build_task_msg(task: PythonBridgeTask) -> Dictionary:
	var msg := {
		"v": PythonProtocol.PROTOCOL_VERSION,
		"type": PythonProtocol.MSG_TASK,
		"id": task.id,
		"command": task.command,
		"context": task.context_id,
		"source": task.source,
		"timeout_ms": task.timeout_ms,
	}
	msg["data"] = _task_data(task)
	return msg

func _task_item(task: PythonBridgeTask) -> Dictionary:
	return {
		"id": task.id,
		"command": task.command,
		"context": task.context_id,
		"source": task.source,
		"timeout_ms": task.timeout_ms,
		"data": _task_data(task),
	}

func _task_data(task: PythonBridgeTask) -> Dictionary:
	var data: Dictionary = {}
	if task.command == PythonProtocol.CMD_RUN:
		data["input"] = task.input
	elif task.command == PythonProtocol.CMD_CALL:
		data["args"] = task.args
		data["kwargs"] = task.kwargs
	return data

## Lightweight payload size estimate (source length + one-level scan of the
## input/args for byte buffers). It is a guardrail, not an exact measure.
func _estimate_payload_bytes(task: PythonBridgeTask) -> int:
	var bytes := task.source.length()
	if task.command == PythonProtocol.CMD_RUN:
		bytes += _approx_value_size(task.input)
	elif task.command == PythonProtocol.CMD_CALL:
		for a in task.args:
			bytes += _approx_value_size(a)
		for v in task.kwargs.values():
			bytes += _approx_value_size(v)
	return bytes

func _approx_value_size(v: Variant) -> int:
	if v is PackedByteArray:
		return (v as PackedByteArray).size()
	if v is String:
		return (v as String).length()
	if v is Array:
		var total := 0
		for x in v:
			total += _approx_value_size(x)
		return total
	if v is Dictionary:
		var total2 := 0
		for x in v.values():
			total2 += _approx_value_size(x)
		return total2
	return 0