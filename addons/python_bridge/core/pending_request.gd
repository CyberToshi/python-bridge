class_name PendingRequest
extends RefCounted
## Ein ausstehender Request. Wird per `done`-Signal mit dem Ergebnis
## aufgelöst. `await req.done` liefert das `PythonBridgeResult`.

signal done(result: PythonBridgeResult)

var id: String = ""
var created: int = 0
var timeout_ms: int = 0