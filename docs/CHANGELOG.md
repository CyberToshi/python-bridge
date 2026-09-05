# Changelog

## Unreleased

### Dokumentation & Editor-UX

- **Dock-Tab umbenannt**: Der Tab hieß zuvor „PythonBridgePanel“ (interner
  Node-Name) und war dadurch schwer zu finden — er zeigt jetzt
  **„Python Bridge“**.
- **Installations-Doku ausgebaut** (`docs/INSTALLATION.md`): vollständige
  Klick-für-Klick-Anleitung von der Plugin-Aktivierung über das Auffinden
  des Docks (mit ASCII-Diagramm) bis zur ersten Python-Datei — auch für
  Godot-Neulinge nachvollziehbar.
- **Praxis-Doku ergänzt** (`docs/PRAXIS.md`): Button-Übersicht des Docks
  und Workflow-Checkliste mit allen Editor-Schritten.
- **Bottlenecks dokumentiert** (`docs/BOTTLENECKS.md` + Kapitel 11 in der
  PDF): alle konkreten Engpässe der Bridge — Serienquote pro Instanz,
  verklemmte Worker, pro-Aufruf-Quelltext-Neusendung/-neuhash, HauptThread-
  Dekodierung ohne Byte-Budget, numerische Arrays per JSON, eigenständiges
  Kapitel mit A/B/C/D-Kategorien, Größenordnungen und Dateinamen.

### Phase 2 — Data Plane (Commits `f625c7b` … `2c5fbc5`)

- **Binärer Numerik-Transport**: grosse Godot-`Packed*Array`
  (f32/f64/i32/i64) wandern als Little-Endian-Binary-Chunks mit
  `nbytes`-Descriptor statt als JSON-Zahlenliste; kleine bleiben inline.
  Python dekodiert Chunks (mit NumPy als ndarray) und versteht die Legacy-
  Listenform.
- **Dtype-/nbytes-Validierung** auf beiden Decodern: Descriptor-Mismatch
  wird erkannt (leeres Typed Array / raw-Fallback statt stiller Garbage).
- **DataRef-Handles**: numpy-Ergebnisse >= `data_ref_threshold_bytes`
  (Default 16 MiB) bleiben im Python-Prozess (per-Connection-`DataStore`,
  Cleanup bei Verbindungsende); Godot erhält `PythonBridgeDataRef` mit
  `materialize_data`/`release_data`/`describe_data`. Protokoll:
  `data_get`/`data_result`/`data_release`/`data_ack`. Stale-Handles
  (Release/Instanz-Ende) liefern strukturierte Fehler.
- **Frame-Budget**: `max_decode_bytes_per_frame` (Default 16 MiB) — rohe
  Pakete werden gepuffert und nur bis zum Budget pro Frame dekodiert
  (kein Main-Thread-Stall durch grosse Antworten).
- **Neue Doku** `docs/DATA_PLANE.md`; `docs/ARCHITEKTUR_V3.md`-Status auf
  „Phasen 0–2 umgesetzt“ aktualisiert.

**Tests:** GDScript-Suite 52 Tests / 167 Assertions, Python-Suite 61 Tests
(inkl. DataStore-Unit- und DataRef-Server-Integrationstests).

## v0.2.1 (current)

### Neu: Demo-Szene & Dokumentations-PDF

- **Demo-Szene** `example/demo_scene.tscn`: Nodes mit angehängten Skripten
  (`example/demo/`), die alle Kernfunktionen der Bridge zeigen:
  `DemoBasic` (call/execute/define_script), `DemoTasks` (Task-API,
  Priorität, Timeout, Cancel), `DemoBatch` (Batching), `DemoErrors`
  (strukturierte Fehler), `DemoMulti` (zwei Python-Instanzen parallel).
  UI-Panel mit Buttons; Beispielskripte in `example/scripts/`
  (`demo_skript.py`, `crash_skript.py` für den Crash-Restart-Test).
- **Dokumentations-PDF** `docs/PythonBridge_Dokumentation.pdf` (16 Seiten,
  im Stil der Original-PDF): Architektur, API-Referenz, Task Manager,
  Batching, Datentransport, Python-Seite, Editor-Integration, Demo-Szene,
  Lifecycle, Fehlerbehandlung, Troubleshooting.

Stabilitäts-Fix für Godot 4.7.x (und neuer): Das Addon kompiliert jetzt
fehlerfrei, wenn es als Autoload/Editor-Plugin geladen wird. Der Editor-
Parser (Autoload-Pfad) akzeptiert einige Konstrukte nicht, die der normale
Editor-Scan toleriert - das führte zu einem Kaskadenfehler, bei dem fast
jedes Skript mit „Could not resolve class … parser error“ scheiterte.

### Behobene Ursachen

- **Mehrzeilige `match`-Pattern-Listen** (Pattern über mehrere Zeilen vor
  dem Doppelpunkt) wurden im Autoload-Parsing abgelehnt
  („Expected expression for match pattern“). Alle Pattern-Listen stehen
  jetzt auf einer Zeile (`config.gd`, `error_handler.gd`, `scheduler.gd`,
  `bridge_instance.gd`).
- **Mehrzeilige Funktionssignaturen** (Parameter über mehrere Zeilen)
  wurden im Autoload-Parsing abgelehnt („Expected parameter name“). Alle
  Signaturen stehen jetzt auf einer Zeile (`error_handler.gd`, `protocol.gd`,
  `task.gd`, `type_mapper.gd`, `scheduler.gd`, `python_bridge.gd`,
  `wrapper_generator.gd`).
- **Nicht-literalische Konstanten**: `const DEFAULTS := { … }` mit
  `PackedStringArray()`/Arithmetik wurde als „isn't a constant expression“
  abgelehnt. `PythonBridgeConfig.DEFAULTS` ist jetzt die Funktion
  `PythonBridgeConfig.defaults()` (Runtime-Aufbau); weitere Konstanten sind
  explizit typisiert.
- **`class_name` als Parameter-/Variablenname** ist im Autoload-Kontext
  reserviert („Expected parameter name“ / „Expected variable name after
  var“). In `type_mapper.gd` (`register`) und `wrapper_generator.gd`
  umbenannt (`custom_class` / `cls_name`).
- **Autoload-Zugriff auf externe Klassen zur Parse-Zeit**: `_settings`
  wurde in `python_bridge.gd` mit `PythonBridgeConfig.DEFAULTS`
  initialisiert; jetzt lazy in `_init()`. Default-Parameter
  `PythonBridgeConfig.DEFAULT_INSTANCE` in `wrapper_generator.gd`
  ersetzt durch Runtime-Auflösung.
- **`python_editor.gd`**: `Engine.get_main_loop().root` funktioniert nicht
  (MainLoop hat kein `root`) - jetzt `is SceneTree`-Check.
- **`wrapper_generator.gd`**: `_class_name_for()` erzeugt jetzt gültige
  PascalCase-Identifiers (Separatoren wie `-`/`_` werden als
  Wortgrenzen behandelt: `mein_skript` -> `PyBridgeMeinSkript`).
- **`protocol.gd`**: `build_frame()` akzeptiert optional extern
  gesammelte Chunks und re-encodiert bereits getaggte Werte nicht mehr
  (Binary-Frame-Roundtrip funktionierte nicht für vor-encodierte Daten).
- **`task_manager.gd`**: Retry-Delay nutzt konsistent den übergebenen
  `now_ms` statt Wall-Clock (`Time.get_ticks_msec`) - Timeout/Retry-
  Logik ist damit deterministisch und testbar.

### Tests

- GDScript-Headless-Suite läuft jetzt erstmals real: **34 Tests / 99
  Assertions grün** (`godot --headless --script
  res://tests/gdscript/run_tests.gd`). Fixes im Runner (RefCounted-free,
  Typannotationen), in `test_serializer_protocol.gd` (Variant-Warnungen)
  und `test_task_layer.gd` (Batch-/Retry-Erwartungen).
- Optionaler E2E-Test `tests/gdscript/e2e_live.gd` (Autoload -> echter
  Python-Subprozess -> Task): erfordert natives Godot (Flatpak-Sandbox
  entzieht Subprozessen den venv-Zugriff).
- Python-Suite weiterhin **33/33 grün**.

## v0.2.0

Grundlegender Ausbau der v0.1.0-Bridge auf den vollen Funktionsumfang des
Master-Prompts. Protokoll v2.

### Neue Komponenten (Godot)

- `core/config.gd` — zentrale Konfiguration (Version-Floors Godot 4.2+ /
  Python 3.8+, alle Tunables) mit Typ-Koerzion.
- `core/error_handler.gd` — Fehler-Taxonomie mit 9 Kategorien und Mapping
  auf die Legacy-Status.
- `core/type_mapper.gd` — explizite `$pb`-Tag-Tabelle + Registry für
  benutzerdefinierte Typen (Serializer delegiert automatisch).
- `core/task.gd` — Task-Zustandsmaschine (QUEUED/RUNNING/COMPLETED/FAILED/
  CANCELLED/TIMEOUT), Prioritaet, Timeout, Batchable-Flag.
- `core/task_manager.gd` — Priority-Queue (stabil), Backpressure
  (max_queued_tasks, max_payload_bytes), Cancel, Retry-Policy, Batch-Fenster
  (max_batch_size/max_batch_delay_ms, Preemption, Reihenfolge), Auto-/Explicit-
  Instanz-Zuordnung.
- `core/scheduler.gd` — Frame-Sync: max_dispatch_per_frame,
  max_inflight_per_instance, bounded Inbox mit max_results_per_frame,
  Backlog-Throttling, Timeout-Check mit best-effort CANCEL, Crash-Hook.
- `core/process_manager.gd` — nicht-blockierender Prozess-Start, Running-/
  Exit-Code-Check, Force-Kill (ersetzt `process_thread.gd`).
- `core/connection_manager.gd` — WebSocket-Wrapper mit Ping/Pong-Timing
  (ersetzt `ws_client.gd`).
- `core/health_monitor.gd` — Ping-Kadenz, Missed-Pong-Zaehler, Health-State.

### Geaenderte Komponenten

- `core/bridge_instance.gd` — komplette Ueberarbeitung: Crash-Erkennung
  (WS-Close + Subprozess-Ende), Exponential-Backoff-Restart mit
  Stable-Uptime-Reset, Graceful Shutdown (shutdown_ack/Timeout/Force-Kill),
  Zombie-Praevention, leitet Task-Ergebnisse an den Scheduler weiter.
- `core/provisioner.gd` — Dependency-Verifikation per Import-Check nach pip.
- `core/python_bridge.gd` — Facade besitzt jetzt TaskManager/Scheduler;
  neue Task-API (submit_task/cancel_task/get_task), Hot-Reload-Trigger,
  Introspection (AST), shutdown()/shutdown_now().
- `core/protocol.gd` — Protokoll v2 mit explizitem Nachrichten-Set und
  Batch-Item-Kodierung.
- `core/serializer.gd` — delegiert unbekannte Tags an die TypeMapper-Registry.
- `core/result.gd` — strukturierte Fehler mit `code`, `task_id`,
  `instance_id`; `cancelled()`-Helper.

### Neue Komponenten (Python)

- `introspection.py` — AST-basierte Funktions-Signatur-Analyse (fuehrt nie
  Code aus) als Basis der Wrapper-Generierung.
- `server.py` (v2) — Routing fuer task/batch/cancel/reload/introspect/
  shutdown; Nutzer-Code laeuft in genau einem Worker-Thread pro Instanz
  (Event-Loop bleibt reaktionsfaehig), Timeout via asyncio.wait_for,
  Watchdog beendet den Prozess nach Shutdown/Verbindungsabbruch.
- `executor.py` — define/run/call mit Source-Hash pro Kontext (call
  re-definiert nur bei Aenderung), reload_context, stdout/stderr-Capture.
- `protocol.py` — v2-Nachrichtentypen, Batch-Item-Dekodierung.
- `__init__.py` — Version 0.2.0.

### Editor

- `editor/python_editor.gd` — Dock-Panel (Dateiliste, CodeEdit, Save/Run/
  Wrapper/Hot-Reload, Log, mtime-Watcher).
- `editor/python_syntax_highlighter.gd` — Python-Highlighting.
- `editor/wrapper_generator.gd` — deterministische GDScript-Generierung,
  Marker-sicheres Ueberschreiben, class_name-Kollisions-Check.
- `plugin.gd` — registriert Autoload + Dock.

### Entfernt

- `core/pending_request.gd`, `core/process_thread.gd`, `core/ws_client.gd`
  (durch Task/ProcessManager/ConnectionManager ersetzt).

### Tests

- Python-`unittest`-Suite (33 Tests, gruen): Protocol, Serializer,
  Executor, Introspection, Server-Integration (echter Subprozess + WS).
- GDScript-Headless-Testrunner (`godot --headless --script
  res://tests/gdscript/run_tests.gd`): Core-Units, Serializer/Protocol,
  Task-Layer, Wrapper-Generator.

## v0.1.0 (Baseline)

Importierte Ausgangsbasis aus `python_bridge_addon.zip`: BridgeInstance,
BridgeProvisioner, BridgeWsClient, BridgeProcess, PythonProtocol (v1),
PythonBridgeSerializer, Python-Server (hello/execute/ping/shutdown),
Editor-Plugin mit Autoload-Registrierung, Dokumentations-PDF.