class_name PBTestBridgeSync
extends PBTests
## Tests fuer die Web-/Sync-Schicht der Facade - ohne laufende Instanz.
##
## Warum: Im Browser sieht Python nur sein eigenes MEMFS. Skripte, die Godot
## schreibt, muessen ueber den einseitigen file_op-Kanal gespiegelt werden.
## Frueher wurden Ops verworfen, wenn noch keine Instanz bereit war - ein vor
## dem ersten Python-Start angelegtes Skript existierte im Pyodide-Workspace
## dann nie. Diese Suite pinnt die Puffer-Logik (letzte Op pro Pfad gewinnt,
## FIFO-Reihenfolge, Kapazitaetsgrenze) und die Nachrichtenform fest.

const PAGE := "res://addons/python_bridge/core/python_bridge.gd"

# Bewusst untypisiert: die Suite greift auf interne Felder zu, die Node nicht
# kennt (dynamischer Zugriff statt Compile-Fehler).
func _bridge(web := true):
	var b = (load(PAGE) as GDScript).new()
	b._settings["web_transport"] = web
	return b

func test_file_op_message_shape() -> void:
	var b = _bridge()
	var msg: Dictionary = b._file_op_message("write", "scripts/a.py", "x = 1\n")
	assert_eq(str(msg.get("type", "")), PythonProtocol.MSG_FILE_OP)
	assert_eq(str(msg.get("op", "")), "write")
	assert_eq(str(msg.get("path", "")), "scripts/a.py")
	assert_eq(str(msg.get("content", "")), "x = 1\n")
	assert_eq(int(msg.get("v", 0)), PythonProtocol.PROTOCOL_VERSION)
	assert_ne(str(msg.get("id", "")), "", "jede Op hat eine eigene Id")

func test_queue_is_empty_initially() -> void:
	assert_eq(_bridge()._pending_file_ops.size(), 0)

func test_send_without_ready_instance_is_buffered_in_web() -> void:
	var b = _bridge(true)
	b._send_file_op("write", "scripts/neu.py", "wert = 1\n")
	assert_eq(b._pending_file_ops.size(), 1, "im Web gepuffert statt verworfen")
	var entry: Dictionary = b._pending_file_ops["scripts/neu.py"]
	assert_eq(str(entry.get("op", "")), "write")
	assert_true(str(entry.get("content", "")).contains("wert"))

func test_send_without_ready_instance_is_dropped_on_desktop() -> void:
	# Desktop: Godot und Python sehen dieselbe Datei - kein Puffer noetig.
	var b = _bridge(false)
	b._send_file_op("write", "scripts/neu.py", "wert = 1\n")
	assert_eq(b._pending_file_ops.size(), 0, "Desktop puffert nicht")

func test_last_operation_per_path_wins() -> void:
	var b = _bridge()
	b._queue_file_op("write", "scripts/x.py", "v1")
	b._queue_file_op("write", "scripts/x.py", "v2")
	b._queue_file_op("delete", "scripts/x.py", "")
	assert_eq(b._pending_file_ops.size(), 1, "ein Eintrag pro Pfad")
	var entry: Dictionary = b._pending_file_ops["scripts/x.py"]
	assert_eq(str(entry.get("op", "")), "delete", "letzte Op gewinnt")
	assert_eq(str(entry.get("content", "")), "", "delete traegt keinen Inhalt")

func test_queue_keeps_insertion_order() -> void:
	var b = _bridge()
	b._queue_file_op("write", "scripts/a.py", "1")
	b._queue_file_op("write", "scripts/b.py", "2")
	b._queue_file_op("write", "scripts/c.py", "3")
	var keys: Array = b._pending_file_ops.keys()
	assert_eq(keys.size(), 3)
	assert_eq(str(keys[0]), "scripts/a.py", "FIFO-Reihenfolge bleibt erhalten")

func test_queue_is_bounded() -> void:
	var b = _bridge()
	var limit: int = b.MAX_PENDING_FILE_OPS
	for i in range(limit + 20):
		b._queue_file_op("write", "scripts/f%d.py" % i, str(i))
	assert_eq(b._pending_file_ops.size(), limit, "harte Obergrenze")
	assert_false(b._pending_file_ops.has("scripts/f0.py"), "aeltester Eintrag verworfen")
	assert_true(b._pending_file_ops.has("scripts/f%d.py" % (limit + 19)), "neuester bleibt")

func test_flush_without_ready_instance_keeps_queue() -> void:
	var b = _bridge()
	b._queue_file_op("write", "scripts/bleibt.py", "1")
	b._flush_pending_file_ops()
	assert_eq(b._pending_file_ops.size(), 1, "nichts verloren, solange nichts bereit ist")

func test_flush_without_ready_instance_keeps_queue_even_with_node_arg() -> void:
	var b = _bridge()
	b._queue_file_op("write", "scripts/bleibt.py", "1")
	b._flush_pending_file_ops(Node.new())
	assert_eq(b._pending_file_ops.size(), 1, "nicht bereite Instanzen zaehlen nicht")

func test_notify_deleted_forgets_cython_hash() -> void:
	# Ohne laufende Instanz darf notify_script_deleted weder crashen noch
	# schreiben - aber den Build-Hash des Stems leeren, damit ein neu
	# angelegtes Skript gleichen Namens nicht als "gebaut" gilt.
	var b = _bridge()
	b._script_registry = PythonBridgeScriptRegistry.new()
	b._cython_built_hash["mein_modul"] = "hash-alt"
	b.notify_script_deleted("mein_modul")
	assert_false(b._cython_built_hash.has("mein_modul"), "Build-Hash verworfen")

func test_notify_saved_survives_missing_file() -> void:
	var b = _bridge(true)
	b._script_registry = PythonBridgeScriptRegistry.new()
	b.notify_script_saved("gibt_es_nicht", "/tmp/gibt_es_nicht.py")
	assert_true(true, "kein Fehler ohne Datei/Instanz")
