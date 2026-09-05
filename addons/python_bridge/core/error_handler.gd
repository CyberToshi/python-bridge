class_name PythonBridgeErrorHandler
extends RefCounted
## Structured error taxonomy for the Python Bridge.
##
## Every error that crosses a module boundary is a Dictionary with at least:
##   code        one of the CATEGORY_* constants below
##   message     human readable short description
##   type        exception type (Python) or error class name
##   traceback   full Python traceback (empty for bridge-internal errors)
##   task_id     optional owning task id
##   instance_id optional owning instance id
##
## These codes map onto the legacy `PythonBridgeResult.status` strings through
## `status_for_code()` so existing call sites keep working.

# --- Error categories (protocol + result.error.code) -------------------------
const CATEGORY_BRIDGE_ERROR := "BRIDGE_ERROR"
const CATEGORY_PROCESS_ERROR := "PROCESS_ERROR"
const CATEGORY_CONNECTION_ERROR := "CONNECTION_ERROR"
const CATEGORY_PYTHON_EXCEPTION := "PYTHON_EXCEPTION"
const CATEGORY_SERIALIZATION_ERROR := "SERIALIZATION_ERROR"
const CATEGORY_TIMEOUT_ERROR := "TIMEOUT_ERROR"
const CATEGORY_DEPENDENCY_ERROR := "DEPENDENCY_ERROR"
const CATEGORY_PROTOCOL_ERROR := "PROTOCOL_ERROR"
const CATEGORY_TASK_ERROR := "TASK_ERROR"

# --- Legacy status values (kept for compatibility) ---------------------------
const STATUS_OK := "ok"
const STATUS_ERROR := "error"
const STATUS_TIMEOUT := "timeout"
const STATUS_NOT_READY := "not_ready"
const STATUS_DOWN := "down"
const STATUS_INTERNAL := "internal"
const STATUS_CANCELLED := "cancelled"

## Builds a structured error dictionary.
static func make(code: String, message: String, task_id := "", instance_id := "", exc_type := "", traceback := "") -> Dictionary:
	var err := {
		"code": code,
		"message": message,
		"type": exc_type,
		"traceback": traceback,
	}
	if task_id != "":
		err["task_id"] = task_id
	if instance_id != "":
		err["instance_id"] = instance_id
	return err

## Converts a structured error (or a legacy dict {type,message,traceback})
## into the canonical form. Missing categories default to PYTHON_EXCEPTION
## for legacy Python errors and BRIDGE_ERROR otherwise.
static func normalize(error: Dictionary, task_id := "", instance_id := "") -> Dictionary:
	var code := str(error.get("code", ""))
	if code == "":
		code = CATEGORY_PYTHON_EXCEPTION if error.has("traceback") else CATEGORY_BRIDGE_ERROR
	var out := make(
		code,
		str(error.get("message", "Unknown error")),
		task_id,
		instance_id,
		str(error.get("type", "")),
		str(error.get("traceback", "")))
	for k in error:
		if not out.has(k):
			out[k] = error[k]
	return out

## Maps an error category onto the legacy status string used by
## PythonBridgeResult. Keeps existing `is_error()` / `status` call sites
## working without changes.
static func status_for_code(code: String) -> String:
	match code:
		CATEGORY_PYTHON_EXCEPTION, CATEGORY_TASK_ERROR:
			return STATUS_ERROR
		CATEGORY_TIMEOUT_ERROR:
			return STATUS_TIMEOUT
		CATEGORY_PROCESS_ERROR, CATEGORY_CONNECTION_ERROR:
			return STATUS_DOWN
		CATEGORY_DEPENDENCY_ERROR, CATEGORY_SERIALIZATION_ERROR, CATEGORY_PROTOCOL_ERROR, CATEGORY_BRIDGE_ERROR:
			return STATUS_INTERNAL
	return STATUS_ERROR

## Short, human readable message for logging / UI.
static func message(error: Dictionary) -> String:
	if error.has("message") and str(error["message"]) != "":
		return str(error["message"])
	if error.has("type") and str(error["type"]) != "":
		return str(error["type"])
	return "Unknown error"