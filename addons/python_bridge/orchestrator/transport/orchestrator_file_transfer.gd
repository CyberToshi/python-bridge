class_name OrchestratorFileTransfer
extends RefCounted
## Chunked Datei-Uebertragung zum Worker (Phase 7, §13/§14).
##
## Eine grosse Datei wird **nicht** als eine riesige Nachricht geschickt, sondern
## in Stuecken. Der Worker haengt die Stuecke an eine temporaere Datei, prueft am
## Ende den **SHA-256** und benennt sie erst dann um (Atomaritaet).
##
##      Controller                          Worker
##      file_begin  ───────────────────────►  ok / have
##      file_chunk (0..n) ─────────────────►  schreiben
##      file_end    ───────────────────────►  SHA-256 pruefen → verified
##
## Enthalten sind: Fortschritt, Timeout pro Stueck, Wiederholung, Abbruch,
## Verifikation und die Regel "Datei schon da → kein Transfer" (§12).

signal transfer_progress(server_id: String, file_id: String, sent: int, total: int)
signal transfer_finished(server_id: String, file_id: String, ok: bool, reason: String)
## Alle Dateien einer Aufgabe liegen (verifiziert) auf dem Server.
signal task_files_ready(task_id: String)
## Die Dateien einer Aufgabe konnten nicht bereitgestellt werden. Die Aufgabe
## wird daraufhin neu bewertet (nicht stillschweigend verloren, §9).
signal task_data_failed(task_id: String, server_id: String, reason: String)

const CHUNK_SIZE := 256 * 1024
## Harte Obergrenze pro Datei - schuetzt Worker-Platte und Speicher.
const MAX_FILE_BYTES := 512 * 1024 * 1024
## Gleichzeitige Transfers (Bandbreite und Uebersicht schonen).
const MAX_ACTIVE := 1
const CHUNK_TIMEOUT_MS := 20000
const MAX_CHUNK_RETRIES := 3
const MAX_FILE_RETRIES := 2

var registry: OrchestratorFileRegistry

var _send: Callable = Callable()
var _transfers: Dictionary = {}      # transfer_id -> record
var _order: Array[String] = []
var _waiting: Dictionary = {}        # task_id -> {server_id, files: Array, done: int}
var _counter := 0


func _init(p_registry: OrchestratorFileRegistry = null) -> void:
	registry = p_registry if p_registry != null else OrchestratorFileRegistry.new()


## Wie Nachrichten zum Worker kommen (der Transport reicht seine Sende-Funktion
## herein). Ohne Sender macht diese Klasse gar nichts.
func set_sender(sender: Callable) -> void:
	_send = sender


# ---------------------------------------------------------------- Auftraege
## Startet alle fehlenden Dateien einer Aufgabe zum Zielserver.
## Liefert die IDs der gestarteten Transfers.
func request_files(task_id: String, server_id: String, file_ids: Array) -> Array[String]:
	var started: Array[String] = []
	if registry == null or server_id == "" or file_ids.is_empty():
		return started
	var missing := registry.missing_on(server_id, file_ids)
	if missing.is_empty():
		# Alles schon da - Aufgabe darf sofort weiter.
		call_deferred("_complete_task", task_id)
		return started
	_waiting[task_id] = {
		"server_id": server_id,
		"files": file_ids.duplicate(),
		"done": 0,
	}
	for file_id in missing:
		var transfer_id := _start_transfer(task_id, server_id, file_id)
		if transfer_id != "":
			started.append(transfer_id)
	return started


func cancel_task(task_id: String) -> void:
	for transfer_id in _order.duplicate():
		var record: Dictionary = _transfers.get(transfer_id, {})
		if str(record.get("task_id", "")) == task_id:
			_cancel_transfer(transfer_id, "Aufgabe abgebrochen")
	_waiting.erase(task_id)


func cancel_transfer(transfer_id: String) -> bool:
	if not _transfers.has(transfer_id):
		return false
	_cancel_transfer(transfer_id, "Transfer abgebrochen")
	return true


## Alle Transfers zu einem Rechner verwerfen (Verbindung weg). Ohne das wuerde
## der Transfer nur in seinen Timeout laufen, obwohl die Ursache schon bekannt
## ist - und die Aufgabe damit unnoetig lange warten.
func cancel_server(server_id: String) -> int:
	var stopped := 0
	for transfer_id in _order.duplicate():
		var record: Dictionary = _transfers.get(transfer_id, {})
		if str(record.get("server_id", "")) != server_id:
			continue
		_cancel_transfer(transfer_id, "Verbindung zu %s verloren" % server_id)
		stopped += 1
	for task_id in _waiting.keys().duplicate():
		var waiting: Dictionary = _waiting[task_id]
		if str(waiting.get("server_id", "")) != server_id:
			continue
		_waiting.erase(task_id)
		task_data_failed.emit(str(task_id), server_id,
			"Verbindung zu %s verloren" % server_id)
	return stopped


func is_waiting_for(task_id: String) -> bool:
	return _waiting.has(task_id)


func active_count() -> int:
	return _transfers.size()


func stats() -> Dictionary:
	var bytes := 0
	for transfer_id in _order:
		bytes += int((_transfers.get(transfer_id, {}) as Dictionary).get("sent_bytes", 0))
	return {
		"active": _transfers.size(),
		"waiting_tasks": _waiting.size(),
		"bytes_in_flight": bytes,
	}


# ---------------------------------------------------------------- Nachrichten
## Verarbeitet Worker-Antworten. Liefert true, wenn die Nachricht hierher gehoerte.
func on_message(server_id: String, message: Dictionary) -> bool:
	var kind := str(message.get("t", ""))
	match kind:
		"file_ack":
			return _on_file_ack(server_id, message)
		"file_have":
			var present: Variant = message.get("file_ids", [])
			if present is Array and registry != null:
				registry.sync_from_worker(server_id, present)
			return true
	return false


func _on_file_ack(server_id: String, message: Dictionary) -> bool:
	var transfer_id := str(message.get("transfer_id", ""))
	var record: Dictionary = _transfers.get(transfer_id, {})
	if record.is_empty() or str(record.get("server_id", "")) != server_id:
		return false
	var state := str(message.get("state", ""))
	match state:
		"have":
			# Der Worker hatte die Datei schon: kein Transfer, sofort fertig.
			_finish_transfer(transfer_id, true, "auf dem Worker bereits vorhanden")
		"accepted":
			record["awaiting_ms"] = 0
		"chunk_ok":
			record["awaiting_ms"] = 0
			_send_next_chunks(transfer_id)
		"verified":
			_finish_transfer(transfer_id, true, "verifiziert")
		"hash_failed":
			# Inhalt kaputt: komplette Datei erneut senden (begrenzt).
			var retries := int(record.get("file_retry", 0)) + 1
			record["file_retry"] = retries
			if retries > MAX_FILE_RETRIES:
				_finish_transfer(transfer_id, false,
					"Pruefsumme stimmt nicht (SHA-256) - Datei konnte nicht korrekt uebertragen werden")
			else:
				_transfers.erase(transfer_id)
				_order.erase(transfer_id)
				# Versuchszaehler mitnehmen: das neue Transfer-Objekt startet sonst
				# wieder bei 0 und die Grenze wuerde nie erreicht (Endlosschleife).
				_start_transfer(str(record.get("task_id", "")), server_id,
					str(record.get("file_id", "")), retries)
		"rejected":
			_finish_transfer(transfer_id, false,
				str(message.get("reason", "Worker hat den Empfang abgelehnt")))
		_:
			return true
	return true


# ---------------------------------------------------------------- Intern
func _start_transfer(task_id: String, server_id: String, file_id: String,
		file_retry := 0) -> String:
	if registry == null or not registry.has(file_id):
		return ""
	if _transfers.size() >= 64:
		_fail_task(task_id, "zu viele gleichzeitige Transfers")
		return ""
	var info := registry.get_file(file_id)
	var size := int(info.get("size", 0))
	if size > MAX_FILE_BYTES:
		_fail_task(task_id, "Datei '%s' ist zu gross (%.1f MB, Limit %.1f MB)" % [
			str(info.get("name", file_id)), size / 1048576.0, MAX_FILE_BYTES / 1048576.0])
		return ""
	var path := str(info.get("source_path", ""))
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		# Quelle verschwunden: Ursache nennen statt raten.
		_fail_task(task_id, "Datei '%s' ist am Hauptrechner nicht mehr lesbar" % path)
		return ""
	_counter += 1
	var transfer_id := "t-%d-%d" % [Time.get_ticks_msec(), _counter]
	_transfers[transfer_id] = {
		"transfer_id": transfer_id,
		"task_id": task_id,
		"server_id": server_id,
		"file_id": file_id,
		"name": str(info.get("name", file_id)),
		"sha256": str(info.get("sha256", file_id)),
		"size": size,
		"file": file,
		"sent_bytes": 0,
		"next_index": 0,
		"file_retry": file_retry,
		"chunk_retry": 0,
		"awaiting_ms": 0,
		"sent_end": false,
		"done": false,
	}
	_order.append(transfer_id)
	if registry != null:
		registry.mark(server_id, file_id, OrchestratorFileRegistry.State.TRANSFERRING)
	var sent := _send_payload(server_id, {
		"t": "file_begin",
		"transfer_id": transfer_id,
		"file_id": file_id,
		"name": str(info.get("name", file_id)),
		"size": size,
		"sha256": str(info.get("sha256", file_id)),
	})
	if not sent:
		_finish_transfer(transfer_id, false, "keine Verbindung zum Worker")
		return transfer_id
	# Nach der Anmeldung wird auf die Antwort des Workers gewartet. Ohne diese
	# Markierung wuerde `poll()` sofort ein erstes Stueck schicken - auch wenn
	# der Worker die Anmeldung noch gar nicht beantwortet hat (moegliche
	# Doppelsendung).
	var record: Dictionary = _transfers.get(transfer_id, {})
	if not record.is_empty():
		record["awaiting_ms"] = Time.get_ticks_msec()
	return transfer_id


## Pro Aufruf hoechstens ein Stueck: der Transport bleibt bei mehreren Transfers
## fair und der Speicherbedarf klein.
func _send_next_chunks(transfer_id: String) -> void:
	var record: Dictionary = _transfers.get(transfer_id, {})
	if record.is_empty() or bool(record.get("done", false)):
		return
	if int(record.get("awaiting_ms", 0)) != 0:
		return # wartet noch auf die Bestaetigung des letzten Stuecks
	if _transfers.size() > MAX_ACTIVE and _order.find(transfer_id) > 0:
		return
	var file := record.get("file", null) as FileAccess
	if file == null:
		_finish_transfer(transfer_id, false, "Quelldatei nicht mehr offen")
		return
	var index := int(record["next_index"])
	var size := int(record["size"])
	var server_id := str(record["server_id"])
	if index * CHUNK_SIZE >= size:
		# Nur einmal abschliessen: sonst koennte dasselbe `file_end` erneut
		# gesendet werden und der Worker hat dafuer keinen laufenden Transfer
		# mehr (-> unnoetiger Fehlversuch).
		if bool(record.get("sent_end", false)):
			return
		record["sent_end"] = true
		_send_payload(server_id, {
			"t": "file_end",
			"transfer_id": transfer_id,
			"sha256": str(record["sha256"]),
		})
		record["awaiting_ms"] = Time.get_ticks_msec()
		if registry != null:
			registry.mark(server_id, str(record["file_id"]),
				OrchestratorFileRegistry.State.VERIFYING)
		return
	file.seek(index * CHUNK_SIZE)
	var wanted := mini(CHUNK_SIZE, size - index * CHUNK_SIZE)
	var bytes := file.get_buffer(wanted)
	var ok := _send_payload(server_id, {
		"t": "file_chunk",
		"transfer_id": transfer_id,
		"index": index,
		"data": Marshalls.raw_to_base64(bytes),
	})
	if not ok:
		_finish_transfer(transfer_id, false, "Verbindung waehrend der Uebertragung verloren")
		return
	record["next_index"] = index + 1
	record["sent_bytes"] = index * CHUNK_SIZE + bytes.size()
	record["awaiting_ms"] = Time.get_ticks_msec()
	record["chunk_retry"] = 0
	transfer_progress.emit(server_id, str(record["file_id"]),
		int(record["sent_bytes"]), size)


## Regelmaessig aufrufen: schickt weiter und erkennt haengende Stuecke.
func poll(now_ms: int = -1) -> void:
	var now := now_ms if now_ms >= 0 else Time.get_ticks_msec()
	for transfer_id in _order.duplicate():
		var record: Dictionary = _transfers.get(transfer_id, {})
		if record.is_empty() or bool(record.get("done", false)):
			continue
		var awaiting := int(record.get("awaiting_ms", 0))
		if awaiting == 0:
			_send_next_chunks(transfer_id)
			continue
		if now - awaiting < CHUNK_TIMEOUT_MS:
			continue
		# Keine Antwort: Stueck erneut senden (begrenzt), sonst sauber scheitern.
		var retry := int(record.get("chunk_retry", 0)) + 1
		record["chunk_retry"] = retry
		record["awaiting_ms"] = 0
		if retry > MAX_CHUNK_RETRIES:
			_finish_transfer(transfer_id, false,
				"Zeitueberschreitung bei der Uebertragung (%d Versuche)" % MAX_CHUNK_RETRIES)
			continue
		if bool(record.get("sent_end", false)):
			# Der Abschluss war schon raus: nur ihn wiederholen, kein Stueck
			# doppelt senden (der Worker wuerde es ablehnen).
			record["sent_end"] = false
		else:
			record["next_index"] = maxi(int(record["next_index"]) - 1, 0)
			record["sent_bytes"] = int(record["next_index"]) * CHUNK_SIZE
		_send_next_chunks(transfer_id)


func _send_payload(server_id: String, payload: Dictionary) -> bool:
	if not _send.is_valid():
		return false
	return bool(_send.call(server_id, payload))


func _cancel_transfer(transfer_id: String, reason: String) -> void:
	var record: Dictionary = _transfers.get(transfer_id, {})
	if record.is_empty():
		return
	var server_id := str(record.get("server_id", ""))
	var file_id := str(record.get("file_id", ""))
	_send_payload(server_id, {"t": "file_abort", "transfer_id": transfer_id})
	_close(record)
	_transfers.erase(transfer_id)
	_order.erase(transfer_id)
	if registry != null and file_id != "":
		registry.mark(server_id, file_id, OrchestratorFileRegistry.State.CANCELLED)
	transfer_finished.emit(server_id, file_id, false, reason)


func _finish_transfer(transfer_id: String, ok: bool, reason: String) -> void:
	var record: Dictionary = _transfers.get(transfer_id, {})
	if record.is_empty() or bool(record.get("done", false)):
		return
	record["done"] = true
	var server_id := str(record.get("server_id", ""))
	var file_id := str(record.get("file_id", ""))
	var task_id := str(record.get("task_id", ""))
	_close(record)
	_transfers.erase(transfer_id)
	_order.erase(transfer_id)
	if registry != null and file_id != "":
		registry.mark(server_id, file_id,
			OrchestratorFileRegistry.State.PRESENT if ok
			else OrchestratorFileRegistry.State.FAILED)
	transfer_finished.emit(server_id, file_id, ok, reason)
	if ok:
		_note_file_done(task_id, server_id, file_id)
	elif _waiting.erase(task_id):
		task_data_failed.emit(task_id, server_id, reason)


func _close(record: Dictionary) -> void:
	var file := record.get("file", null) as FileAccess
	if file != null:
		file.close()


func _note_file_done(task_id: String, server_id: String, _file_id: String) -> void:
	if task_id == "" or not _waiting.has(task_id):
		return
	var waiting: Dictionary = _waiting[task_id]
	if str(waiting.get("server_id", "")) != server_id:
		return
	if registry == null or not registry.all_present(server_id, waiting.get("files", [])):
		return
	_waiting.erase(task_id)
	task_files_ready.emit(task_id)


func _complete_task(task_id: String) -> void:
	_waiting.erase(task_id)
	task_files_ready.emit(task_id)


func _fail_task(task_id: String, reason: String) -> void:
	if not _waiting.has(task_id):
		transfer_finished.emit("", "", false, "%s (Aufgabe %s)" % [reason, task_id])
		return
	var waiting: Dictionary = _waiting[task_id]
	var server_id := str(waiting.get("server_id", ""))
	_waiting.erase(task_id)
	task_data_failed.emit(task_id, server_id, reason)


func reset() -> void:
	for transfer_id in _order.duplicate():
		_close(_transfers.get(transfer_id, {}))
	_transfers.clear()
	_order.clear()
	_waiting.clear()
