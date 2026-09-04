# Changelog

## v0.2.0 (current)

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