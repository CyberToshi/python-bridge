class_name PythonBridgeDataRef
extends RefCounted
## Leichtgewichtiges Handle auf einen grossen Datensatz, der im Python-Prozess
## gehalten wird (Bridge Data Object / Data Plane, Phase 2).
##
## Ein `data_ref`-Descriptor aus Python dekodiert zu genau diesem Objekt -
## NICHT zum vollstaendigen Datensatz. Die Daten werden erst bei
## `PythonBridge.materialize_data(ref)` uebertragen (als normaler, binär-
## chunked Wert) und bei `PythonBridge.release_data(ref)` bzw. beim Ende der
## Instanz freigegeben. Handles koennen mehrfach materialisiert werden.
##
## Lifecycle: Nach einem Instanz-Stop/Crash sind alle Handles dieser Instanz
## stale (der Python-Prozess kennt die Daten nicht mehr). `materialize_data`
## liefert dann einen strukturierten Fehler; `is_stale()` erlaubt die
## fruehe Pruefung ohne Roundtrip.

var data_id: String = ""
var kind: String = ""            # ndarray | ...
var dtype: String = ""           # float32, float64, int32, ...
var shape: Array = []            # z. B. [5000000, 3]
var nbytes: int = 0
var readonly: bool = true
var descriptor: Dictionary = {}  # vollstaendiger Original-Descriptor
var instance_name: String = ""   # gesetzt, sobald der Handle einer Instanz zugeordnet ist

var _stale: bool = false

func _init() -> void:
	pass

## Erzeugt einen Handle aus einem data_ref-Descriptor.
static func from_descriptor(desc: Dictionary) -> PythonBridgeDataRef:
	var ref := PythonBridgeDataRef.new()
	ref.descriptor = desc.duplicate(true)
	ref.data_id = str(desc.get("id", ""))
	ref.kind = str(desc.get("kind", ""))
	ref.dtype = str(desc.get("dtype", ""))
	var s: Variant = desc.get("shape", [])
	ref.shape = s if s is Array else []
	ref.nbytes = int(desc.get("nbytes", 0))
	ref.readonly = bool(desc.get("readonly", true))
	return ref

## Strukturierte Beschreibung (frei von Instance-/State-Interna).
func describe() -> Dictionary:
	return {
		"id": data_id,
		"kind": kind,
		"dtype": dtype,
		"shape": shape.duplicate(),
		"nbytes": nbytes,
		"readonly": readonly,
		"instance": instance_name,
		"stale": _stale,
	}

func is_stale() -> bool:
	return _stale

func mark_stale() -> void:
	_stale = true

func _to_string() -> String:
	return "<PythonBridgeDataRef id=%s kind=%s %s nbytes=%d instance=%s stale=%s>" % [
		data_id, kind, dtype, nbytes, instance_name, _stale]
