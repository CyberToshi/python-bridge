class_name PythonBridgeResult
extends RefCounted
## Structured result/error container for every PythonBridge call.
##
## Status values (legacy, kept for compatibility):
##   "ok"        - execution succeeded, `value` holds the result
##   "error"     - Python exception, details in `error`
##   "timeout"   - answer did not arrive in time
##   "not_ready" - instance is not (yet) ready
##   "down"      - Python process stopped/died
##   "internal"  - tool infrastructure error
##   "cancelled" - task was cancelled before completion
##
## `error.code` uses the PythonBridgeErrorHandler taxonomy
## (e.g. "PYTHON_EXCEPTION", "CONNECTION_ERROR", ...).

var ok: bool = false
var status: String = "internal"
var value: Variant = null
var error: Dictionary = {}            # {code, type, message, traceback, task_id, instance_id}
var request_id: String = ""
var task_id: String = ""
var instance_id: String = ""
var meta: Dictionary = {}

func is_ok() -> bool:
	return ok

func is_error() -> bool:
	return not ok

func error_message() -> String:
	if error.has("message") and str(error["message"]) != "":
		return str(error["message"])
	return status

func error_code() -> String:
	return str(error.get("code", ""))

static func success(value: Variant = null, meta := {}) -> PythonBridgeResult:
	var result := PythonBridgeResult.new()
	result.ok = true
	result.status = "ok"
	result.value = value
	result.meta = meta
	return result

## Builds a failure result from a structured error dictionary. When `err`
## lacks a "code", it is normalized via PythonBridgeErrorHandler.
static func failed_with_error(err: Dictionary, task_id := "", instance_id := "") -> PythonBridgeResult:
	var normalized: Dictionary = PythonBridgeErrorHandler.normalize(err, task_id, instance_id)
	var result := PythonBridgeResult.new()
	result.ok = false
	result.status = PythonBridgeErrorHandler.status_for_code(str(normalized.get("code", "")))
	result.error = normalized
	result.task_id = task_id
	result.instance_id = instance_id
	return result

## Builds a cancelled result (status "cancelled", TASK_ERROR category).
static func cancelled(task_id := "") -> PythonBridgeResult:
	var result := PythonBridgeResult.new()
	result.ok = false
	result.status = "cancelled"
	result.error = PythonBridgeErrorHandler.make(
		PythonBridgeErrorHandler.CATEGORY_TASK_ERROR, "Task cancelled", task_id)
	result.task_id = task_id
	return result

## Legacy constructor: builds a failure from a status string + message.
static func failed(status: String, message: String = "", err := {}) -> PythonBridgeResult:
	var result := PythonBridgeResult.new()
	result.ok = false
	result.status = status
	if err.is_empty():
		err = PythonBridgeErrorHandler.make(
			PythonBridgeErrorHandler.CATEGORY_BRIDGE_ERROR, message)
	elif not err.has("code"):
		err = PythonBridgeErrorHandler.normalize(err)
	result.error = err
	return result