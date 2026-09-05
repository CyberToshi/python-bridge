extends SceneTree
## Headless GDScript test runner.
##
## Run from the project root:
##   godot --headless --path . --script res://tests/gdscript/run_tests.gd
##
## Exits with code 0 when all tests pass, 1 otherwise. The editor must have
## imported the project once so the add-on class_names are registered
## (open the project in the editor, then run).

var _total_passed := 0
var _total_failed := 0
var _all_failures: Array[String] = []
var _suites := 0
var _tests := 0

func _initialize() -> void:
	_run_all()
	var msg := "\n=== GDScript tests: %d suites / %d tests, %d passed, %d failed ===" % [
		_suites, _tests, _total_passed, _total_failed]
	print(msg)
	if _total_failed == 0:
		quit(0)
	else:
		quit(1)

func _run_all() -> void:
	var suite_classes: Array = [
		preload("res://tests/gdscript/test_core_units.gd"),
		preload("res://tests/gdscript/test_serializer_protocol.gd"),
		preload("res://tests/gdscript/test_task_layer.gd"),
		preload("res://tests/gdscript/test_wrapper_generator.gd"),
	]
	for cls in suite_classes:
		_run_suite(cls)

func _run_suite(cls: GDScript) -> void:
	_suites += 1
	var probe: Object = cls.new()
	var methods: Array[Dictionary] = probe.get_method_list()
	var test_names: Array[String] = []
	for m in methods:
		var name := str(m.get("name", ""))
		if name.begins_with("test_"):
			test_names.append(name)
	print("Suite: %s (%d tests)" % [cls.resource_path.get_file(), test_names.size()])
	var suite_failed := 0
	for name in test_names:
		var instance = cls.new()
		instance.call(name)
		_total_passed += instance._passed
		_total_failed += instance._failed
		_tests += 1
		suite_failed += instance._failed
		for f in instance._failures:
			_all_failures.append("%s.%s %s" % [cls.resource_path.get_file(), name, f])
		if instance._failed > 0:
			print("  %s FAILED" % name)
			for f in instance._failures:
				print("      " + f)
	if suite_failed == 0:
		print("  suite OK")
	else:
		print("  suite FAILED (%d failures)" % suite_failed)