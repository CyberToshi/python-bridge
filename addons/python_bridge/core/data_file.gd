class_name PythonBridgeDataFile
extends RefCounted
## Datei-basierte Materialisierung grosser DataRefs (Phase 4).
##
## Statt grosse Datensaetze ueber den WebSocket zu schicken, legt der
## Python-Server die Rohbytes einer DataRef zusaetzlich als Datei ab (siehe
## python_bridge/data_registry.py). Godot liest diese Datei chunkweise mit
## FileAccess - innerhalb eines Frame-Budgets, damit der Main-Thread durch
## einen grossen Datensatz nicht blockiert wird - und verifiziert Groesse
## sowie optional den sha256-Prüfsumme. Erst am Ende wird in den gewuenschten
## Godot-Typ dekodiert (ueber den Standard-Serializer, inkl. nbytes-
## Validierung).

const CHUNK_SIZE := 1024 * 1024   # max. Bytes pro FileAccess-Read

## Liest eine Daten-Datei chunkweise. `budget_bytes` begrenzt die gelesenen
## Bytes pro Frame; uebrige Daten werden in Folge-Frames gelesen. Verifiziert
## Groesse und - wenn `sha256` gesetzt ist - die Pruefsumme.
## Liefert {"ok": bool, "data": PackedByteArray, "error": String}.
static func read_chunked(path: String, budget_bytes: int, expected_bytes: int, sha256 := "") -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "Cannot open data file: " + path}
	var total := f.get_length()
	if expected_bytes > 0 and total != expected_bytes:
		f.close()
		return {"ok": false, "error": "Data file size mismatch: expected %d bytes, got %d" % [expected_bytes, total]}
	var out := PackedByteArray()
	var hasher: HashingContext = null
	if sha256 != "":
		hasher = HashingContext.new()
		hasher.start(HashingContext.HASH_SHA256)
	var pos := 0
	var read_this_pass := 0
	while pos < total:
		var chunk_size := mini(CHUNK_SIZE, total - pos)
		if read_this_pass > 0 and read_this_pass + chunk_size > budget_bytes:
			await _frame() # Budget erreicht: Rest im naechsten Frame lesen
			read_this_pass = 0
		var chunk := f.get_buffer(chunk_size)
		if chunk.size() == 0:
			break # unerwartetes EOF
		out.append_array(chunk)
		if hasher != null:
			hasher.update(chunk)
		pos += chunk.size()
		read_this_pass += chunk.size()
	f.close()
	if pos != total:
		return {"ok": false, "error": "Data file truncated: read %d of %d bytes" % [pos, total]}
	if hasher != null:
		var digest := hasher.finish().hex_encode()
		if digest != sha256:
			return {"ok": false, "error": "Data file checksum mismatch (sha256)"}
	return {"ok": true, "data": out}

## Dekodiert die gelesenen Rohbytes ueber den Standard-Serializer in den
## gewuenschten Godot-Typ (typisierte Arrays fuer numpy, Array von Zeilen bei
## 2D-Shapes). Nutzt den ndarray-Pfad inkl. nbytes-Validierung.
static func decode_bytes(data: PackedByteArray, dtype: String, shape: Array) -> Variant:
	return PythonBridgeSerializer.decode({
		PythonBridgeSerializer.TAG: "ndarray",
		"chunk": 0,
		"dtype": dtype,
		"shape": shape,
		"nbytes": data.size(),
	}, [data])

static func _frame() -> void:
	var loop := Engine.get_main_loop()
	if loop != null:
		await loop.process_frame