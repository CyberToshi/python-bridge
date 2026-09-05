# Architektur — Python Bridge v0.2.0

Dieses Dokument beschreibt die tatsächlich implementierte Architektur
(Stand: v0.2.0, Protokoll v2). Grundlage war die v0.1.0-Codebasis; alle
Änderungen sind unten markiert.

Der nächste Architekturplan steht separat in `docs/ARCHITEKTUR_V3.md`. Er ist
noch kein Implementierungsstand und beschreibt die geplante Entwicklung von
Script Registry, Data Plane, Handles, Frame-Budgets und optionalen IPC-
Transporten.

## Leitprinzipien (verbindlich)

1. **Python bleibt Python.** Die Bridge ist eine Kommunikations- und
   Verwaltungsschicht, kein zweites GDScript. Python-Dateien bleiben echte
   `.py`-Dateien; Bridge-Funktionalität wird über das `python_bridge`-Paket
   und die Skript-Konventionen (`input`/`result`, Funktionen) bereitgestellt.
2. **Invariante:** *Python wartet nie auf einen Godot-Frame, und Godot wartet
   nie auf Python.* Alle Kommunikation ist asynchron und frame-poll-basiert;
   `await` auf der Facade ist ein Signal-`await`, das den Frame nicht blockiert.
3. **Ein Main-Thread, keine Threads im Godot-Kern.** Thread-Safety wird
   strukturell gelöst (Poll-Modell), nicht durch Locks. Python-Seite: ein
   Worker-Thread pro Instanz (sequenzielle Ausführung, race-frei).
4. **Keine erfundenen APIs.** Es werden ausschließlich dokumentierte
   Godot-4-APIs verwendet (WebSocketPeer, OS.create_process,
   OS.is_process_running, SyntaxHighlighter, EditorPlugin, ...).

## Komponenten

```
Godot (Main Thread, komplett poll-basiert)
│
├─ PythonBridge (Autoload/Facade)      Public-API, Instanzen, Konfig, Signals
├─ PythonBridgeConfig                  zentrale Konstanten + Tunables (config.gd)
├─ PythonBridgeTaskManager             Queue (Priorität), Backpressure, Cancel,
│                                      Retry, Batch-Fenster, Instanz-Zuordnung
├─ PythonBridgeScheduler               Frame-Sync: Dispatch/Result-Budgets,
│                                      Inbox, Backlog-Throttling
├─ PythonBridgeTask                    Task-Objekt + Zustandsmaschine
├─ BridgeInstance                      Prozess+WS+Health, Crash-Restart (Backoff),
│                                      Graceful Shutdown
├─ BridgeProcessManager                Start/Kill/Status (plattformspezifisch)
├─ BridgeConnectionManager             WebSocket-Wrapper + Ping/Pong-Timing
├─ BridgeHealthMonitor                 Ping-Kadenz, Missed-Pong-Zaehler
├─ BridgeProvisioner                   venv/pip (poll-basiert) + Dependency-Check
├─ PythonProtocol                      Frame-Bau/-Parse + Nachrichtentypen (v2)
├─ PythonBridgeSerializer / TypeMapper typisierte Kodierung + explizite Tabelle
├─ PythonBridgeErrorHandler            Fehler-Taxonomie (9 Kategorien)
└─ PythonBridgeResult                  Ergebnis-/Fehlercontainer

Editor (haengt nur an der Facade)
├─ plugin.gd                           Autoload-Registrierung + Dock
├─ PythonBridgeEditorPanel             Dateiliste, CodeEdit, Aktionen, Log
├─ PythonBridgeSyntaxHighlighter       Python-Syntaxhighlighting
└─ PythonBridgeWrapperGenerator        deterministische GDScript-Generierung

Python (ein Prozess pro Instanz)
├─ run_server.py                       Entry-Point (bind/port/tmpdir/tag)
├─ server.py                           asyncio-Loop: Control inline, Nutzer-Code
│                                      im Worker-Thread, Batch/Reload/Introspect
├─ executor.py                         ScriptHost: define/run/call + Source-Hash
├─ introspection.py                    AST-Analyse (fuer Wrapper-Generierung)
└─ protocol.py / serializer.py         Frames + typisierte Kodierung
```

## Datenfluss (Frame-Sync)

```
GDScript-Code → PythonBridge.call_script()/submit_task()
   → TaskManager: QUEUED (Prioritaet, Backpressure-Check)
   → Scheduler (Sync-Punkt, max_dispatch_per_frame):
       Batch-Fenster (max_batch_size / max_batch_delay_ms)
   → Instanz → WebSocket (task | batch)
   → Python-Loop → Worker-Thread (sequenziell) → Frame zurueck
   → Instanz.tick() → Scheduler.Inbox (bounded)
   → Sync-Punkt (_process): max_results_per_frame → Task abschliessen
   → task.done-Signal → Koroutine laeuft weiter (Main-Thread)
```

## Thread-/Prozessmodell

- **Godot:** 1 Main-Thread. Keine Worker-Threads im Kern. I/O ausschließlich
  nicht-blockierend (`WebSocketPeer.poll()`, `OS.create_process`).
- **Python:** 1 Prozess pro Instanz; darin 1 asyncio-Event-Loop (beantwortet
  Ping/Cancel/Shutdown auch waehrend langer Tasks) + 1 Worker-Thread für
  Nutzer-Code (sequenziell, Context-State race-frei).
- **Parallelitaet:** mehrere Instanzen (= mehrere Prozesse). Innerhalb einer
  Instanz strikt sequenziell.

## Task-Modell

Zustände: `QUEUED → RUNNING → COMPLETED | FAILED | TIMEOUT | CANCELLED`.

- Prioritaet: Integer, 0 = höchste; stabile Sortierung (Submissions-Reihenfolge).
- Timeout: Gesamtlebensdauer (Queue + Ausführung); Timeout bricht den
  Python-Task **nicht** physisch ab (dokumentiert), das Ergebnis wird
  verworfen und der Task als TIMEOUT aufgelöst.
- Retry: `retry_policy` (`none`/`connection_error`/`process_error`/`all`),
  `max_retries`, `retry_delay_ms`.
- Cancel: QUEUED → sofort CANCELLED; RUNNING → markiert, Ergebnis wird
  verworfen (CANCELLED), Python erhält best-effort CANCEL.
- Backpressure: `max_queued_tasks`, `max_payload_bytes`, `max_inflight_per_instance`
  (= 1 Unit; ein Batch zaehlt als eine Unit).

## Batching

- Nur kompatible Tasks werden gebatcht: gleiche Instanz (explizit oder Auto),
  gleiches Prioritaets-Bucket, `batchable == true`, keine Retry-Verzoegerung.
- Trigger: `max_batch_size` (Fenster voll → sofort) **oder** `max_batch_delay_ms`
  (frame-gezaehlt; Fenster laeuft ab → flush).
- Ein einzelner Task wartet nie (dispachtet sofort, kein Fenster).
- Hoeher priorisierter Task flusht das Fenster fruehzeitig (Preemption).
- Reihenfolge bleibt garantiert (Submissions-Ordnung), Ergebnisse pro Item,
  Fehler isoliert pro Item.

## Protokoll v2

Nachrichtentypen: `hello, hello_ack, task, task_result, task_error, batch,
batch_result, cancel, cancel_ack, ping, pong, reload, reload_ack, introspect,
introspect_result, status, event, shutdown, shutdown_ack`.
Commands: `run | call | define`. Siehe `core/protocol.gd`.

Frames: Text = JSON; Binary = `U32LE(HeaderLaenge) + HeaderJSON + [U32LE(ChunkLaenge) + Chunk]*`
(Little-Endian auf beiden Seiten, `struct.pack("<I")` / `decode_u32`).

## Serialisierung / Typ-Mapping

Skalare bleiben JSON. Strukturierte Werte: getaggte Objekte `{"$pb": "<tag>", ...}`.
Grosse Blobs (> 512 B) wandern in den Binary-Chunk-Stream. Die Mapping-Tabelle
liegt explizit in `type_mapper.gd`; benutzerdefinierte Typen koennen per
`PythonBridgeTypeMapper.register(tag, encode_fn, decode_fn, class_name)` ergaenzt
werden (Serializer delegiert automatisch).

## Crash / Restart / Shutdown

- Crash-Erkennung: unerwarteter WS-Close **oder** Subprozess-Ende (READY).
- Restart-Policy: `max_restart_attempts` (Default 3), `restart_base_delay_ms`
  (500), Faktor 2 → 0.5 s, 1 s, 2 s; Reset nach `stable_uptime_ms` (30 s).
- In-Flight-Tasks beim Crash → `FAILED` mit `PROCESS_ERROR`/`CONNECTION_ERROR`.
- Shutdown: neue Tasks blockiert, In-Flight gefailt, `shutdown` gesendet,
  `shutdown_timeout_ms` (3 s) gewartet (frame-gepollt, `shutdown_ack` beschleunigt),
  danach Force-Kill (`taskkill /F` / `kill -9`). Keine Zombies.

## Hot Reload

Modi (`hot_reload_mode`): `none` | `reload_context` (Default) | `restart_instance`.
`reload_context` invalidiert den Python-seitigen Source-Hash des Kontexts; der
naechste Call re-definiert die Quelle. Andere Kontexte + Prozess bleiben am
Leben, Godot-State bleibt unangetastet. Der Editor-Watcher prueft mtime und
loest den Reload automatisch aus.

## Abgrenzung Editor → Kern

Der Editor (`editor/`) kennt ausschliesslich die Facade-API
(`create_script`, `execute_script`, `introspect_script`,
`hot_reload_script`, `workspace_dir`). Der Kern (`core/`) referenziert keine
Editor-Klassen. CodeEdit wird nur als Texteditor im Dock benutzt, nicht als
Architekturbasis.