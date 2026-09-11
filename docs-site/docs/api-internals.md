---
sidebar_position: 12
title: Kern-Komponenten
description: Referenz zu Config, ErrorHandler, ScriptRegistry, BridgeInstance und den Transport-/Lifecycle-Klassen.
---

# Kern-Komponenten

Diese Seite dokumentiert die Klassen unterhalb der Facade. Für normale Arbeit
genügt [API-Überblick & Facade](./api) – wer die Bridge erweitern, testen
oder debuggen will, findet hier jede öffentliche Funktion.

## PythonBridgeConfig

`core/config.gd` – zentrale Konfiguration. Hält alle Tunables,
Versions-Mindeststände und Protokollkonstanten an einem Ort.

### Konstanten

| Konstante | Wert | Bedeutung |
|---|---|---|
| `PROTOCOL_VERSION` | `2` | Protokollversion |
| `MIN_GODOT_VERSION` | `"4.2"` | Mindest-Godot-Version |
| `MIN_PYTHON_MAJOR` / `MIN_PYTHON_MINOR` | `3` / `8` | Mindest-Python-Version |
| `DEFAULT_WORKSPACE_DIR` | `"res://python_bridge"` | Standard-Workspace |
| `DEFAULT_INSTANCE` | `"default"` | Name der Standard-Instanz |

### Methoden

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `defaults()` *(statisch)* | `Dictionary` | Frische Kopie der Standardwerte (als Funktion, nicht Konstante – Editor-Compiler-Falle) |
| `normalize(cfg)` *(statisch)* | `Dictionary` | Mergt `cfg` über die Defaults und erzwingt Typen |
| `is_valid_reload_mode(mode)` *(statisch)* | `bool` | `none` \| `reload_context` \| `restart_instance` |
| `is_valid_retry_policy(policy)` *(statisch)* | `bool` | `none` \| `connection_error` \| `process_error` \| `all` |

`normalize()` behandelt `dependencies` als `PackedStringArray`, Strings
(`workspace_dir`, `python_executable`, `wrapper_dir`, `hot_reload_mode`,
`retry_policy`) via `str()` und numerische Tunables als `int`. Unbekannte
Schlüssel bleiben erhalten (vorwärtskompatibel).

## PythonBridgeErrorHandler

`core/error_handler.gd` – die Fehler-Taxonomie. Jeder Fehler, der eine
Modulgrenze überschreitet, ist ein Dictionary mit mindestens
`{code, message, type, traceback, task_id, instance_id}`.

### Kategorien und Status

| Kategorie-Konstante | Wert | Legacy-Status |
|---|---|---|
| `CATEGORY_PYTHON_EXCEPTION` | `PYTHON_EXCEPTION` | `error` |
| `CATEGORY_TASK_ERROR` | `TASK_ERROR` | `error` |
| `CATEGORY_TIMEOUT_ERROR` | `TIMEOUT_ERROR` | `timeout` |
| `CATEGORY_CONNECTION_ERROR` | `CONNECTION_ERROR` | `down` |
| `CATEGORY_PROCESS_ERROR` | `PROCESS_ERROR` | `down` |
| `CATEGORY_DEPENDENCY_ERROR` | `DEPENDENCY_ERROR` | `internal` |
| `CATEGORY_SERIALIZATION_ERROR` | `SERIALIZATION_ERROR` | `internal` |
| `CATEGORY_PROTOCOL_ERROR` | `PROTOCOL_ERROR` | `internal` |
| `CATEGORY_BRIDGE_ERROR` | `BRIDGE_ERROR` | `internal` |

Status-Konstanten: `STATUS_OK`, `STATUS_ERROR`, `STATUS_TIMEOUT`,
`STATUS_NOT_READY`, `STATUS_DOWN`, `STATUS_INTERNAL`, `STATUS_CANCELLED`.

### Methoden

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `make(code, message, task_id := "", instance_id := "", exc_type := "", traceback := "")` *(statisch)* | `Dictionary` | Baut ein strukturiertes Fehler-Dictionary |
| `normalize(error, task_id := "", instance_id := "")` *(statisch)* | `Dictionary` | Kanonisiert ein Fehler-Dict; ohne `code` wird `PYTHON_EXCEPTION` (bei Traceback) bzw. `BRIDGE_ERROR` gesetzt |
| `status_for_code(code)` *(statisch)* | `String` | Mappt Kategorie → Legacy-Status |
| `message(error)` *(statisch)* | `String` | Kurze Menschenlesbare Meldung |

## PythonBridgeScriptRegistry

`core/script_registry.gd` – die **Code Plane**. Zwei Aufgaben:

1. **Datei-Lesecache:** liest einen Quelltext nur neu, wenn sich `mtime`
   geändert hat (Bottleneck A3 vermieden).
2. **Instanz-Kontext-Registry:** merkt pro Instanz, welche
   `(context_id → source_hash)` der Server bereits kennt. Ein bestätigter
   Hash erlaubt dem Scheduler, den Quelltext beim Dispatch wegzulassen
   („define once“).

Die Registry ist rein Godot-seitig und läuft im Main-Thread.

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `entry_for(path)` | `Dictionary` | `{source, hash, mtime, size}` oder `{}` |
| `refresh(path)` | `Dictionary` | Erzwingt Neulesen (Hot Reload/Speichern) |
| `forget(path)` | `void` | Verwirft den Datei-Cache-Eintrag |
| `is_defined(instance, context, hash)` | `bool` | Kennt die Instanz den Kontext mit genau diesem Hash? |
| `confirm(instance, context, hash)` | `void` | Bestätigt ein `(context, hash)` für eine Instanz |
| `reset_instance(instance)` | `void` | Verwirft alle Bestätigungen einer Instanz (Neustart/Crash/Stop) |
| `reset_context(instance, context)` | `void` | Verwirft eine Kontext-Bestätigung |
| `reset_context_all(context)` | `void` | Verwirft eine Kontext-Bestätigung auf allen Instanzen |
| `confirmed_count()` | `int` | Anzahl bestätigter Kontexte (Diagnose) |

## BridgeInstance

`core/bridge_instance.gd` – ein Python-Prozess + ein WebSocket-Kanal. Die
Instanz besitzt nur Transport und Lifecycle; die Task-Orchestrierung liegt
bei Facade/TaskManager/Scheduler.

### Zustandsmaschine

```text
NONE → PROVISIONING → STARTING → CONNECTING → HANDSHAKE → READY
 any  → CRASHED → RESTARTING → STARTING (Backoff) | ERROR (permanent)
 any  → STOPPING → STOPPED
```

### Signale

| Signal | Parameter | Wann |
|---|---|---|
| `state_changed` | `instance, state` | Bei jedem Zustandswechsel |
| `message_received` | `instance, parsed` | Task-/Data-/Event-Nachricht eingetroffen |
| `lost` | `instance, error` | Crash/Stop mit In-Flight-Tasks |
| `instance_ready` | `instance` | `READY` erreicht |

### Methoden

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `start()` | `void` | Startet Provisioning → Prozess → Verbindung |
| `tick()` | `void` | Pro Frame: Provisioner/Port-Probe/WS-Poll/Health/Shutdown |
| `stop()` | `void` | Graceful Stop (SHUTDOWN → Warten → Kill), non-blocking |
| `shutdown_now()` | `void` | Sofortiger Force-Kill |
| `send_message(msg)` | `Error` | Frame senden (nur wenn offen) |
| `status_text()` | `String` | Zustandstext (s. Facade) |
| `is_active()` | `bool` | Ob die Instanz am Leben/provisioniert wird |
| `is_ready()` / `is_ready_immediately()` | `bool` | `state == READY` |
| `last_error_message()` | `String` | Letzte Fehlermeldung (z. B. für `start_instance`) |
| `wait_ready(timeout_sec := 300.0)` | `bool` ⏳ | Wartet per `process_frame` auf `READY`; `false` bei `ERROR`/`STOPPED`/Timeout |

Konstanten: `PORT_PROBE_MAX` (`1800`), `PING_INTERVAL_MS` (`5000`).

## BridgeConnectionManager

`core/connection_manager.gd` – reiner WebSocket-Transport mit **Decode-Budget
pro Frame**. Alle Methoden laufen im Main-Thread.

| Methode / Feld | Rückgabe | Bedeutung |
|---|---|---|
| `connect_to(host, port)` | `Error` | Öffnet den WebSocket (`ws://host:port`) |
| `poll()` | `void` | Muss pro Frame aufgerufen werden |
| `is_open()` | `bool` | Verbindung offen? |
| `send_message(msg)` | `Error` | Baut den Frame und sendet Text oder Binär |
| `drain(byte_budget := -1)` | `Array` | Liefert dekodierte Frames `{msg, data}`; dekodiert nur bis zum Budget, Rest im nächsten Frame |
| `mark_ping_sent()` / `mark_pong_received()` | `void` | Ping/Pong-Buchhaltung für den HealthMonitor |
| `last_error` | `Error` | Letzter Transportfehler |
| `pending_ping` | `bool` | Ob ein Pong aussteht |
| `last_drain_bytes` | `int` | Telemetrie: Bytes der letzten `drain()` |

`inbound_buffer_size`/`outbound_buffer_size` sind auf 512 MiB gesetzt, damit
große Binärframes hineinpassen.

## BridgeProcessManager

`core/process_manager.gd` – startet/überwacht den Python-Subprozess ohne den
Main-Thread zu blockieren (OS.create_process). Keine Shell: Argumente gehen
als strukturiertes `PackedStringArray` (sicher für Leerzeichen, Umlaute,
Unicode).

| Methode / Feld | Rückgabe | Bedeutung |
|---|---|---|
| `start(command)` | `bool` | Startet den Prozess (flatpak-aware), speichert `pid` |
| `spawn(argv)` *(statisch)* | `int` | Non-blocking Spawn eines vollen argv, liefert `pid` oder `-1` |
| `execute(argv, out, read_stderr := true)` *(statisch)* | `int` | Flatpak-aware `OS.execute` |
| `in_flatpak()` *(statisch)* | `bool` | Erkennt die Flatpak-Sandbox (`FLATPAK_ID`/`/.flatpak-info`) |
| `wrap_argv(argv)` *(statisch)* | `PackedStringArray` | Prefix `flatpak-spawn --host` und übersetzt `/run/host/…`-Pfade |
| `is_running()` | `bool` | Ob der PID noch läuft |
| `get_exit_code()` | `int` | Exit-Code des Prozesses |
| `kill()` | `void` | Force-Kill (taskkill/kill -9), flatpak zusätzlich `pkill` über `kill_marker` |
| `forget()` | `void` | PID freigeben, ohne den Prozess zu beenden |
| `kill_marker` | `String` | z. B. `--tag <instanz>` für gezieltes Host-`pkill` |

## BridgeHealthMonitor

`core/health_monitor.gd` – pingt eine Instanz im Zustand `READY` und zählt
verpasste Pongs. Frame-getrieben, keine Threads.

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `reset()` | `void` | Zähler und Zustand zurücksetzen |
| `should_ping(now_ms)` | `bool` | Ob jetzt ein PING fällig ist |
| `record_ping_sent(now_ms)` | `void` | Zeitstempel des Pings |
| `record_pong()` | `void` | Pong erhalten → Zähler zurück |
| `tick(now_ms)` | `bool` | Pro Frame: `false`, wenn `health_missed_pong_limit` Fenster in Folge verpasst wurden |
| `is_healthy()` | `bool` | Aktueller Gesundheitszustand |
| `missed_windows()` | `int` | Anzahl verpasster Fenster |

## BridgeProvisioner

`core/provisioner.gd` – legt die projektbezogene `venv` an und installiert
die Pakete. Läuft **poll-basiert** (kein Thread): `start()` beginnt, `tick()`
treibt, `wait()` läuft synchron bis zum Abschluss.

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `start(cfg, target, method)` | `void` | Beginnt das Provisioning; ruft `target.method(ok, msg)` am Ende |
| `wait()` | `void` | Blockiert, bis das Provisioning fertig ist |
| `tick()` | `void` | Treibt den Zustandsautomaten (non-blocking) |
| `is_done()` | `bool` | Ob das Provisioning abgeschlossen ist |

Log des pip-Schritts: `<workspace>/tmp/pip.log`.

## PythonBridgeWrapperGenerator

`editor/wrapper_generator.gd` – erzeugt deterministische GDScript-Wrapper aus
dem Introspect-Schema. Regeln: nur Dateien mit Marker-Header werden
überschrieben, gleicher Input → identische Bytes, Typ-Hints sind reine
Dokumentation, Python-Defaults bleiben autoritativ (Sentinel `_unset`).

| Konstante / Methode | Rückgabe | Bedeutung |
|---|---|---|
| `MARKER` | `String` | Marker-Header generierter Dateien |
| `is_generated(path)` *(statisch)* | `bool` | Ob die Datei ein Bridge-Wrapper ist |
| `generate(schema, script_id, instance_name := "")` *(statisch)* | `Dictionary` | `{"ok": true, "code": String}` oder `{"ok": false, "error": String}` |

`generate()` bricht mit sichtbarem Fehler ab, wenn der gewünschte
`class_name` (`PyBridge<Name>`) bereits im Projekt belegt ist.

---

Verwandt: [Tasks & Scheduling](./api-tasks) · [Daten & Serialisierung](./api-data)
· [Editor & HP-Werkzeuge](./api-editor) · [Architektur](./architecture)
