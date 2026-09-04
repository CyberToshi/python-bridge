class_name PBTestWrapperGenerator
extends PBTests
## Tests for the deterministic wrapper generator (editor component).

const SCHEMA: Array = [
	{
		"name": "calculate",
		"kind": "def",
		"docstring": "Adds two numbers.",
		"returns": "int",
		"params": [
			{"name": "a", "kind": "pos", "has_default": false, "default": "", "annotation": "int"},
			{"name": "b", "kind": "pos", "has_default": true, "default": "2", "annotation": "int"},
		],
	},
	{
		"name": "ping",
		"kind": "def",
		"docstring": "",
		"returns": "",
		"params": [],
	},
]

func test_generates_valid_marker() -> void:
	var res := PythonBridgeWrapperGenerator.generate(SCHEMA, "mein_skript")
	assert_true(bool(res.get("ok", false)))
	var code: String = res.get("code", "")
	assert_true(code.begins_with(PythonBridgeWrapperGenerator.MARKER))
	assert_true(code.contains("class_name PyBridgeMeinSkript"))
	assert_true(code.contains("func calculate"))
	assert_true(code.contains("func ping"))
	assert_true(code.contains("PythonBridge.call_script"))

func test_deterministic() -> void:
	var a := PythonBridgeWrapperGenerator.generate(SCHEMA, "skript")
	var b := PythonBridgeWrapperGenerator.generate(SCHEMA, "skript")
	assert_eq(a.get("code"), b.get("code"), "same input -> identical output")

func test_sorted_alphabetically() -> void:
	var res := PythonBridgeWrapperGenerator.generate(SCHEMA, "s")
	var code: String = res.get("code", "")
	var idx_calc := code.find("func calculate")
	var idx_ping := code.find("func ping")
	assert_true(idx_calc > -1 and idx_ping > -1)
	assert_true(idx_calc < idx_ping, "calculate before ping (alphabetical)")

func test_sanitized_class_name() -> void:
	var res := PythonBridgeWrapperGenerator.generate(SCHEMA, "mein-skript")
	var code: String = res.get("code", "")
	assert_true(code.contains("class_name PyBridgeMeinSkript"))

func test_marker_detection() -> void:
	var path := "user://pb_test_wrapper.gd"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(PythonBridgeWrapperGenerator.MARKER + "\n# content\n")
	f.close()
	assert_true(PythonBridgeWrapperGenerator.is_generated(path))
	DirAccess.remove_absolute(path)