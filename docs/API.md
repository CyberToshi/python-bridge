# Python Bridge — API-Referenz (v0.2.0)

Alle Funktionen sind Instanz-Methoden des Autoload-Singletons `PythonBridge`.
Aufrufe, die Python ausführen, liefern ein `PythonBridgeResult`.

## PythonBridge (Autoload)

### Konfiguration

```gdscript
PythonBridge.configure({
    "workspace_dir": "res://python_bridge",   # wo scripts/ venv/ tmp/ liegen
    "python_executable": "",                  # leer = automatische Suche
    "dependencies": ["numpy"],                # zusätzlich zu websockets
    "autostart": false,
    # Task Manager / Backpressure
    "max_queued_tasks": 1000,
    "max_payload_bytes": 67108864,            # 64 MiB
    "task_timeout_ms": 30000,
    "max_retries": 0,
    "retry_policy": "connection_error",       # none|connection_error|process_error|all
    # Batching
    "max_batch_size": 32,
    "max_batch_delay_ms": 32,
    # Frame-Sync
    "max_dispatch_per_frame": 16,
    "max_results_per_frame": 64,
    "max_inbox_size": 512,
    # Health / Crash-Restart
    "health_check_interval_ms": 5000,
    "health_missed_pong_limit": 3,
    "max_restart_attempts": 3,
    "restart_base_delay_ms": 500,
    "restart_backoff_factor": 2,
    "stable_uptime_ms": 30000,
    "shutdown_timeout_ms": 3000,
    # Hot Reload
    "hot_reload_mode": "reload_context",      # none|reload_context|restart_instance
    # Editor / Wrapper
    "auto_generate_wrappers": false,
})
```

### Instanzen

| Funktion | Beschreibung |
|---|---|
| `await start_instance(name := "default")` | Startet (bzw. holt) eine Instanz, wartet bis READY. |
| `get_instance(name)` | `BridgeInstance` oder `null`. |
| `instance_status(name)` | `none/provisioning/starting/connecting/handshake/ready/crashed/restarting/stopping/stopped/error`. |
| `stop_instance(name)` / `stop_all()` / `shutdown()` | Graceful Stop (non-blocking). |
| `shutdown_now()` | Sofortiger Force-Stop (keine Zombies; für `_exit_tree`). |

### Skripte & Ausführung

```gdscript
# Temporärer Code (Wegwerf-Kontext; input/result-Konvention)
var r := await PythonBridge.execute("result = input['x'] * 2", {"x": 21})

# Dauerhaftes Skript anlegen / lesen
PythonBridge.create_script("mein_skript", "def calculate(a, b):\n    return a * b\n")
var src := PythonBridge.get_script_source("mein_skript")

# Skript ausführen (input/result) oder Funktion aufrufen
var r1 := await PythonBridge.execute_script("mein_skript", {"x": 1})
var r2 := await PythonBridge.call_script("mein_skript", "calculate", [2, 3])

# Kontext vorab definieren (nur bei Source-Änderung neu ausgeführt)
var r3 := await PythonBridge.define_script("mein_skript")

# Alle Aufrufe akzeptieren optional einen Instanznamen:
var r4 := await PythonBridge.call_script("mein_skript", "f", [1], {}, "worker")
```

### Task-API (fein-granular)

```gdscript
var task := PythonBridgeTask.make_call("mein-id", "script:mein_skript", src, "fn", [1], {"b": 2}, 30000)
task.priority = 5            # 0 = höchste
task.batchable = true
task.retry_policy = "all"    # nur wenn max_retries > 0
var submitted := PythonBridge.submit_task(task)   # sofortiges Ergebnis (Backpressure)
if submitted.is_ok():
    var result := await task.done                # Endergebnis
PythonBridge.cancel_task(task.id)
var t2 := PythonBridge.get_task(task.id)         # Status/Result abfragen
```

### Hot Reload & Introspection

```gdscript
var reloaded := await PythonBridge.hot_reload_script("mein_skript")
var schema := await PythonBridge.introspect_script("mein_skript")
# schema.value = Array von {name, kind, docstring, returns, params:[...]}
```

### Pfade

```gdscript
PythonBridge.script_path_for("mein_skript")        # res://python_bridge/scripts/mein_skript.py
PythonBridge.resolve_script_path("unterordner/id") # volle Pfade erlaubt
PythonBridge.workspace_dir()                       # res://python_bridge
PythonBridge.config()                              # aktive Konfiguration
```

### Signale

```gdscript
signal pulse
signal instance_state_changed(instance: String, state: String)
signal task_done(task: PythonBridgeTask)
signal bridge_event(instance: String, event: Dictionary)
```

## PythonBridgeResult

| Feld | Beschreibung |
|---|---|
| `ok` / `is_ok()` / `is_error()` | Erfolg? |
| `status` | `ok/error/timeout/not_ready/down/internal/cancelled` (Legacy-Kompatibilität) |
| `value` | Ergebnis bei Erfolg (typisiert) |
| `error` | `{code, type, message, traceback, task_id, instance_id}` |
| `error_code()` | Kategorie aus der Taxonomie (z. B. `PYTHON_EXCEPTION`) |
| `request_id` / `task_id` / `instance_id` | Zuordnung |
| `meta` | z. B. `duration_ms`, stdout/stderr des Tasks |

Fehler-Kategorien: `BRIDGE_ERROR, PROCESS_ERROR, CONNECTION_ERROR,
PYTHON_EXCEPTION, SERIALIZATION_ERROR, TIMEOUT_ERROR, DEPENDENCY_ERROR,
PROTOCOL_ERROR, TASK_ERROR`.

## PythonBridgeTask

```gdscript
enum State { QUEUED, RUNNING, COMPLETED, FAILED, CANCELLED, TIMEOUT }
signal done(result: PythonBridgeResult)
# Felder: id, instance_id (""=auto), priority, timeout_ms, command,
# context_id, source, input/args/kwargs, batchable, retries_left, ...
PythonBridgeTask.make_run(id, context, source, input, timeout_ms)
PythonBridgeTask.make_call(id, context, source, function, args, kwargs, timeout_ms)
PythonBridgeTask.make_define(id, context, source, timeout_ms)
```

## Python-Seite (Skript-Konventionen)

- `run` (execute / execute_script): Variable `input`, Ergebnis in `result`.
- `call` (call_script): benannte Funktion, Rückgabewert ist das Ergebnis.
- Kontexte: Jede `context_id` hat einen eigenen Namespace. `call` re-definiert
  nur, wenn sich die Quelle geändert hat (Source-Hash); Modul-State bleibt.
- stdout/stderr des Nutzer-Codes werden pro Task erfasst und in
  `result.meta.stdout` / `result.meta.stderr` zurückgegeben.

## Wrapper-Generierung

Im Editor-Dock: Skript öffnen → „Generate wrapper“.
Oder programmatisch über `PythonBridge.introspect_script()` +
`PythonBridgeWrapperGenerator.generate(schema, script_id)`.

Generierte Datei: `res://python_bridge/wrappers/<skript>_wrapper.gd`
mit `class_name PyBridge<SkriptName>` und je Funktion eine Methode:

```gdscript
var w := PyBridgeMeinSkript.new()
var r := await w.calculate(2, 3)   # -> PythonBridgeResult
```

Regeln: Marker-Header (`# ===== GENERATED BY PYTHON BRIDGE - DO NOT EDIT =====`);
nur Marker-Dateien werden überschrieben; deterministische Ausgabe;
Type-Hints sind Kommentare (Variant-Parameter); Python-Defaults bleiben
autoritativ (Sentinel-Check); class_name-Kollisionen werden sichtbar abgelehnt.