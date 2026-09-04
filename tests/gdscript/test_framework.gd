class_name PBTests
extends RefCounted
## Minimal assertion framework for the headless GDScript test runner.
## Every test class extends this and defines `test_*` methods.

var _passed := 0
var _failed := 0
var _failures: Array[String] = []

func assert_true(cond: bool, msg := "") -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		_failures.append("  FAIL: %s" % (msg if msg != "" else "expected true"))

func assert_false(cond: bool, msg := "") -> void:
	assert_true(not cond, msg)

func assert_eq(a: Variant, b: Variant, msg := "") -> void:
	if a == b:
		_passed += 1
	else:
		_failed += 1
		_failures.append("  FAIL: %s (got %s, expected %s)" % [msg, str(a), str(b)])

func assert_ne(a: Variant, b: Variant, msg := "") -> void:
	assert_true(a != b, msg)

func assert_not_null(v: Variant, msg := "") -> void:
	assert_true(v != null, msg)

func assert_null(v: Variant, msg := "") -> void:
	assert_true(v == null, msg)

func assert_type(v: Variant, type: int, msg := "") -> void:
	assert_eq(typeof(v), type, msg)

func summary(suite_name: String) -> void:
	print("  [%s] %d passed, %d failed" % [suite_name, _passed, _failed])
	for f in _failures:
		print(f)