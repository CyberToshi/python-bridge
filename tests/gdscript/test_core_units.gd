class_name PBTestCoreUnits
extends PBTests
## Unit tests for the foundation layer (config, error handler, mapper).

func test_config_defaults() -> void:
	var cfg := PythonBridgeConfig.normalize({})
	assert_eq(cfg.get("max_queued_tasks", 0), 1000)
	assert_eq(cfg.get("max_batch_size", 0), 32)
	assert_eq(cfg.get("max_batch_delay_ms", 0), 32)
	assert_eq(cfg.get("max_results_per_frame", 0), 64)
	assert_eq(cfg.get("hot_reload_mode", ""), "reload_context")
	assert_eq(PythonBridgeConfig.PROTOCOL_VERSION, 2)

func test_config_override_and_coerce() -> void:
	var cfg := PythonBridgeConfig.normalize({
		"max_batch_size": 8,
		"dependencies": ["numpy", "scipy"],
		"autostart": true,
	})
	assert_eq(cfg.get("max_batch_size"), 8)
	assert_true(cfg.get("dependencies") is PackedStringArray)
	assert_true(bool(cfg.get("autostart")))

func test_error_handler_taxonomy() -> void:
	var err := PythonBridgeErrorHandler.make(
		PythonBridgeErrorHandler.CATEGORY_PYTHON_EXCEPTION,
		"boom", "t1", "inst1", "ValueError", "trace...")
	assert_eq(err["code"], PythonBridgeErrorHandler.CATEGORY_PYTHON_EXCEPTION)
	assert_eq(err["type"], "ValueError")
	assert_eq(err["task_id"], "t1")
	assert_eq(err["instance_id"], "inst1")
	assert_eq(PythonBridgeErrorHandler.status_for_code(
		PythonBridgeErrorHandler.CATEGORY_CONNECTION_ERROR), "down")
	assert_eq(PythonBridgeErrorHandler.status_for_code(
		PythonBridgeErrorHandler.CATEGORY_TIMEOUT_ERROR), "timeout")

func test_error_handler_normalize_legacy() -> void:
	var legacy := {"type": "ValueError", "message": "x", "traceback": "tb"}
	var norm := PythonBridgeErrorHandler.normalize(legacy, "t9")
	assert_eq(norm["code"], PythonBridgeErrorHandler.CATEGORY_PYTHON_EXCEPTION)
	assert_eq(norm["traceback"], "tb")

func test_type_mapper_table() -> void:
	assert_true(PythonBridgeTypeMapper.info_for_tag("vec3").has("python"))
	assert_true(PythonBridgeTypeMapper.MAPPINGS.size() > 10)

func test_type_mapper_custom_registry() -> void:
	var tag := "mytag"
	PythonBridgeTypeMapper.register(tag,
		func(v: Variant, chunks: Array) -> Variant: return {"$pb": tag, "x": 1},
		func(v: Variant, chunks: Array) -> Variant: return 42)
	assert_true(PythonBridgeTypeMapper.has_custom(tag))
	assert_true(PythonBridgeTypeMapper.custom_decode(tag).is_valid())
	PythonBridgeTypeMapper.unregister(tag)
	assert_false(PythonBridgeTypeMapper.has_custom(tag))

func test_result_ok_error() -> void:
	var ok := PythonBridgeResult.success(5, {"a": 1})
	assert_true(ok.is_ok())
	assert_eq(ok.value, 5)
	var err := PythonBridgeResult.failed_with_error(
		PythonBridgeErrorHandler.make(PythonBridgeErrorHandler.CATEGORY_TIMEOUT_ERROR, "late"))
	assert_true(err.is_error())
	assert_eq(err.status, "timeout")
	assert_eq(err.error_code(), PythonBridgeErrorHandler.CATEGORY_TIMEOUT_ERROR)

func test_result_cancelled() -> void:
	var c := PythonBridgeResult.cancelled("t1")
	assert_eq(c.status, "cancelled")
	assert_true(c.is_error())