---
sidebar_position: 9
sidebar_label: API-Überblick & Facade
title: API-Referenz
description: Vollständige Referenz der PythonBridge-Facade, Ergebnisse, Signale und Fehlercodes.
---

# API-Referenz

Diese Referenz beschreibt **jede öffentliche Funktion des Addons** – nichts,
was nicht wirklich im Code steht. Sie ist in logische Kapitel geteilt:

| Kapitel | Inhalt |
|---|---|
| **API-Überblick & Facade** (diese Seite) | `PythonBridge`, `PythonBridgeResult`, Fehlercodes, Lebenszyklus |
| [Tasks & Scheduling](./api-tasks) | `PythonBridgeTask`, `PythonBridgeTaskManager`, `PythonBridgeScheduler` |
| [Daten & Serialisierung](./api-data) | `PythonBridgeDataRef`, `PythonBridgeDataFile`, Serializer, Type Mapper, Protokoll |
| [Kern-Komponenten](./api-internals) | `PythonBridgeConfig`, `PythonBridgeErrorHandler`, `ScriptRegistry`, `BridgeInstance`, Verbindung/Prozess/Health, Provisioner, Wrapper-Generator |
| [Editor & HP-Werkzeuge](./api-editor) | `PythonBridgeEditorPanel`, Syntax-Highlighter, HP-GDScript |

## Lese-Konventionen

- **⏳** markiert eine `await`-bare (asynchrone) Methode. Sie gibt ein
  `PythonBridgeResult` zurück und kann mit `await` benutzt werden.
- ***(synchron)*** markiert Methoden, die sofort zurückkehren.
- Alle Beispiele sind GDScript. Typen folgen Godot-4-Konventionen.
- `PythonBridge` ist ein **Autoload-Singleton**, also sind alle Methoden
  **Instanz-Methoden** (kein `static`), damit `await` auf dem Main-Thread
  funktioniert.

## Klassenübersicht

| Klasse | Datei | Rolle |
|---|---|---|
| `PythonBridge` (Autoload) | `core/python_bridge.gd` | Zentrale Facade – Instanzen, Tasks, Skripte, Daten, Konfiguration, Signale |
| `PythonBridgeResult` | `core/result.gd` | Ergebnis-/Fehlerbehälter **jeder** Operation |
| `PythonBridgeTask` | `core/task.gd` | Eine Arbeitseinheit (Zustände, Felder, Builder) |
| `PythonBridgeTaskManager` | `core/task_manager.gd` | Queue, Prioritäten, Backpressure, Retry, Batching-Policy |
| `PythonBridgeScheduler` | `core/scheduler.gd` | Frame-Dispatch, Inbox, Timeouts (Mechanik) |
| `PythonBridgeDataRef` | `core/data_ref.gd` | Handle auf einen großen Datensatz |
| `PythonBridgeDataFile` | `core/data_file.gd` | Datei-basierte Materialisierung großer DataRefs |
| `PythonBridgeConfig` | `core/config.gd` | Standardwerte, Normalisierung, Validierung |
| `PythonBridgeErrorHandler` | `core/error_handler.gd` | Fehler-Taxonomie und -Normalisierung |
| `PythonBridgeScriptRegistry` | `core/script_registry.gd` | Datei-Cache + „Context ist definiert“-Bestätigungen |
| `PythonBridgeSerializer` | `core/serializer.gd` | Kodierung/Dekodierung aller Werte |
| `PythonBridgeTypeMapper` | `core/type_mapper.gd` | Typ-Tabelle und benutzerdefinierte Tags |
| `PythonProtocol` | `core/protocol.gd` | Draht-Protokoll (Nachrichtentypen, Framing) |
| `PythonBridgeWrapperGenerator` | `editor/wrapper_generator.gd` | GDScript-Wrapper erzeugen |
| `BridgeInstance` | `core/bridge_instance.gd` | Ein Python-Prozess + WebSocket-Kanal (Lifecycle) |
| `BridgeConnectionManager` | `core/connection_manager.gd` | WebSocket-Transport mit Decode-Budget |
| `BridgeProcessManager` | `core/process_manager.gd` | Subprozess-Start/Stop (flatpak-fähig) |
| `BridgeHealthMonitor` | `core/health_monitor.gd` | Ping/Pong-Überwachung |
| `BridgeProvisioner` | `core/provisioner.gd` | venv + Pip-Einrichtung |
| `PythonBridgeEditorPanel` | `editor/python_editor.gd` | Das Python-Dock im Editor |

---

## PythonBridge – die Facade

Der Autoload ist der **einzige Einstiegspunkt**. Der Editor-Dock und alle
generierten Wrapper sprechen ausschließlich mit dieser Klasse; sie hängen
nie direkt am Kern.

### Konfiguration & Zustand

#### `configure(cfg: Dictionary) -> void` *(synchron)*

Setzt die globale Konfiguration. Die Angaben werden **über die Standardwerte
gemergt**: nicht genannte Schlüssel bleiben Default, unbekannte Schlüssel
werden toleriert (vorwärtskompatibel) und in den numerischen Fällen auf
`int` normalisiert (`PythonBridgeConfig.normalize`). Vor dem ersten
`start_instance()` aufrufen – eine Instanz übernimmt beim Start eine
Momentaufnahme der Einstellungen.

```gdscript
PythonBridge.configure({"dependencies": ["numpy"], "workers_per_instance": 2})
```

Alle Schlüssel und ihre Wirkung: [Konfiguration](./konfiguration).

#### `config() -> Dictionary` *(synchron)*

Gibt eine **tiefe Kopie** der aktiven Konfiguration zurück. Änderungen an
der Kopie beeinflussen die Bridge nicht.

#### `workspace_dir() -> String` *(synchron)*

Der aktive Workspace-Pfad (Default `res://python_bridge`). Kurzform für
`config()["workspace_dir"]`.

#### `poll() -> void` *(synchron)*

Der **Sync-Punkt**: emittiert `pulse`, tickt jede Instanz und den Scheduler.
Der Autoload ruft das in `_process` selbst auf; der Editor-Plugin ruft es
zusätzlich, damit Instanzen auch im Editor-Kontext zuverlässig ticken. In
normalem Spielcode musst du das **nicht** aufrufen.

#### `system() -> Node` *(statisch)*

Findet den Autoload zur Laufzeit über den Szenenbaum:
`PythonBridge.system()`. Praktisch für Komponenten ohne feste
Singleton-Referenz (z. B. aus einer Klasse ohne Autoload-Zugriff).

### Instanzen (Python-Prozesse)

#### `start_instance(instance_name := "default") -> PythonBridgeResult` ⏳

Startet eine Instanz bzw. findet eine bereits laufende. Liefert `ok`,
sobald sie `ready` ist. Wiederholte Aufrufe sind idempotent (eine bereits
bereite Instanz antwortet sofort). Eine vorher beendete/fehlgeschlagene
Instanz gleichen Namens wird verworfen und neu gestartet.

Fehlerfälle: `DEPENDENCY_ERROR` (Python/venv/pip), `PROCESS_ERROR`
(Start fehlgeschlagen), `CONNECTION_ERROR` (Timeout). Der Timeout für
`wait_ready` beträgt intern 300 s (venv-Erstellung).

```gdscript
var r: PythonBridgeResult = await PythonBridge.start_instance("default")
if r.is_error():
    push_error(r.error_message())
```

#### `get_instance(instance_name := "default") -> BridgeInstance` *(synchron)*

Die Instanz als Node (`BridgeInstance`). Fortgeschritten – für die normale
Arbeit genügen `instance_status` und die Facade-Aufrufe.

#### `instance_status(instance_name := "default") -> String` *(synchron)*

Status-Text der Instanz oder `"none"`, wenn unbekannt. Mögliche Werte:
`none`, `provisioning`, `starting`, `connecting`, `handshake`, `ready`,
`crashed`, `restarting`, `stopping`, `stopped`, `error`.

#### `stop_instance(instance_name := "default") -> void` *(synchron, non-blocking)*

Leitet den **Graceful Shutdown** einer Instanz ein. Queued und laufende
Tasks dieser Instanz werden sofort strukturiert als `CONNECTION_ERROR`
aufgelöst (`fail_queued_for` + `fail_in_flight`), damit niemand ewig hängt.
Der Prozess beendet sich selbst im nächsten Instanz-`tick()`.

#### `stop_all() -> void` *(synchron, non-blocking)*

Ruft `stop_instance()` für alle bekannten Instanzen auf.

#### `shutdown() -> void` *(synchron, non-blocking)*

Blockiert neue Tasks und stoppt alle Instanzen (graceful). Gibt sofort
zurück – ideal in `_exit_tree()`, weil der Main-Thread nicht blockiert.
Ablauf und Timeout laufen im Instanz-`tick()`.

#### `shutdown_now() -> void` *(synchron)*

Erzwungener Sofort-Stop aller Instanzen (Kill). Markiert alle DataRefs als
`stale` und räumt die Prozesse auf, ohne auf ein `SHUTDOWN_ACK` zu warten.
Für `_exit_tree`/Editor-Trennung gedacht – **keine Zombie-Prozesse**.

### Temporärer Python-Code

#### `execute(code, input := {}, instance := "default", timeout_sec := 30.0) -> PythonBridgeResult` ⏳

Führt Python-Code **einmalig** in einem frischen temporären Kontext
(`temp-N`) aus. Im Code stehen die Variablen `input` (dein Wert) und
`result` (von dir gesetzt) bereit. Der Kontext ist **nicht** persistent –
zwei `execute`-Aufrufe teilen keinen Zustand, und `execute` ist **nicht
batchbar**.

```gdscript
var r := await PythonBridge.execute(
    "result = input[\"value\"] * 2", {"value": 21})
print(r.value)  # 42
```

| Parameter | Typ | Default | Bedeutung |
|---|---|---|---|
| `code` | `String` | – | Der auszuführende Python-Quelltext |
| `input` | `Variant` | `{}` | Wert, der im Code als `input` sichtbar ist |
| `instance` | `String` | `"default"` | Ziel-Instanz; unbekannter Name → sofortiger Fehler |
| `timeout_sec` | `float` | `30.0` | Ausführungs-Timeout (ab `RUNNING`) |

### Dauerhafte Skripte (.py-Dateien)

Skript-IDs sind Dateinamen **ohne** `.py`. Erlaubt sind auch
`unterordner/id` oder ein voller `res://`/absoluter Pfad. Skripte liegen
unter `<workspace>/scripts/`.

#### `create_script(script_id, code, subfolder := "") -> PythonBridgeResult` *(synchron)*

Schreibt `code` nach `<workspace>/scripts/[subfolder/]<id>.py`, legt
Ordner rekursiv an und verwirft den Lesecache, damit der nächste Zugriff
den neuen Inhalt sieht. Erfolgswert: `{"path": "<res://…>"}`.

#### `get_script_source(script_id) -> String` *(synchron)*

Inhalt der Skriptdatei (leer, wenn nicht vorhanden). Nutzt den
mtime/size-Cache der `PythonBridgeScriptRegistry`.

#### `call_script(script_id, function, args := [], kwargs := {}, instance := "default", timeout_sec := 30.0) -> PythonBridgeResult` ⏳

**Der häufigste Aufruf.** Definiert den Python-Kontext des Skripts genau
dann neu, wenn sich der Inhalt geändert hat (SHA-256-Vergleich über die
Registry), und ruft dann `function(*args, **kwargs)` auf. Der Modulzustand
bleibt zwischen Aufrufen erhalten.

```gdscript
var r := await PythonBridge.call_script("hello", "say_hello", ["Hello Python"])
```

| Parameter | Bedeutung |
|---|---|
| `args` | Positionsargumente (Array) |
| `kwargs` | Schlüsselwortargumente (Dictionary) |
| `instance` | Ziel-Instanz (Kontext ist **instanzgebunden**) |
| `timeout_sec` | Ausführungs-Timeout |

#### `execute_script(script_id, input := {}, instance := "default", timeout_sec := 30.0) -> PythonBridgeResult` ⏳

Führt die Skriptdatei wie `execute` aus (`input`/`result`-Konvention), aber
im **persistenten Skript-Kontext**. Der Dateicode läuft bei jedem Aufruf
erneut – der Modulzustand bleibt trotzdem im selben Kontext bestehen.

#### `define_script(script_id, instance := "default", timeout_sec := 30.0) -> PythonBridgeResult` ⏳

Führt das Skript **einmal** aus, ohne eine Funktion aufzurufen (z. B. zum
Vorbereiten von Caches). Nachfolgende `call_script`-Aufrufe greifen dann
auf den bereits definierten Kontext zurück.

#### `introspect_script(script_id, instance := "default") -> PythonBridgeResult` ⏳

Fragt die Funktions-Signaturen eines Skripts per **AST** ab, **ohne das
Skript auszuführen**. Erfolgswert ist ein Array von
`{name, params, returns, docstring}` – die Grundlage des Wrapper-Generators.
Benötigt eine `ready`-Instanz; Timeout nutzt `task_timeout_ms`.

#### `hot_reload_script(script_id) -> PythonBridgeResult` ⏳

Übernimmt Änderungen am Skript gemäß `hot_reload_mode`. Der Godot-Zustand
bleibt unangetastet; nur der Python-Kontext wird neu definiert (Default)
oder der Prozess neu gestartet. Ergebnis:
`{"reloaded": bool, "mode": "<modus>"}`.

### Low-Level-Tasks (fortgeschritten)

#### `submit_task(task: PythonBridgeTask) -> PythonBridgeResult` *(synchron)*

Reicht einen Task ein. Das **sofortige** Ergebnis sagt nur, ob der Task
akzeptiert wurde (Backpressure-/Payload-Prüfung). Das **Endergebnis** kommt
über `await task.done` bzw. `task.result`. Leere Task-ID wird automatisch
vergeben. Ist die Bridge im Shutdown, kommt `BRIDGE_ERROR`.

```gdscript
var t := PythonBridgeTask.make_call("id-1", "script:/pfad.py", source,
    "add", [2, 3], {}, 30000)
var accepted := PythonBridge.submit_task(t)     # sofort
if accepted.is_ok():
    var end: PythonBridgeResult = await t.done   # final
```

#### `cancel_task(task_id: String) -> bool` *(synchron)*

Bricht einen Task ab. `true`, wenn der Task existierte und noch nicht
terminal war. Queued Tasks (inkl. Batch-Fenster-Mitglieder) werden sofort
`CANCELLED`; laufende werden markiert (CANCEL an Python, kooperative
Cancellation via `__bridge__`) und laufen als `CANCELLED` aus. Späte
Ergebnisse abgebrochener Tasks werden verworfen.

#### `get_task(task_id: String) -> PythonBridgeTask` *(synchron)*

Liefert den Task (auch nach Abschluss für eine Weile – terminale Tasks
werden nach ~60 s aufgeräumt).

### Pfad-Helfer

#### `script_path_for(script_id, subfolder) -> String` *(synchron)*

Baut `<workspace>/scripts/[subfolder/]<id>.py` (ohne Prüfung, ob die Datei
existiert).

#### `resolve_script_path(script_id) -> String` *(synchron)*

Löst eine Skript-ID auf. Beginnt die ID mit `/` oder enthält `://`, wird
sie unverändert zurückgegeben; sonst wird sie zu
`<workspace>/scripts/<id>.py`.

### Datenebene (DataRefs)

#### `materialize_data(ref: PythonBridgeDataRef, timeout_sec := 60.0) -> PythonBridgeResult` ⏳

Holt die Daten eines Handles. Für große Datensätze nutzt der Server den
**Datei-Transport** (`tmp/data/data-<tag>-<id>.bin`, SHA-256-verifiziert);
Godot liest die Datei chunkweise innerhalb des Frame-Budgets
`file_read_bytes_per_frame`. Mehrfaches Materialisieren ist erlaubt;
stale/released Handles liefern einen strukturierten `TASK_ERROR`.

#### `release_data(ref: PythonBridgeDataRef, timeout_sec := 10.0) -> PythonBridgeResult` ⏳

Gibt die Daten im Python-Prozess frei und markiert den Handle als `stale`.
Ergebnis: `{"released": bool, "ref_id": …}`. Nach Instanz-Ende ist
`release_data` ein No-Op (Erfolg, `released = false`).

#### `describe_data(ref: PythonBridgeDataRef) -> PythonBridgeResult` *(synchron)*

Beschreibt den Handle **ohne Roundtrip**:
`{id, kind, dtype, shape, nbytes, readonly, instance, stale}`.

Mehr dazu: [Daten & Serialisierung](./api-data) und
[Große Daten (DataRefs)](./datenebene).

### Signale (Events)

| Signal | Parameter | Wann |
|---|---|---|
| `pulse` | – | Jeden Frame über `poll()` (interner Sync-Puls) |
| `instance_state_changed` | `instance: String, state: String` | Bei jedem Zustandswechsel einer Instanz |
| `task_done` | `task: PythonBridgeTask` | Jeder Task erreicht einen Endzustand |
| `bridge_event` | `instance: String, event: Dictionary` | Python → Godot-Ereignisse (`MSG_EVENT`) |

```gdscript
func _ready() -> void:
    PythonBridge.task_done.connect(_on_task_done)
    PythonBridge.instance_state_changed.connect(_on_instance_state)

func _on_task_done(task: PythonBridgeTask) -> void:
    print("Task ", task.id, " -> ", task.state_text(), " | ", task.result.value)

func _on_instance_state(instance: String, state: String) -> void:
    print("Instanz ", instance, " ist jetzt ", state)
```

---

## PythonBridgeResult

Jede Operation liefert ein `PythonBridgeResult`. Es ist der einzige Weg,
Erfolg und Fehler zu unterscheiden – es gibt keine Exceptions über die
Bridge-Grenze.

### Felder

| Feld | Typ | Bedeutung |
|---|---|---|
| `ok` | `bool` | `true` = Erfolg |
| `status` | `String` | Legacy-Status: `ok`/`error`/`timeout`/`not_ready`/`down`/`internal`/`cancelled` |
| `value` | `Variant` | Ergebniswert bei Erfolg (typisiert, s. [Typ-Mapping](./datenebene)) |
| `error` | `Dictionary` | Strukturierter Fehler `{code, type, message, traceback, task_id, instance_id}` |
| `request_id` | `String` | Interne Request-ID |
| `task_id` | `String` | Zuordnung zum Task |
| `instance_id` | `String` | Zuordnung zur Instanz |
| `meta` | `Dictionary` | u. a. `{duration_ms, request_id, instance_id}` |

### Methoden

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `is_ok()` | `bool` | `ok == true` |
| `is_error()` | `bool` | `ok == false` |
| `error_code()` | `String` | `error["code"]` (leer, wenn kein Fehler) |
| `error_message()` | `String` | `error["message"]`, sonst `status` |

### Statische Konstruktoren

| Methode | Bedeutung |
|---|---|
| `PythonBridgeResult.success(value := null, meta := {})` | Erfolgs-Ergebnis mit Wert und Meta |
| `PythonBridgeResult.failed_with_error(err, task_id := "", instance_id := "")` | Fehler; fehlt `code`, wird über den `ErrorHandler` normalisiert |
| `PythonBridgeResult.cancelled(task_id := "")` | `status = "cancelled"`, Code `TASK_ERROR` |
| `PythonBridgeResult.failed(status, message := "", err := {})` | Legacy-Konstruktor aus Status-String + Meldung |

```gdscript
var r := await PythonBridge.call_script("analyse", "rechne", [10])
if r.is_ok():
    print(r.value)
else:
    print("Code:      ", r.error_code())
    print("Meldung:   ", r.error_message())
    print("Typ:       ", r.error.get("type", ""))
    print("Traceback: ", r.error.get("traceback", ""))
    print("Dauer:     ", r.meta.get("duration_ms", 0), " ms")
```

:::note print() aus Python
`print()` in deinem Python-Code wird serverseitig erfasst (begrenzt durch
`max_stdout_bytes`), aber derzeit **nicht automatisch in die Godot-Konsole
durchgereicht**. Für sichtbare Ausgaben gibst du Werte per `return` zurück
und `print()`-est sie in GDScript. Details:
[Python-Seite verstehen](./python-seite).
:::

---

## Fehlercodes (Taxonomie)

`error.code` ist stabil und für eigene Fehlerbehandlung gedacht. Die
Konstanten liegen in `PythonBridgeErrorHandler`.

| Code | Bedeutung | Legacy-`status` |
|---|---|---|
| `PYTHON_EXCEPTION` | Python-Ausnahme (Exception-Typ, Message, Traceback) | `error` |
| `TASK_ERROR` | Task-Ebene: Queue voll, Payload zu groß, abgebrochen, stale Handle | `error` |
| `TIMEOUT_ERROR` | Antwort kam nicht rechtzeitig (Ausführungs-/Queue-Timeout) | `timeout` |
| `CONNECTION_ERROR` | WebSocket weg / Verbindungsfehler | `down` |
| `PROCESS_ERROR` | Python-Prozess beendet/abgestürzt | `down` |
| `DEPENDENCY_ERROR` | venv/pip/Import-Prüfung fehlgeschlagen | `internal` |
| `SERIALIZATION_ERROR` | Kodierung/Dekodierung, Datei-Prüfsumme, Ergebnis zu groß | `internal` |
| `PROTOCOL_ERROR` | Protokoll-/Hash-Verletzung | `internal` |
| `BRIDGE_ERROR` | Infrastrukturfehler (Skript fehlt, Instanz unbekannt, Shutdown) | `internal` |

**Retry-Hinweis:** Nur Verbindungs- und Prozessfehler sind gemäß
`retry_policy` retry-fähig; `PYTHON_EXCEPTION` niemals. Die vollständige
Behandlung inkl. `match`-Beispiel steht in
[Fehlerbehebung](./fehlerbehebung).

---

## Lebenszyklus eines Tasks (Kurzfassung)

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

Weiter: [Tasks & Scheduling](./api-tasks) · [Daten & Serialisierung](./api-data)
· [Kern-Komponenten](./api-internals) · [Editor & HP-Werkzeuge](./api-editor)
