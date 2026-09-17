extends SceneTree
## Headless GDScript unit test runner for the Python Bridge offline suites.
## Run: godot --headless --path . --script res://tests/gdscript/run_tests.gd
##
## The live e2e suites (test_ipc_api.gd, e2e_live.gd) are intentionally not
## part of this runner: they need a running Python instance and are executed
## via the bridge itself.

const SUITES := [
	"res://tests/gdscript/test_core_units.gd",
	"res://tests/gdscript/test_task_layer.gd",
	"res://tests/gdscript/test_serializer_protocol.gd",
	"res://tests/gdscript/test_wrapper_generator.gd",
]


func _initialize() -> void:
	var total_passed := 0
	var total_failed := 0
	var failed_suites := 0

	for path in SUITES:
		var script: GDScript = load(path)
		if script == null:
			print("[RunTests] FAIL: cannot load ", path)
			failed_suites += 1
			continue
		var suite: PBTests = script.new()
		var method_list := script.get_script_method_list()
		for m in method_list:
			var mname: String = m["name"]
			if mname.begins_with("test_"):
				suite.call(mname)
		suite.summary(path.get_file())
		total_passed += suite._passed
		total_failed += suite._failed
		if suite._failed > 0:
			failed_suites += 1

	print("[RunTests] TOTAL: %d passed, %d failed (%d failing suites)" % [
		total_passed, total_failed, failed_suites])
	quit(0 if total_failed == 0 else 1)
