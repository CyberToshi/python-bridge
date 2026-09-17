---
sidebar_position: 9
sidebar_label: API-Referenz
title: API-Referenz
description: Vollständige Referenz der PythonBridge-Facade, Klassen, Signale und Fehlercodes.
---

# API-Referenz

Diese Referenz beschreibt **jede öffentliche Funktion** des Addons – nur was
wirklich im Code existiert. Alle Beispiele sind GDScript.

## Überblick der Klassen

| Klasse | Rolle |
|---|---|
| `PythonBridge` (Autoload) | Zentrale Facade – Instanzen, Tasks, Skripte, Daten, Konfiguration |
| `PythonBridgeResult` | Ergebnis-/Fehlerbehälter jeder `await`-baren Operation |
| `PythonBridgeTask` | Eine Arbeitseinheit (für `submit_task`/Beobachtung) |
| `PythonBridgeDataRef` | Handle auf einen großen Datensatz |
| `PythonBridgeDataFile` | Dateibasierte Materialisierung großer DataRefs (intern) |
| `PythonBridgeConfig` | Konfigurations-Defaults und Normalisierung |
| `PythonBridgeErrorHandler` | Fehler-Taxonomie (`PYTHON_EXCEPTION`, …) |
| `PythonBridgeProtocol` | Draht-Protokoll-Nachrichten (Transparenz/Debug) |
| `PythonBridgeWrapperGenerator` | Wrapper-Generierung |

---

## PythonBridge – Facade

Der Autoload `PythonBridge` ist ein Node. **Asynchrone** Methoden (`await`)
sind mit ⏳ markiert; synchrone liefern sofort.

### Konfiguration & Zustand

#### `configure(cfg: Dictionary) -> void` *(synchron)*
Setzt die globale Konfiguration (merge über Defaults). **Vor** dem ersten
`start_instance()` aufrufen. Details: [Konfiguration](./konfiguration).

#### `config() -> Dictionary` *(synchron)*
Gibt eine Kopie der aktiven Konfiguration zurück.

#### `workspace_dir() -> String` *(synchron)*
Der aktive Workspace-Pfad (Default `res://python_bridge`).

#### `system() -> Node` *(statisch)*
Findet den Autoload zur Laufzeit: `PythonBridge.system()`.
Praktisch für Komponenten ohne feste Singleton-Referenz.

### Instanzen (Python-Prozesse)

#### `start_instance(instance_name := "default") -> PythonBridgeResult` ⏳
Startet (bzw. findet) eine Instanz. Liefert `ok`, sobald die Instanz
`ready` ist, sonst einen strukturierten Fehler (z. B. `DEPENDENCY_ERROR`,
wenn Python fehlt). Wiederholte Aufrufe sind idempotent.

```gdscript
var r: PythonBridgeResult = await PythonBridge.start_instance("default")
if r.is_error():
    push_error(r.error_message())
```

#### `instance_status(instance_name := "default") -> String` *(synchron)*
Status-Text der Instanz: `none`, `provisioning`, `starting`, `connecting`,
`handshake`, `ready`, `crashed`, `restarting`, `stopping`, `stopped`,
`error`.

#### `get_instance(instance_name := "default") -> BridgeInstance` *(synchron)*
Die Instanz als Node (fortgeschritten; normalerweise nicht nötig).

#### `stop_instance(instance_name := "default") -> void` *(synchron, non-blocking)*
Graceful Shutdown **einer** Instanz. Laufende/queued Tasks dieser Instanz
werden sauber als Fehler aufgelöst (`CONNECTION_ERROR`), der Prozess beendet
sich im Instanz-`tick`.

#### `stop_all() -> void` *(synchron, non-blocking)*
`stop_instance()` für alle Instanzen.

#### `shutdown() -> void` *(synchron, non-blocking)*
Blockiert neue Tasks und stoppt alle Instanzen (graceful). Aufruf ohne
`await` „feuert und vergisst“; ideal in `_exit_tree()`.

#### `shutdown_now() -> void` *(synchron)*
Sofortiger, erzwungener Stop aller Instanzen (Kill, keine Zombies). Für
`_exit_tree`/Editor-Trennung gedacht.

### Temporärer Python-Code

#### `execute(code: String, input := {}, instance := "default", timeout_sec := 30.0) -> PythonBridgeResult` ⏳
Führt Python-Code **einmalig** in einem frischen temporären Kontext aus
(`temp-N`). Im Code sind die Variablen `input` (dein Wert) und `result`
(von dir gesetzt) verfügbar:

```gdscript
var r: PythonBridgeResult = await PythonBridge.execute(
    "result = input[\"value\"] * 2", {"value": 21})
print(r.value)  # 42
```

`execute` ist **nicht batchbar** und wird bei jedem Aufruf neu ausgeführt.

### Dauerhafte Skripte (.py-Dateien)

Skript-IDs sind Dateinamen **ohne** `.py` (auch `unterordner/id` oder ein
voller Pfad möglich). Skripte liegen unter `<workspace>/scripts/`.

#### `create_script(script_id: String, code: String, subfolder := "") -> PythonBridgeResult` *(synchron)*
Schreibt `code` nach `<workspace>/scripts/[subfolder/]<id>.py` (legt Ordner
an) und verwirft den Lesecache. Liefert `{"path": …}`.

#### `get_script_source(script_id: String) -> String` *(synchron)*
Inhalt der Skriptdatei (leer, wenn nicht vorhanden). Der Editor-Dock nutzt
diese Funktion.

#### `call_script(script_id: String, function: String, args := [], kwargs := {}, instance := "default", timeout_sec := 30.0) -> PythonBridgeResult` ⏳
**Der häufigste Aufruf:** definiert den Python-Kontext des Skripts genau
dann neu, wenn sich der Inhalt geändert hat (Source-Hash), und ruft dann
`function(*args, **kwargs)` auf. Modul-Zustand bleibt zwischen Aufrufen
erhalten.

```gdscript
var r: PythonBridgeResult = await PythonBridge.call_script(
    "hello", "say_hello", ["Hello Python"])
```

#### `execute_script(script_id: String, input := {}, instance := "default", timeout_sec := 30.0) -> PythonBridgeResult` ⏳
Führt die Skriptdatei wie `execute` aus (`input`/`result`-Konvention), aber
im **persistenten Skript-Kontext**. Der Code läuft bei jedem Aufruf erneut –
Modul-Zustand bleibt im selben Kontext bestehen.

#### `define_script(script_id: String, instance := "default", timeout_sec := 30.0) -> PythonBridgeResult` ⏳
Führt das Skript **einmal** aus, ohne eine Funktion aufzurufen – z. B. zum
Vorbereiten/Initialisieren. Nachfolgende `call_script`-Aufrufe können dann
auf den bereits definierten Kontext zurückgreifen.

#### `introspect_script(script_id: String, instance := "default") -> PythonBridgeResult` ⏳
Fragt die Funktions-Signaturen eines Skripts ab (**AST-basiert, ohne das
Skript auszuführen**). Wert bei Erfolg: Array von
`{name, params, returns, docstring}` – Grundlage des Wrapper-Generators.
Benötigt eine `ready`-Instanz.

#### `hot_reload_script(script_id: String) -> PythonBridgeResult` ⏳
Übernimmt Änderungen am Skript gemäß `hot_reload_mode`. Liefert
`{"reloaded": bool, "mode": …}`. Godot-Zustand bleibt unangetastet; bei
`restart_instance` wird der Prozess neu gestartet.

### Low-Level-Tasks (fortgeschritten)

#### `submit_task(task: PythonBridgeTask) -> PythonBridgeResult` *(synchron)*
Reicht einen Task ein. Das **sofortige** Ergebnis sagt nur, ob der Task
angenommen wurde (Backpressure). Das **Endergebnis** kommt über
`await task.done` bzw. `task.result`:

```gdscript
var t := PythonBridgeTask.make_call("id-1", "script:/pfad.py", source,
    "add", [2, 3], {}, 30000)
var accepted := PythonBridge.submit_task(t)   # sofort
if accepted.is_ok():
    var end: PythonBridgeResult = await t.done # final
```

`PythonBridgeTask`-Felder: `id`, `instance_id` (`""` = Auto-Zuordnung),
`priority` (0 = höchste), `timeout_ms` (ab RUNNING), `args`, `kwargs`,
`input`, `function`, `context_id`, `batchable`, `cancel_requested`, … Die
statischen Builder `make_run`, `make_call`, `make_define` erzeugen passende
Tasks.

#### `cancel_task(task_id: String) -> bool` *(synchron)*
Bricht einen Task ab: queued Tasks werden entfernt; laufende werden markiert
(CANCEL an Python, kooperative Cancellation via `__bridge__`). Späte
Ergebnisse abgebrochener Tasks werden verworfen.

#### `get_task(task_id: String) -> PythonBridgeTask`
Liefert den Task (auch nach Abschluss für eine Weile). Terminale Tasks
werden nach ~60 s aus dem Speicher entfernt.

### Datenebene (DataRefs)

#### `materialize_data(ref: PythonBridgeDataRef, timeout_sec := 60.0) -> PythonBridgeResult` ⏳
Holt die Daten eines DataRef-Handles (binär-chunked bzw. dateibasiert) und
liefert sie als normalen Wert (typisierte Arrays, Bytes, …). Mehrfaches
Materialisieren ist erlaubt; stale/Released-Handles liefern einen
strukturierten Fehler.

#### `release_data(ref: PythonBridgeDataRef, timeout_sec := 10.0) -> PythonBridgeResult` ⏳
Gibt die Daten im Python-Prozess frei. Liefert
`{"released": bool, "ref_id": …}`; der Handle wird als `stale` markiert.
Nach Instanz-Ende ist `release_data` ein No-Op (Erfolg, `released=false`).

#### `describe_data(ref: PythonBridgeDataRef) -> PythonBridgeResult` *(synchron)*
Beschreibt den Handle ohne Roundtrip:
`{id, kind, dtype, shape, nbytes, readonly, instance, stale}`.

Mehr: [Große Daten (DataRefs)](./datenebene).

### Signale (Events)

| Signal | Parameter | Wann |
|---|---|---|
| `pulse` | – | Jeden Frame (interner Sync-Puls) |
| `instance_state_changed` | `instance: String, state: String` | Instanz-Zustandswechsel (z. B. `ready`, `crashed`) |
| `task_done` | `task: PythonBridgeTask` | Jeder Task erreicht einen Endzustand (beobachtbar) |
| `bridge_event` | `instance: String, event: Dictionary` | Python → Godot-Ereignisse |

```gdscript
func _ready() -> void:
    PythonBridge.task_done.connect(_on_task_done)

func _on_task_done(task: PythonBridgeTask) -> void:
    print("Task", task.id, "->", task.state_text(), task.result)
```

---

## PythonBridgeResult

Jede `await`-Operation liefert ein `PythonBridgeResult`.

| Member | Typ | Bedeutung |
|---|---|---|
| `ok` | bool | `true` = Erfolg |
| `status` | String | Legacy-Status: `ok`/`error`/`timeout`/`not_ready`/`down`/`internal`/`cancelled` |
| `value` | Variant | Ergebnis bei Erfolg |
| `error` | Dictionary | Strukturierter Fehler: `{code, type, message, traceback, task_id, instance_id}` |
| `request_id` | String | Interne Request-ID |
| `task_id` / `instance_id` | String | Zuordnung |
| `meta` | Dictionary | z. B. `{duration_ms, request_id, instance_id}` |

Methoden: `is_ok()`, `is_error()`, `error_code()` (aus `error.code`),
`error_message()`.

```gdscript
if r.is_ok():
    print(r.value)
else:
    print("Code:  ", r.error_code())
    print("Msg:   ", r.error_message())
    print("Type:  ", r.error.get("type", ""))
    print("Trace: ", r.error.get("traceback", ""))
```

:::note print() aus Python
`print()` in deinem Python-Code wird serverseitig erfasst (begrenzt durch
`max_stdout_bytes`), aber derzeit **nicht automatisch in die Godot-Konsole
durchgereicht**. Für sichtbare Ausgaben gibst du Werte per `return` zurück
und `print()`-est sie in GDScript, oder du liest das Log im Editor-Dock.
:::

---

## Fehlercodes (Taxonomie)

`error.code` ist stabil und für eigene Fehlerbehandlung gedacht:

| Code | Bedeutung | Legacy-`status` |
|---|---|---|
| `PYTHON_EXCEPTION` | Python-Ausnahme (Exception-Typ, Message, Traceback vorhanden) | `error` |
| `TASK_ERROR` | Task-Ebene: Queue voll, Payload zu groß, abgebrochen, stale Handle | `error` |
| `TIMEOUT_ERROR` | Antwort kam nicht rechtzeitig (Ausführungs-/Queue-Timeout) | `timeout` |
| `CONNECTION_ERROR` | WebSocket weg / Verbindungsfehler | `down` |
| `PROCESS_ERROR` | Python-Prozess beendet/abgestürzt | `down` |
| `DEPENDENCY_ERROR` | venv/pip/Import-Prüfung fehlgeschlagen | `internal` |
| `SERIALIZATION_ERROR` | Kodierung/Dekodierung, Datei-Prüfsumme, Ergebnis zu groß | `internal` |
| `PROTOCOL_ERROR` | Protokoll-/Hash-Verletzung | `internal` |
| `BRIDGE_ERROR` | Infrastrukturfehler (Skript fehlt, Instanz unbekannt, …) | `internal` |

Retry-Hinweis: Nur Verbindungs-/Prozessfehler sind gemäß `retry_policy`
retry-fähig; `PYTHON_EXCEPTION` niemals.

---

## Lifecycle eines Tasks (Kurzfassung)

```text
submit_task() / call_script() …
   │  angenommen? (Queue voll? Payload zu groß?)
   ▼
QUEUED ──(Slot frei)──► RUNNING ──Antwort──► COMPLETED
   │                        │                 │
   │ queue_timeout          │ execution       │
   ▼                        ▼ timeout         ▼
 FAILED/TIMEOUT         TIMEOUT          FAILED / CANCELLED
   (ggf. Retry)         (ggf. Watchdog → Neustart)
```

Antworten werden nie direkt aus einem Hintergrundthread in Nodes geschrieben:
Die Bridge puffert sie und arbeitet sie im Frame-Sync-Punkt mit Budget ab
(`max_results_per_frame`, `max_decode_bytes_per_frame`).

Weiterführend: [Python-Seite verstehen](./python-seite) · [Große Daten](./datenebene)
· [Konfiguration](./konfiguration)
