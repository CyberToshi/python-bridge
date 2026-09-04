class_name PythonBridgeResult
extends RefCounted
## Strukturierter Ergebnis-/Fehler-Container aller PythonBridge-Aufrufe.
##
## Status-Werte:
##   "ok"        - Ausfuehrung erfolgreich, `value` enthaelt das Ergebnis
##   "error"     - Python-Exception, Details in `error`
##   "timeout"   - Antwort kam nicht rechtzeitig
##   "not_ready" - Instanz ist (noch) nicht bereit
##   "down"      - Python-Prozess gestoppt/gestorben
##   "internal"  - Fehler in der Tool-Infrastruktur

var ok: bool = false
var status: String = "internal"
var value: Variant = null
var error: Dictionary = {}            # {type, message, traceback}
var request_id: String = ""
var meta: Dictionary = {}

func is_ok() -> bool:
	return ok

func is_error() -> bool:
	return not ok

func error_message() -> String:
	if error.has("message") and str(error["message"]) != "":
		return str(error["message"])
	return status

static func success(value: Variant = null, meta := {}) -> PythonBridgeResult:
	var result := PythonBridgeResult.new()
	result.ok = true
	result.status = "ok"
	result.value = value
	result.meta = meta
	return result

static func failed(status: String, message: String = "", err := {}) -> PythonBridgeResult:
	var result := PythonBridgeResult.new()
	result.ok = false
	result.status = status
	if err.is_empty():
		err = {"type": status, "message": message, "traceback": ""}
	elif not err.has("message"):
		err["message"] = message
	result.error = err
	return result