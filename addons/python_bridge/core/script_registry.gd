class_name PythonBridgeScriptRegistry
extends RefCounted
## Script-Registry (Code Plane, Phase 1).
##
## Zwei getrennte Aufgaben:
##
## 1. Datei-Lesecache:  `entry_for(path)` liefert {source, hash, mtime, size}
##    und liest die Datei nur, wenn sich mtime oder Groesse geaendert haben.
##    Damit entfaellt das erneute Einlesen + Hashen unveraenderten Sources
##    bei jedem Call (Bottleneck A3, Godot-Seite).
##
## 2. Instanz-Kontext-Registry:  `is_defined(instance, context, hash)` /
##    `confirm(instance, context, hash)` tracken pro Python-Instanz, welche
##    (context_id -> source_hash) der Server bereits kennt. Ist ein Hash
##    bestaetigt, kann der Scheduler den Source beim Dispatch entfernen und
##    nur noch den Hash mitschicken (DEFINE-once, keine erneute Uebertragung).
##
## Die Registry ist rein Godot-seitig und laeuft auf dem Main-Thread (wie der
## TaskManager). Sie haelt keinen Python-State: Nach einem Prozess-Neustart
## werden die Bestaetigungen der betroffenen Instanz verworfen
## (`reset_instance`), wodurch der naechste Call den Source wieder mitschickt
## und den Context korrekt neu aufbaut.

var _file_entries: Dictionary = {}        # path -> {mtime, size, source, hash}
var _defined: Dictionary = {}             # instance -> {context -> source_hash}

## Liest die Datei gecacht. Liefert {source, hash, mtime, size} oder {} wenn
## die Datei nicht existiert bzw. nicht gelesen werden kann. `source` ist
## der vollstaendige, unveraenderte Python-Quelltext.
func entry_for(path: String) -> Dictionary:
	var cached: Dictionary = _file_entries.get(path, {})
	var mtime := FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else -1
	if not cached.is_empty() and int(cached.get("mtime", -1)) == mtime:
		return cached
	var entry := _read(path, mtime)
	if not entry.is_empty():
		_file_entries[path] = entry
	return entry

## Erzwingt das naechste Einlesen (Hot Reload / Speichern). Liefert direkt
## den frischen Eintrag.
func refresh(path: String) -> Dictionary:
	_file_entries.erase(path)
	return entry_for(path)

func forget(path: String) -> void:
	_file_entries.erase(path)

# ------------------------------------------------------------------ Per-instance
## True, wenn die Instanz den Context bereits mit genau diesem Hash definiert
## hat (und der Source daher beim Dispatch weggelassen werden darf).
func is_defined(instance: String, context: String, hash: String) -> bool:
	if hash == "" or instance == "" or context == "":
		return false
	var contexts: Dictionary = _defined.get(instance, {})
	return contexts.get(context, "") == hash

## Registriert, dass die Instanz den Context mit `hash` kennt.
func confirm(instance: String, context: String, hash: String) -> void:
	if hash == "" or instance == "" or context == "":
		return
	if not _defined.has(instance):
		_defined[instance] = {}
	_defined[instance][context] = hash

## Verwirft alle Bestaetigungen einer Instanz (Neustart / Crash / Stop).
func reset_instance(instance: String) -> void:
	_defined.erase(instance)

## Verwirft die Bestaetigung eines Contexts auf einer Instanz.
func reset_context(instance: String, context: String) -> void:
	if _defined.has(instance):
		(_defined[instance] as Dictionary).erase(context)

## Verwirft eine Context-Bestaetigung auf allen Instanzen (Hot Reload).
func reset_context_all(context: String) -> void:
	for instance in _defined.keys():
		(_defined[instance] as Dictionary).erase(context)

func confirmed_count() -> int:
	var total := 0
	for contexts in _defined.values():
		total += (contexts as Dictionary).size()
	return total

# ------------------------------------------------------------------ Internal
func _read(path: String, mtime: int) -> Dictionary:
	if mtime < 0:
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var source := f.get_as_text()
	f.close()
	return {
		"source": source,
		"hash": source.sha256_text(),
		"mtime": mtime,
		"size": source.length(),
	}
