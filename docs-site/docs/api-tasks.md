---
sidebar_position: 10
title: Tasks & Scheduling
description: Referenz zu PythonBridgeTask, TaskManager und Scheduler – Zustände, Felder, Prioritäten, Batching und Retry.
---

# Tasks & Scheduling

Ein **Task** ist eine einzelne Arbeitseinheit. Die **Facade** erzeugt Tasks
für dich (`call_script`, `execute`, …), der **TaskManager** hält die Queue
und die Policy, der **Scheduler** verteilt und liefert frame-synchron aus.
Wer `submit_task()` direkt nutzt, arbeitet mit den hier dokumentierten Typen.

## PythonBridgeTask

Eine `RefCounted`-Klasse (`core/task.gd`). Tasks gehören der Bridge; der
TaskManager darf ihren Zustand verändern – dein Code liest ihn.

### Zustände

```text
QUEUED → RUNNING → COMPLETED | FAILED | CANCELLED | TIMEOUT
```

| Enum | `state_text()` | Bedeutung |
|---|---|---|
| `State.QUEUED` | `queued` | In der Queue oder in einem Batch-Fenster |
| `State.RUNNING` | `running` | An Python gesendet, wartet auf Antwort |
| `State.COMPLETED` | `completed` | Erfolgreich beendet, `result.value` gesetzt |
| `State.FAILED` | `failed` | Fehlgeschlagen (Python-/Bridge-Fehler) |
| `State.CANCELLED` | `cancelled` | Abgebrochen (queued oder laufend) |
| `State.TIMEOUT` | `timeout` | Ausführungs-Timeout überschritten |

### Felder

| Feld | Typ | Default | Bedeutung |
|---|---|---|---|
| `id` | `String` | `""` | Eindeutige Task-ID; leer wird beim Submit vergeben |
| `instance_id` | `String` | `""` | Ziel-Instanz; `""` = Auto-Zuordnung beim Dispatch |
| `priority` | `int` | `0` | **0 = höchste**; niedriger Wert wird zuerst bedient |
| `created_at_ms` | `int` | `0` | Erstellzeit (Tick-Millisekunden) |
| `queued_at_ms` | `int` | `0` | Letzter Eintritt in die Queue (Anker für den Queue-Timeout) |
| `state` | `State` | `QUEUED` | Aktueller Zustand |
| `command` | `String` | `"run"` | `run` \| `call` \| `define` (s. `PythonProtocol`) |
| `context_id` | `String` | `""` | Persistenter Kontext; `script:<pfad>` oder `temp-N` |
| `source` | `String` | `""` | Inline-Quelltext zum **Definieren** des Kontexts |
| `source_hash` | `String` | `""` | SHA-256 des Quelltexts (Registry-Abgleich) |
| `input` | `Variant` | `null` | Bei `run`: der Python-Wert `input` |
| `function` | `String` | `""` | Bei `call`: Funktionsname |
| `args` | `Array` | `[]` | Bei `call`: Positionsargumente |
| `kwargs` | `Dictionary` | `{}` | Bei `call`: Schlüsselwortargumente |
| `timeout_ms` | `int` | `0` | Ausführungs-Timeout, gerechnet **ab `RUNNING`** |
| `started_at_ms` | `int` | `0` | Startzeitpunkt (Dispatch) |
| `max_retries` | `int` | `0` | Aus der Konfiguration übernommen |
| `retries_left` | `int` | `0` | Verbleibende Retries |
| `retry_policy` | `String` | `"connection_error"` | Aus der Konfiguration übernommen |
| `batchable` | `bool` | `true` | Darf in ein Batch-Fenster aufgenommen werden |
| `cancel_requested` | `bool` | `false` | Abbruch angefordert (laufende Tasks) |
| `result` | `PythonBridgeResult` | `null` | Endgültiges Ergebnis (nach `done`) |
| `meta` | `Dictionary` | `{}` | Frei nutzbarer Zusatzspeicher |

Zusätzlich gibt es interne Felder (`_seq`, `_next_attempt_ms`,
`_source_sent`, `_source_resent`, `_force_source`), die nur TaskManager
und Scheduler berühren.

### Signal

| Signal | Parameter | Wann |
|---|---|---|
| `done` | `result: PythonBridgeResult` | Genau einmal pro terminalem Task |

### Methoden

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `is_terminal()` | `bool` | `true` bei `COMPLETED`/`FAILED`/`CANCELLED`/`TIMEOUT` |
| `is_queued()` | `bool` | `true` bei `QUEUED` |
| `state_text()` | `String` | Menschenlesbarer Zustand (s. o.) |

### Statische Builder

| Methode | Erzeugt |
|---|---|
| `make_call(id, context, source, function, args, kwargs, timeout_ms, priority := 0)` | **call**-Task (`CMD_CALL`) |
| `make_run(id, context, source, input, timeout_ms, priority := 0)` | **run**-Task (`CMD_RUN`) |
| `make_define(id, context, source, timeout_ms, priority := 0)` | **define**-Task (`CMD_DEFINE`) |

```gdscript
var t := PythonBridgeTask.make_call(
    "task-1", "script:res://python_bridge/scripts/rechnen.py", source,
    "berechne", [3.0], {"faktor": 10.0}, 15000)
PythonBridge.submit_task(t)
var r: PythonBridgeResult = await t.done
```

## PythonBridgeTaskManager

`core/task_manager.gd` – verwaltet Queue, Priorität, Backpressure,
Cancellation, Retry und die Batching-Policy. **Alle Zustandsänderungen
passieren im Main-Thread** (Poll-Modell), daher keine Locks. Die Klasse wird
von der Facade instanziiert (`_init_task_layer()`); du greifst normalerweise
nicht direkt auf sie zu.

### Methoden

#### `attach_registry(registry: PythonBridgeScriptRegistry) -> void`

Hängt die Code-Plane-Registry an. Ohne Registry trägt **jeder** Task seinen
Inline-Quelltext (Legacy-Verhalten) – nützlich für isolierte Unit-Tests.

#### `submit(task: PythonBridgeTask, now_ms: int) -> PythonBridgeResult`

Reiht einen Task ein oder lehnt ihn ab. Ablehnungsgründe (alle
`TASK_ERROR`): leere/doppelte ID, bereits terminaler Task, Queue voll
(`max_queued_tasks`), Payload zu groß (`max_payload_bytes`, geschätzt aus
Quelltext-Länge und Argument-Puffern). Bei Erfolg wird der Task mit
`QUEUED` einsortiert und `{"task_id": id}` geliefert.

#### `get_task(task_id: String) -> PythonBridgeTask`

Task per ID oder `null`.

#### `pending_count() -> int`

Wartende Tasks: Queue **plus** die Mitglieder offener Batch-Fenster.

#### `running_count() -> int`

Anzahl Tasks im Zustand `RUNNING`.

#### `running_contexts(instance_id: String) -> Array`

Context-IDs, die auf der Instanz gerade laufen (eindeutig). Der Scheduler
nutzt das als **busy-Set**: gleiche Contexts werden nie parallel
dispatched, unabhängige dürfen auf freie Worker-Slots.

#### `cancel(task_id: String) -> bool`

`true`, wenn existiert und nicht terminal. Queued Tasks werden sofort
`CANCELLED`; laufende nur markiert (`cancel_requested`) und laufen als
`CANCELLED` aus, wenn ihr Resultat eintrifft.

#### `next_unit(instance_id, now_ms, busy_contexts := []) -> Dictionary`

Berechnet die nächste Dispatch-Einheit. Rückgabe:

| `kind` | Inhalt |
|---|---|
| `"none"` | Nichts passendes in der Queue |
| `"wait"` | Ein Batch-Fenster ist offen und wartet |
| `"single"` | `{"task": Task, "msg": Dictionary}` |
| `"batch"` | `{"tasks": Array, "msg": Dictionary, "instance_id": String}` |

Respektiert Retry-Verzögerungen (`_next_attempt_ms`) und überspringt Tasks,
deren Kontext im `busy_contexts` liegt. Ein einzelner Task dispatcht sofort,
er wartet **nie** auf ein Batch.

#### `tick_windows(now_ms: int) -> void`

Lässt pro Frame passende Tasks einem offenen Batch-Fenster beitreten
(bis `max_batch_size`). Geflusht wird in `next_unit()`, damit die
zurückgegebene Einheit auch wirklich versendet werden kann.

#### `check_timeouts(now_ms: int) -> Array`

Prüft Timeouts und liefert die IDs der **laufenden** Tasks, die gerade
abgelaufen sind (damit der Scheduler ein Best-Effort-CANCEL senden kann).

- **QUEUED**: Timeout über `queue_timeout_ms` (0 = unbegrenzt). Ergebnis:
  `TIMEOUT_ERROR` mit `error["reason"] = "queue"`, Task wird aus der Queue
  entfernt.
- **RUNNING**: Timeout über `task.timeout_ms` ab `started_at_ms`. Die
  Wartezeit in der Queue wird **nicht** angerechnet.

#### `resolve_result(instance_id: String, parsed: Dictionary) -> void`

Verarbeitet ein geparstes Ergebnis-Frame. Löst einzelne `task_result`/
`task_error` und alle Items eines `batch_result` auf. Späte/terminal­e
Ergebnisse werden verworfen. Bei `ScriptNotDefined` wird der Task **einmal**
mit Quelltext wiederholt (Registry-Selbstheilung, verbraucht keinen Retry).

#### `prune_terminal(now_ms: int, keep_ms := 60000) -> void`

Entfernt lang fertige Tasks aus dem Speicher (Memory-Hygiene), lässt
`result` aber für eine Weile abrufbar.

#### `fail_tasks(tasks, instance_id, err, now_ms := -1) -> void`

Lässt eine bestimmte Menge laufender Tasks fehlschlagen (z. B.
Sende-Fehler). Die Retry-Policy wird angewandt.

#### `fail_queued_for(instance_id: String, err: Dictionary) -> void`

Lässt alle **QUEUED** Tasks einer Instanz fehlschlagen (z. B. weil die
Instanz gestoppt wurde). Laufende Tasks bleiben unberührt.

#### `fail_in_flight(instance_id: String, err: Dictionary, now_ms := -1) -> void`

Lässt alle **RUNNING** Tasks einer Instanz fehlschlagen (Crash/Disconnect).
Zusätzlich werden Mitglieder offener Batch-Fenster dieser Instanz
fehlgeschlagen (sie wurden nie gesendet).

#### `mark_unit_running(instance_id: String, unit: Dictionary, started_ms := -1) -> void`

Markiert die Tasks einer Dispatch-Einheit als `RUNNING` und trägt die
konkrete Instanz (löst Auto-Zuordnung auf) sowie die Startzeit nach.

### Semantik-Überblick

- **Priorität:** Kleinere `priority` zuerst; bei Gleichstand zählt die
  Submissions-Reihenfolge (`_seq`) – stabil.
- **Backpressure:** Queue-Länge und geschätzte Payload werden beim Submit
  geprüft; zusätzlich drosselt der Scheduler, wenn die Inbox voll ist.
- **Batching:** Ab **zwei** kompatiblen batchbaren Tasks derselben Instanz
  öffnet sich ein Fenster (`max_batch_delay_ms`). Es schließt vorzeitig bei
  `max_batch_size` oder wenn ein höherpriorer Task auftaucht.
- **Retry:** `_should_retry` entscheidet anhand von `retry_policy`
  (`all`, `connection_error`, `process_error`, `none`) und `retries_left`.
  Requeue wartet `retry_delay_ms`.

## PythonBridgeScheduler

`core/scheduler.gd` – die **Mechanik** der Frame-Synchronisation. Der
Scheduler wird einmal pro Frame von `PythonBridge.poll()` getickt und
übernimmt beide Hälften des Vertrags: Dispatch (max.
`max_dispatch_per_frame` Einheiten) und Auslieferung (max.
`max_results_per_frame` Ergebnisse). Die Inbox ist auf `max_inbox_size`
begrenzt; ist sie voll, wird der Dispatch gedrosselt statt Ergebnisse zu
verlieren.

### Methoden

#### `setup(task_manager, get_ready_instances, send_message, on_event := Callable(), get_instance := Callable()) -> void`

Verdrahtet die Abhängigkeiten. Wird einmal von der Facade nach der
Konstruktion aufgerufen:

| Parameter | Signatur | Zweck |
|---|---|---|
| `task_manager` | `PythonBridgeTaskManager` | Queue/Policy |
| `get_ready_instances` | `() -> Array` | Liste bereiter `BridgeInstance` |
| `send_message` | `(instance, msg) -> Error` | Transport |
| `on_event` | `(instance_id, event) -> void` | Weiterleitung von `MSG_EVENT` an `bridge_event` |
| `get_instance` | `(instance_id) -> instance` | Auflösung für CANCEL-Nachrichten |

#### `tick() -> void`

Der Frame-Einstiegspunkt (Sync-Punkt): `tick_windows` →
`_dispatch` → `_process_inbox` → `_check_timeouts`. Räumt außerdem alle
10 s terminale Tasks auf.

#### `on_message(instance_id: String, parsed: Dictionary) -> void`

Puffert ein dekodiertes Frame. `task_result`/`task_error`/`batch_result`
gehen in die Inbox; `event` wird sofort an `on_event` gereicht; `status`
wird geloggt; `pong` ist hier bewusst ein No-Op (der HealthMonitor misst
die Zeit).

#### `on_instance_lost(instance_id: String, err: Dictionary) -> void`

Crash-Hook: lässt alle In-Flight-Einheiten der Instanz fehlschlagen und
entfernt sie aus der In-Flight-Tabelle.

#### `pending_dispatch_count() -> int`

Größe der Inbox (Diagnose).

#### `in_flight_count(instance_id: String) -> int`

Anzahl offener Dispatch-Einheiten einer Instanz (Diagnose).

Verwandt: [API-Überblick & Facade](./api) · [Fehlerbehebung](./fehlerbehebung)
· [Architektur](./architecture)
