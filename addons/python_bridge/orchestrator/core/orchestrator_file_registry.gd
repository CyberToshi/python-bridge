class_name OrchestratorFileRegistry
extends RefCounted
## Kennt die Dateien, die Aufgaben als Eingabe brauchen (Phase 6, §12).
##
## Eine Datei wird ueber ihren **Inhalt** identifiziert (SHA-256). Daraus folgt
## direkt die wichtigste Eigenschaft des Systems:
##
##     Kann eine Datei bereits auf dem Zielrechner?  ->  KEIN Transfer
##
## Der Registry ist transportunabhaengig: er weiss **ob** etwas vorhanden ist,
## nicht **wie** es dorthin kommt (das macht der OrchestratorFileTransfer).
##
## Logische IDs statt Pfade (§15): Aufgaben referenzieren nur `file_id`, also
## den Inhalt. Absolute Pfade des Hauptrechners werden nie an Worker gegeben.

enum State { UNKNOWN, TRANSFERRING, VERIFYING, PRESENT, FAILED, CANCELLED }

signal file_registered(file_id: String)
signal location_changed(file_id: String, server_id: String, state: int)

## file_id -> {name, size, sha256, source_path}
var _files: Dictionary = {}
## file_id -> {server_id: State}
var _locations: Dictionary = {}
var _order: Array[String] = []


# ---------------------------------------------------------------- Aufnahme
## Registriert eine Datei. `file_id` ist der SHA-256 des Inhalts - damit sind
## identische Dateien automatisch dieselbe Datei.
func register(name: String, size: int, sha256: String, source_path := "") -> String:
	var file_id := sha256.to_lower()
	if file_id == "":
		return ""
	if not _files.has(file_id):
		_files[file_id] = {
			"file_id": file_id,
			"name": name,
			"size": size,
			"sha256": file_id,
			"source_path": source_path,
		}
		_order.append(file_id)
		file_registered.emit(file_id)
	return file_id


func has(file_id: String) -> bool:
	return _files.has(file_id.to_lower())


func get_file(file_id: String) -> Dictionary:
	return (_files.get(file_id.to_lower(), {}) as Dictionary).duplicate()


func file_ids() -> Array[String]:
	return _order.duplicate()


func file_count() -> int:
	return _order.size()


func name_of(file_id: String) -> String:
	var info := get_file(file_id)
	return str(info.get("name", file_id))


func source_path_of(file_id: String) -> String:
	return str(get_file(file_id).get("source_path", ""))


# ---------------------------------------------------------------- Standorte
func mark(server_id: String, file_id: String, state: int) -> void:
	var key := file_id.to_lower()
	if server_id == "" or not _files.has(key):
		return
	var per_file: Dictionary = _locations.get(key, {})
	if int(per_file.get(server_id, State.UNKNOWN)) == state:
		return
	per_file[server_id] = state
	_locations[key] = per_file
	location_changed.emit(key, server_id, state)


func state_on(server_id: String, file_id: String) -> int:
	var per_file: Dictionary = _locations.get(file_id.to_lower(), {})
	return int(per_file.get(server_id, State.UNKNOWN))


func is_present(server_id: String, file_id: String) -> bool:
	return state_on(server_id, file_id) == State.PRESENT


## Dateien einer Liste, die auf dem Server noch fehlen.
func missing_on(server_id: String, file_ids: Array) -> Array[String]:
	var out: Array[String] = []
	for file_id in file_ids:
		var key := str(file_id).to_lower()
		if key == "" or not _files.has(key):
			continue
		if not is_present(server_id, key):
			out.append(key)
	return out


func all_present(server_id: String, file_ids: Array) -> bool:
	return not file_ids.is_empty() and missing_on(server_id, file_ids).is_empty()


func present_on(server_id: String) -> Array[String]:
	var out: Array[String] = []
	for file_id in _order:
		if is_present(server_id, file_id):
			out.append(file_id)
	return out


func workers_with(file_id: String) -> Array[String]:
	var per_file: Dictionary = _locations.get(file_id.to_lower(), {})
	var out: Array[String] = []
	for server_id in per_file.keys():
		if int(per_file[server_id]) == State.PRESENT:
			out.append(str(server_id))
	return out


## Nach einem Netzbruch (oder Neustart) kann der Controller nicht wissen, was
## der Worker hat. Der Worker meldet seine Bestandsliste (`file_have`); diese
## **ersetzt** den bisherigen Stand fuer diesen Rechner.
##
## Wichtig: erst alles auf UNKNOWN setzen. Sonst bliebe eine Datei als
## vorhanden markiert, die der Worker beim Start aus Platzgruenden geloescht
## hat - der Transfer wuerde uebersprungen und die Aufgabe am Ende scheitern.
func sync_from_worker(server_id: String, present: Array) -> int:
	var listed: Dictionary = {}
	for file_id in present:
		listed[str(file_id).to_lower()] = true
	var known := 0
	for file_id in _files.keys():
		if listed.has(file_id):
			mark(server_id, file_id, State.PRESENT)
			known += 1
		elif state_on(server_id, file_id) == State.PRESENT \
				or state_on(server_id, file_id) == State.TRANSFERRING \
				or state_on(server_id, file_id) == State.VERIFYING:
			mark(server_id, file_id, State.UNKNOWN)
	return known


func forget_worker(server_id: String) -> void:
	for file_id in _locations.keys():
		var per_file: Dictionary = _locations[file_id]
		if per_file.erase(server_id):
			location_changed.emit(str(file_id), server_id, State.UNKNOWN)


func remove_file(file_id: String) -> bool:
	var key := file_id.to_lower()
	if not _files.erase(key):
		return false
	_locations.erase(key)
	_order.erase(key)
	return true


func reset() -> void:
	_files.clear()
	_locations.clear()
	_order.clear()


# ---------------------------------------------------------------- Darstellung
func describe(file_id: String) -> Dictionary:
	var info := get_file(file_id)
	if info.is_empty():
		return {}
	var per_file: Dictionary = _locations.get(file_id.to_lower(), {})
	var locations: Array = []
	for server_id in per_file.keys():
		locations.append({
			"server_id": str(server_id),
			"state": int(per_file[server_id]),
			"state_text": state_text(int(per_file[server_id])),
		})
	info["locations"] = locations
	return info


func describe_all() -> Array:
	var out: Array = []
	for file_id in _order:
		out.append(describe(file_id))
	return out


func summary() -> Dictionary:
	var present := 0
	var transferring := 0
	for file_id in _order:
		var per_file: Dictionary = _locations.get(file_id, {})
		for server_id in per_file.keys():
			match int(per_file[server_id]):
				State.PRESENT:
					present += 1
				State.TRANSFERRING, State.VERIFYING:
					transferring += 1
	return {
		"files": _order.size(),
		"present_locations": present,
		"transferring": transferring,
	}


static func state_text(state: int) -> String:
	match state:
		State.TRANSFERRING:
			return "TRANSFERRING"
		State.VERIFYING:
			return "VERIFYING"
		State.PRESENT:
			return "PRESENT"
		State.FAILED:
			return "FAILED"
		State.CANCELLED:
			return "CANCELLED"
	return "UNKNOWN"
