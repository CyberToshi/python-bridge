class_name PBTestTaskLayer
extends PBTests
## Unit tests for the task layer (task manager + scheduler).

func _cfg() -> Dictionary:
	return PythonBridgeConfig.normalize({
		"max_queued_tasks": 10,
		"max_batch_size": 4,
		"max_batch_delay_ms": 1000,
		"max_retries": 1,
		"retry_delay_ms": 0,
	})

func test_priority_order() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var now := 0
	for i in 3:
		var t := PythonBridgeTask.make_call("t%d" % i, "ctx", "src", "f", [], {}, 1000, i)
		assert_true(tm.submit(t, now).is_ok())
	var unit := tm.next_unit("inst", now)
	assert_eq(unit["kind"], "single")
	assert_eq((unit["task"] as PythonBridgeTask).id, "t0", "lowest priority value first")

func test_backpressure_queue_full() -> void:
	var cfg := PythonBridgeConfig.normalize({"max_queued_tasks": 2})
	var tm := PythonBridgeTaskManager.new(cfg)
	var now := 0
	for i in 2:
		assert_true(tm.submit(PythonBridgeTask.make_call("a%d" % i, "c", "s", "f", [], {}, 1000), now).is_ok())
	var third := tm.submit(PythonBridgeTask.make_call("a3", "c", "s", "f", [], {}, 1000), now)
	assert_true(third.is_error())
	assert_eq(third.status, "error")
	assert_eq(third.error_code(), PythonBridgeErrorHandler.CATEGORY_TASK_ERROR)

func test_payload_too_large() -> void:
	var cfg := PythonBridgeConfig.normalize({"max_payload_bytes": 16})
	var tm := PythonBridgeTaskManager.new(cfg)
	var big := PackedByteArray()
	big.resize(64)
	var res := tm.submit(PythonBridgeTask.make_run("big", "c", "s", big, 1000), 0)
	assert_true(res.is_error())
	assert_eq(res.error_code(), PythonBridgeErrorHandler.CATEGORY_TASK_ERROR)

func test_cancel_queued() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var t := PythonBridgeTask.make_call("c1", "ctx", "s", "f", [], {}, 1000)
	tm.submit(t, 0)
	assert_true(tm.cancel("c1"))
	assert_eq(t.state, PythonBridgeTask.State.CANCELLED)

func test_retry_on_connection_error() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var t := PythonBridgeTask.make_call("r1", "ctx", "s", "f", [], {}, 1000)
	tm.submit(t, 0)
	var unit := tm.next_unit("inst", 0)
	tm.mark_unit_running("inst", unit)
	# simulate a send failure -> connection error
	var err := PythonBridgeErrorHandler.make(
		PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR, "conn lost", t.id)
	tm.fail_tasks([t], "inst", err, 0)
	assert_eq(t.state, PythonBridgeTask.State.QUEUED, "retry requeues")
	assert_eq(t.retries_left, 0)
	# dispatches again
	var unit2 := tm.next_unit("inst", 0)
	assert_eq(unit2["kind"], "single")

func test_no_retry_for_python_error() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var t := PythonBridgeTask.make_call("p1", "ctx", "s", "f", [], {}, 1000)
	tm.submit(t, 0)
	var unit := tm.next_unit("inst", 0)
	tm.mark_unit_running("inst", unit)
	tm.resolve_result("inst", {
		"msg": {"type": PythonProtocol.MSG_TASK_ERROR, "id": t.id, "status": "error",
			"error": {"code": "PYTHON_EXCEPTION", "type": "ValueError", "message": "x"}},
	})
	assert_eq(t.state, PythonBridgeTask.State.FAILED)
	assert_eq(t.result.status, "error")

func test_success_resolution() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var t := PythonBridgeTask.make_call("s1", "ctx", "s", "f", [], {}, 1000)
	tm.submit(t, 0)
	var unit := tm.next_unit("inst", 0)
	tm.mark_unit_running("inst", unit)
	tm.resolve_result("inst", {
		"msg": {"type": PythonProtocol.MSG_TASK_RESULT, "id": t.id, "status": "ok", "data": 7},
	})
	assert_eq(t.state, PythonBridgeTask.State.COMPLETED)
	assert_eq(t.result.value, 7)

func test_timeout() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var t := PythonBridgeTask.make_call("to1", "ctx", "s", "f", [], {}, 50)
	tm.submit(t, 0)
	var unit := tm.next_unit("inst", 0)
	tm.mark_unit_running("inst", unit)
	var timed_out := tm.check_timeouts(100)
	assert_true(timed_out.has("to1"))
	assert_eq(t.state, PythonBridgeTask.State.TIMEOUT)

func test_queue_timeout_does_not_kill_queued_early() -> void:
	# Execution timeout (50 ms) starts at RUNNING, not at submission: a task
	# that waits 40 ms in the queue must not time out before it ran.
	var tm := PythonBridgeTaskManager.new(_cfg())
	var t := PythonBridgeTask.make_call("q1", "ctx", "s", "f", [], {}, 50)
	tm.submit(t, 0)
	# still queued at now=40: created 40 ms ago < queue_timeout (60000 default)
	var timed_out := tm.check_timeouts(40)
	assert_false(timed_out.has("q1"))
	assert_eq(t.state, PythonBridgeTask.State.QUEUED)

func test_queue_timeout_caps_wait_for_slot() -> void:
	var cfg := PythonBridgeConfig.normalize({"queue_timeout_ms": 30})
	var tm := PythonBridgeTaskManager.new(cfg)
	var t := PythonBridgeTask.make_call("q2", "ctx", "s", "f", [], {}, 500)
	tm.submit(t, 0)
	# never dispatched; 100 ms queue wait > 30 ms queue cap -> queue timeout
	var timed_out := tm.check_timeouts(100)
	assert_false(timed_out.has("q2"), "queued task is not a RUNNING timeout")
	assert_eq(t.state, PythonBridgeTask.State.TIMEOUT)
	assert_eq(t.result.error.get("reason", ""), "queue")

func test_execution_timeout_counts_from_running() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var t := PythonBridgeTask.make_call("ex1", "ctx", "s", "f", [], {}, 50)
	tm.submit(t, 0)
	# dispatched at 1000, checked at 1030: 30 ms of execution < 50 ms cap
	var unit := tm.next_unit("inst", 1000)
	tm.mark_unit_running("inst", unit, 1000)
	var timed_out := tm.check_timeouts(1030)
	assert_false(timed_out.has("ex1"))
	# still running at 1060: 60 ms of execution > 50 ms cap
	var timed_out2 := tm.check_timeouts(1060)
	assert_true(timed_out2.has("ex1"))
	assert_eq(t.state, PythonBridgeTask.State.TIMEOUT)

func test_batching_window_groups_tasks() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var now := 1000
	var t1 := PythonBridgeTask.make_call("b1", "ctx", "s", "f", [], {}, 1000)
	var t2 := PythonBridgeTask.make_call("b2", "ctx", "s", "f", [], {}, 1000)
	tm.submit(t1, now)
	tm.submit(t2, now)
	# two compatible tasks -> window opens (wait), not sent yet
	var unit := tm.next_unit("inst", now)
	assert_eq(unit["kind"], "wait")
	# window expiry (delay 1000ms) flushes as a batch
	tm.tick_windows(now)
	var unit2 := tm.next_unit("inst", now + 1000)
	assert_eq(unit2["kind"], "batch")
	assert_eq((unit2["tasks"] as Array).size(), 2)
	var items: Array = unit2["msg"][PythonProtocol.FIELD_ITEMS]
	assert_eq(items.size(), 2)

func test_batch_preserves_submission_order() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var now := 1000
	for i in 4:
		tm.submit(PythonBridgeTask.make_call("o%d" % i, "ctx", "s", "f", [], {}, 1000), now)
	var unit := tm.next_unit("inst", now)
	# 4 candidates == max_batch_size: the window fills immediately and the
	# batch dispatches right away (no pointless wait for more tasks).
	if unit.get("kind") == "wait":
		tm.tick_windows(now)
		unit = tm.next_unit("inst", now)
	assert_eq(unit.get("kind"), "batch")
	var items: Array = unit["msg"][PythonProtocol.FIELD_ITEMS]
	for i in 4:
		assert_eq(items[i]["id"], "o%d" % i)

func test_non_batchable_task_dispatches_immediately() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var now := 1000
	var t := PythonBridgeTask.make_call("nb1", "ctx", "s", "f", [], {}, 1000)
	t.batchable = false
	tm.submit(t, now)
	var unit := tm.next_unit("inst", now)
	assert_eq(unit["kind"], "single")

func test_explicit_instance_targeting() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var t := PythonBridgeTask.make_call("x1", "ctx", "s", "f", [], {}, 1000)
	t.instance_id = "worker"
	tm.submit(t, 0)
	var unit := tm.next_unit("worker", 0)
	assert_eq(unit["kind"], "single")
	var unit2 := tm.next_unit("other", 0)
	assert_eq(unit2["kind"], "none")

func test_fail_in_flight_on_crash() -> void:
	var tm := PythonBridgeTaskManager.new(_cfg())
	var t := PythonBridgeTask.make_call("cr1", "ctx", "s", "f", [], {}, 1000)
	tm.submit(t, 0)
	var unit := tm.next_unit("inst", 0)
	tm.mark_unit_running("inst", unit)
	# Connection loss is retryable under the default "connection_error"
	# policy; a hard process crash is not (by design).
	var err := PythonBridgeErrorHandler.make(
		PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR, "connection lost", "", "inst")
	tm.fail_in_flight("inst", err, 0)
	assert_eq(t.state, PythonBridgeTask.State.QUEUED, "retryable crash requeues")

# ------------------------------------------------------------ ScriptRegistry
func _registry_cfg() -> Dictionary:
	var cfg := _cfg()
	cfg["max_batch_size"] = 0   # disable batching: deterministic single units
	return cfg

func _attach_tm() -> Dictionary:
	var reg := PythonBridgeScriptRegistry.new()
	var tm := PythonBridgeTaskManager.new(_registry_cfg())
	tm.attach_registry(reg)
	return {"tm": tm, "reg": reg}

func test_registry_sends_source_until_defined() -> void:
	var ctx: Dictionary = _attach_tm()
	var tm: PythonBridgeTaskManager = ctx["tm"]
	var t := PythonBridgeTask.make_call("d1", "ctxA", "def f(): return 1", "f", [], {}, 1000)
	t.source_hash = t.source.sha256_text()
	tm.submit(t, 0)
	# First dispatch: instance does not know the hash yet -> source travels.
	var unit := tm.next_unit("inst", 0)
	assert_eq(unit["kind"], "single")
	assert_eq(unit["msg"]["source"], t.source)
	assert_eq(unit["msg"]["source_hash"], t.source_hash)

func test_registry_drops_source_once_defined() -> void:
	var ctx: Dictionary = _attach_tm()
	var tm: PythonBridgeTaskManager = ctx["tm"]
	var reg: PythonBridgeScriptRegistry = ctx["reg"]
	reg.confirm("inst", "ctxB", "hash123")
	var t := PythonBridgeTask.make_call("d2", "ctxB", "def f(): return 2", "f", [], {}, 1000)
	t.source_hash = "hash123"
	tm.submit(t, 0)
	var unit := tm.next_unit("inst", 0)
	assert_eq(unit["kind"], "single")
	assert_eq(unit["msg"]["source"], "", "defined context is referenced by hash only")
	assert_eq(unit["msg"]["source_hash"], "hash123")

func test_ok_result_confirms_registry() -> void:
	var ctx: Dictionary = _attach_tm()
	var tm: PythonBridgeTaskManager = ctx["tm"]
	var reg: PythonBridgeScriptRegistry = ctx["reg"]
	var t := PythonBridgeTask.make_call("d3", "ctxC", "def f(): return 3", "f", [], {}, 1000)
	t.source_hash = t.source.sha256_text()
	tm.submit(t, 0)
	var unit := tm.next_unit("inst", 0)
	assert_eq(unit["msg"]["source"], t.source)
	tm.mark_unit_running("inst", unit, 0)
	tm.resolve_result("inst", {
		"msg": {"type": PythonProtocol.MSG_TASK_RESULT, "id": t.id, "status": "ok", "data": 3},
	})
	assert_eq(t.state, PythonBridgeTask.State.COMPLETED)
	assert_true(reg.is_defined("inst", "ctxC", t.source_hash),
		"ok result with source confirms the instance/context/hash")
	# Follow-up call on the same instance now goes hash-only.
	var t2 := PythonBridgeTask.make_call("d4", "ctxC", t.source, "f", [], {}, 1000)
	t2.source_hash = t.source_hash
	tm.submit(t2, 0)
	var unit2 := tm.next_unit("inst", 0)
	assert_eq(unit2["msg"]["source"], "")

func test_reset_instance_forces_source_again() -> void:
	var ctx: Dictionary = _attach_tm()
	var tm: PythonBridgeTaskManager = ctx["tm"]
	var reg: PythonBridgeScriptRegistry = ctx["reg"]
	reg.confirm("inst", "ctxD", "h1")
	# Process restart (or crash): all confirmations of the instance are gone.
	reg.reset_instance("inst")
	var t := PythonBridgeTask.make_call("d5", "ctxD", "def f(): return 5", "f", [], {}, 1000)
	t.source_hash = "h1"
	tm.submit(t, 0)
	var unit := tm.next_unit("inst", 0)
	assert_eq(unit["msg"]["source"], t.source,
		"reset instance -> next dispatch carries the source again")

func test_script_not_defined_self_heals_once() -> void:
	var ctx: Dictionary = _attach_tm()
	var tm: PythonBridgeTaskManager = ctx["tm"]
	var t := PythonBridgeTask.make_call("d6", "ctxE", "def f(): return 6", "f", [], {}, 1000)
	t.source_hash = t.source.sha256_text()
	tm.submit(t, 0)
	var unit := tm.next_unit("inst", 0)
	tm.mark_unit_running("inst", unit, 0)
	var retries_before := t.retries_left
	# Server lost the context (restart race): answers SCRIPT_NOT_DEFINED.
	tm.resolve_result("inst", {
		"msg": {"type": PythonProtocol.MSG_TASK_ERROR, "id": t.id, "status": "error",
			"error": {"code": PythonBridgeErrorHandler.CATEGORY_TASK_ERROR,
				"type": "ScriptNotDefined", "message": "context lost"}},
	})
	assert_eq(t.state, PythonBridgeTask.State.QUEUED, "heal resend requeues")
	assert_eq(t.retries_left, retries_before, "heal does not consume a retry")
	# The resent unit carries the source (forced), so the server can rebuild.
	var unit2 := tm.next_unit("inst", 0)
	assert_eq(unit2["kind"], "single")
	assert_eq(unit2["msg"]["source"], t.source)
	tm.mark_unit_running("inst", unit2, 0)
	tm.resolve_result("inst", {
		"msg": {"type": PythonProtocol.MSG_TASK_RESULT, "id": t.id, "status": "ok", "data": 6},
	})
	assert_eq(t.state, PythonBridgeTask.State.COMPLETED)
	assert_true((ctx["reg"] as PythonBridgeScriptRegistry).is_defined(
		"inst", "ctxE", t.source_hash))

func test_temp_code_always_carries_source() -> void:
	var ctx: Dictionary = _attach_tm()
	var tm: PythonBridgeTaskManager = ctx["tm"]
	# Temp code has no hash -> must always travel inline, never suppressed.
	tm.submit(PythonBridgeTask.make_call("d7", "ctxT", "def g(): return 1", "g", [], {}, 1000), 0)
	var unit := tm.next_unit("inst", 0)
	assert_eq(unit["kind"], "single")
	assert_eq(unit["msg"]["source"], "def g(): return 1")
	# A (no-op) confirm with an empty hash must not suppress the source either.
	(ctx["reg"] as PythonBridgeScriptRegistry).confirm("inst", "ctxT", "")
	tm.submit(PythonBridgeTask.make_call("d8", "ctxT", "def g(): return 1", "g", [], {}, 1000), 0)
	var unit2 := tm.next_unit("inst", 0)
	assert_eq(unit2["msg"]["source"], "def g(): return 1")