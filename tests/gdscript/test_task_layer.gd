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
	tm.fail_tasks([t], "inst", err)
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
	assert_eq(unit["kind"], "wait")
	tm.tick_windows(now)
	var unit2 := tm.next_unit("inst", now)
	assert_eq(unit2["kind"], "batch")
	var items: Array = unit2["msg"][PythonProtocol.FIELD_ITEMS]
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
	var err := PythonBridgeErrorHandler.make(
		PythonBridgeErrorHandler.CATEGORY_PROCESS_ERROR, "process died", "", "inst")
	tm.fail_in_flight("inst", err)
	assert_eq(t.state, PythonBridgeTask.State.QUEUED, "retryable crash requeues")