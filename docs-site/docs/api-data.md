---
sidebar_position: 11
title: Daten & Serialisierung
description: Referenz zu DataRef, DataFile, Serializer, Type Mapper und dem Draht-Protokoll.
---

# Daten & Serialisierung

Diese Seite erklärt die Datenebene auf Klassenebene. Die **Anwendung**
(DataRefs nutzen, Typen verstehen) steht in
[Daten, Typen & große Datensätze](./datenebene).

## PythonBridgeDataRef

`core/data_ref.gd` – leichtgewichtiges **Handle** auf einen großen Datensatz,
der im Python-Prozess liegt. Ein `data_ref`-Descriptor aus Python dekodiert
zu genau diesem Objekt, **nicht** zu den Daten selbst.

### Felder

| Feld | Typ | Bedeutung |
|---|---|---|
| `data_id` | `String` | Server-seitige Handle-ID |
| `kind` | `String` | Art des Datensatzes, z. B. `ndarray` |
| `dtype` | `String` | Elementtyp, z. B. `float32`, `int64` |
| `shape` | `Array` | Form, z. B. `[5000000, 3]` |
| `nbytes` | `int` | Größe in Bytes |
| `readonly` | `bool` | Ob der Datensatz nur gelesen werden darf |
| `descriptor` | `Dictionary` | Vollständiger Original-Descriptor |
| `instance_name` | `String` | Instanz-Zuordnung (wird beim Tracking gesetzt) |

### Methoden

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `from_descriptor(desc: Dictionary)` *(statisch)* | `PythonBridgeDataRef` | Baut einen Handle aus einem `data_ref`-Descriptor |
| `describe()` | `Dictionary` | `{id, kind, dtype, shape, nbytes, readonly, instance, stale}` |
| `is_stale()` | `bool` | `true`, wenn die Instanz endete oder freigegeben wurde |
| `mark_stale()` | `void` | Markiert den Handle als ungültig (Bridge-intern) |
| `_to_string()` | `String` | Lesbare Kurzdarstellung fürs Debugging |

**Lifecycle:** Nach Instanz-Stop/Crash sind alle Handles dieser Instanz
stale. `materialize_data` liefert dann einen strukturierten Fehler;
`is_stale()` erlaubt die frühe Prüfung ohne Roundtrip.

## PythonBridgeDataFile

`core/data_file.gd` – **Datei-basierte** Materialisierung großer DataRefs.
Statt Rohbytes über den WebSocket zu schicken, legt der Python-Server die
Daten als Datei ab; Godot liest sie chunkweise und verifiziert Größe und
(SHA-256-)Prüfsumme.

| Konstante | Wert | Bedeutung |
|---|---|---|
| `CHUNK_SIZE` | `1 MiB` | Maximale Bytes pro `FileAccess`-Read |

### `read_chunked(path, budget_bytes, expected_bytes, sha256 := "") -> Dictionary` *(statisch, ⏳)*

Liest die Datei chunkweise. `budget_bytes` begrenzt die Bytes **pro Frame**;
der Rest wird in Folge-Frames gelesen, der Main-Thread bleibt frei.
Rückgabe: `{"ok": bool, "data": PackedByteArray, "error": String}`.

Fehlerfälle: Datei nicht öffenbar, Größen-Mismatch
(`expected_bytes`), vorzeitiges EOF, SHA-256-Mismatch.

### `decode_bytes(data, dtype, shape) -> Variant` *(statisch)*

Dekodiert die Rohbytes über den Standard-Serializer in den Zieltyp:
typisierte Packed-Arrays für numpy, bei mehrdimensionalen Shapes ein Array
von Zeilen. Nutzt den `ndarray`-Pfad inkl. `nbytes`-Validierung.

## PythonBridgeSerializer

`core/serializer.gd` – der zentrale, transparente und erweiterbare
Serializer. Skalare bleiben lesbare JSON-Werte; strukturierte Werte werden
als getaggte Objekte `{"$pb": "<tag>", …}` kodiert. Große Binärblöcke
landen im `chunks`-Puffer der Nachricht statt als Base64 im JSON-Header.

| Konstante | Wert | Bedeutung |
|---|---|---|
| `TAG` | `"$pb"` | Schlüssel, der ein getaggtes Objekt markiert |
| `INLINE_LIMIT` | `512` | Bis hierhin inline (Base64/JSON-Liste), darüber Binär-Chunk |

### `encode(v: Variant, chunks: Array) -> Variant` *(statisch)*

Godot → typisierte Darstellung. Hängt große Blobs an `chunks` an. Numerische
Packed-Arrays bis `INLINE_LIMIT` bleiben JSON-Zahlenlisten; größere werden
per `encode_s32`/`encode_s64`/`encode_float`/`encode_double` als
Little-Endian-Rohbytes in den Chunk-Stream gelegt. Unbekannte `Object`-Typen
werden über die Custom-Registry des `PythonBridgeTypeMapper` geroutet, sonst
als `{"$pb": "unsupported", "type": …}` markiert.

### `decode(v: Variant, chunks: Array) -> Variant` *(statisch)*

Typisierte Darstellung → Godot. Versteht alle Tags (siehe unten), validiert
`nbytes` bei numerischen Chunks und rekonstruiert `ndarray`-Shapes
(1-D → Packed-Array, >1-D → Array von Zeilen). Unbekannte Tags werden an die
Custom-Registry delegiert, sonst `null`.

## PythonBridgeTypeMapper

`core/type_mapper.gd` – die **einzige Quelle der `$pb`-Tags** und die
Basis der Typ-Mapping-Tabelle. Custom-Typen können zur Laufzeit ergänzt
werden, ohne den Kern zu ändern.

### Tags

`T_NULL`, `T_BOOL`, `T_INT`, `T_FLOAT`, `T_STR`, `T_VEC2`, `T_VEC3`,
`T_VEC4`, `T_COLOR`, `T_TRANSFORM3D`, `T_ARR`, `T_DICT`, `T_TUPLE`,
`T_SET`, `T_BYTES`, `T_I8`, `T_U8`, `T_I16`, `T_U16`, `T_I32`, `T_U32`,
`T_I64`, `T_U64`, `T_F32`, `T_F64`, `T_NDARRAY`, `T_IMAGE`, `T_PYOBJECT`,
`T_UNSUPPORTED`, `TAG` (`"$pb"`).

Die vollständige Zuordnung Godot ↔ Python steht in
[Daten, Typen & große Datensätze](./datenebene); die Konstante `MAPPINGS`
enthält dieselbe Tabelle maschinenlesbar als `Array[Dictionary]` mit
`{tag, godot, python}`.

### Methoden

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `register(tag, encode_fn, decode_fn, custom_class := "")` *(statisch)* | `void` | Registriert einen Tag mit Encode-/Decode-Callable; `custom_class` routet `Object`-Werte dieser Klasse automatisch |
| `unregister(tag)` *(statisch)* | `bool` | Entfernt einen Tag (`true`, wenn er existierte) |
| `has_custom(tag)` *(statisch)* | `bool` | Ob ein Custom-Tag registriert ist |
| `custom_tags()` *(statisch)* | `Array` | Alle registrierten Custom-Tags |
| `custom_encode(tag)` *(statisch)* | `Callable` | Encode-Funktion oder leeres `Callable` |
| `custom_decode(tag)` *(statisch)* | `Callable` | Decode-Funktion oder leeres `Callable` |
| `tag_for_value(value)` *(statisch)* | `String` | Tag, dessen `custom_class` zur Klasse passt, sonst `""` |
| `info_for_tag(tag)` *(statisch)* | `Dictionary` | Mapping-Eintrag `{tag, godot, python}` oder `{}` |

```gdscript
PythonBridgeTypeMapper.register(
    "mytype",
    func(value, chunks): return {"$pb": "mytype", "v": value.to_dict()},
    func(encoded, chunks): return MyType.from_dict(encoded["v"]),
    "MyType")
```

## PythonProtocol

`core/protocol.gd` – das versionierte Draht-Protokoll (Version **2**). Ein
WebSocket-Frame entspricht einer Nachricht. Textframes sind reines JSON;
Binaryframes haben den Aufbau
`U32LE(Headerlänge) + HeaderJSON(utf8) + [U32LE(Chunklänge) + Chunk]*`.
Große Binär-Payloads reisen **nie** im JSON-Header, sondern als Chunks.

### Nachrichtentypen (Konstanten)

| Konstante | Wert | Richtung / Zweck |
|---|---|---|
| `MSG_HELLO` / `MSG_HELLO_ACK` | `hello` / `hello_ack` | Handshake beim Verbinden |
| `MSG_TASK` | `task` | Einzelner Task (`run`/`call`/`define`) |
| `MSG_TASK_RESULT` / `MSG_TASK_ERROR` | `task_result` / `task_error` | Ergebnis/Fehler |
| `MSG_BATCH` / `MSG_BATCH_RESULT` | `batch` / `batch_result` | Mehrere Tasks in einem Frame |
| `MSG_CANCEL` / `MSG_CANCEL_ACK` | `cancel` / `cancel_ack` | Abbruch |
| `MSG_PING` / `MSG_PONG` | `ping` / `pong` | Health-Check |
| `MSG_RELOAD` / `MSG_RELOAD_ACK` | `reload` / `reload_ack` | Hot Reload |
| `MSG_INTROSPECT` / `MSG_INTROSPECT_RESULT` | `introspect` / `introspect_result` | AST-Signaturen |
| `MSG_DATA_GET` / `MSG_DATA_RESULT` | `data_get` / `data_result` | DataRef materialisieren |
| `MSG_DATA_RELEASE` / `MSG_DATA_ACK` | `data_release` / `data_ack` | DataRef freigeben |
| `MSG_STATUS` / `MSG_EVENT` | `status` / `event` | Statusmeldung / Event an Godot |
| `MSG_SHUTDOWN` / `MSG_SHUTDOWN_ACK` | `shutdown` / `shutdown_ack` | Geordnetes Beenden |

Zusätzlich: `PROTOCOL_VERSION` (`2`), die Kommandos `CMD_RUN`, `CMD_CALL`,
`CMD_DEFINE` und `FIELD_ITEMS` (`"items"`, die Item-Liste von Batches).

### Methoden

#### `build_frame(msg: Dictionary, external_chunks := []) -> Dictionary` *(statisch)*

Baut einen kompletten Frame. Serialisiert `data` (und `data` innerhalb von
Batch-Items) über den Type Mapper und sammelt Binär-Chunks. Rückgabe
`{"text": String}` **oder** `{"binary": PackedByteArray}`. Bereits getaggte
Werte (`$pb`) werden **nicht** erneut kodiert – das würde einen
Chunk-Verweis verwaisen lassen.

#### `parse_frame(pkt: Variant) -> Dictionary` *(statisch)*

Parst einen String- oder `PackedByteArray`-Frame. Rückgabe
`{"msg": Dictionary, "data": Variant}` mit bereits dekodierten `data`-Feldern
(auch in Batch-Items). Fehlerhafter Input liefert eine leere `msg`.

#### `response_envelope(msg_type, id, status, data := null, error := {}, ms := 0) -> Dictionary` *(statisch)*

Baut eine `task_result`/`task_error`-Hülle. Bei `status == "ok"` wird `data`
gesetzt, sonst `error`.

---

Verwandt: [Daten, Typen & große Datensätze](./datenebene) ·
[API-Überblick & Facade](./api) · [Kern-Komponenten](./api-internals)
