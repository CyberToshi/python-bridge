# Python Bridge — API-Referenz (v0.5.0)

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

```

Praezedenz beim Start (spaeter gewinnt): Defaults → Projekt-Einstellungen
(*Projekt → Projekteinstellungen → Python Bridge*) → `<workspace>/config.json`
→ `configure()` aus Code.

```gdscript
# Projekt-Einstellungen + config.json neu einlesen (laesst laufende Instanzen
# unangetastet - neue Werte gelten beim naechsten start_instance()):
var res := PythonBridge.reload_config()
# res.value = {settings, project_settings[], config_file}

# Nur einzelne Werte zur Laufzeit nachziehen, ohne die Kette zu verlieren:
var cfg: Dictionary = PythonBridge.reload_config().value.settings
```

Die im Editor sichtbaren Felder samt Pfaden:

| Projekt-Einstellung | Key | Typ |
|---|---|---|
| `python_bridge/general/autostart` | `autostart` | bool |
| `python_bridge/general/workspace_dir` | `workspace_dir` | Ordner |
| `python_bridge/general/python_executable` | `python_executable` | Datei |
| `python_bridge/general/dependencies` | `dependencies` | Komma-String |
| `python_bridge/general/hot_reload_mode` | `hot_reload_mode` | Auswahl |
| `python_bridge/general/auto_generate_wrappers` | `auto_generate_wrappers` | bool |
| `python_bridge/web/packages` | `web_packages` | Komma-String |

Die Liste ist maschinenlesbar: `PythonBridgeConfig.project_setting_defs()`
(genau diese Eintraege registriert das Plugin und der Dock-Dialog verwendet
dieselbe Quelle).

### Dependencies deklarieren (drei gleichberechtigte Wege)

1. **Im Python-Skript** (empfohlen, Single Source of Truth):

   ```python
   __bridge_deps__ = ["numpy", "pandas>=2.0"]
   ```

   Die Deklaration gehört auf Top-Level (Zeilenanfang, keine Einrückung) —
   die Position in der Datei ist frei, auch unterhalb von Kommentaren oder
   Imports. Gilt für `.py` **und** `.pyx`-Dateien (seit v0.3.3).

   Desktop: installiert der Provisioner automatisch in die venv; fehlt ein
   Paket beim ersten Call, installiert der Server es nach (oder startet die
   Instanz einmal neu). Web: `build_web_bundle.py` übernimmt die Deklaration
   in `bridge_deps.json`, der Worker lädt die Pakete beim Start.

2. **Aus GDScript** (vor `start_instance()`):

   ```gdscript
   PythonBridge.register_dependencies(["numpy", "scipy"])
   ```

3. **Datei** `python_bridge/config/dependencies.txt` (eine Zeile pro Paket,
   `#`-Kommentare erlaubt).

Alle drei Quellen werden zusammengefuehrt und in **einem** pip-Lauf
installiert; Duplikate werden entfernt.

### Welche Pakete funktionieren?

**Desktop: alles, was `pip install` in einer frischen venv schafft.** Der
Provisioner ruft genau das auf (`python -m pip install -r
<workspace>/config/requirements_combined.txt`) — voller Resolver, PyPI als
Default-Index, PEP-517-Build-Isolation. Akzeptiert werden alle
Requirements-Schreibweisen:

| Schreibweise | Beispiel | Anmerkung |
|---|---|---|
| Name | `numpy` | |
| Pin | `pandas>=2.0`, `numpy==1.26.4`, `beautifulsoup4~=4.12` | `~=`, `!=` und Marker funktionieren seit v0.5.0 auch in der „ist es schon da?“-Pruefung |
| Extras | `requests[socks]` | Extras landen mit in der venv |
| Direkte URL | `mypkg @ https://…/mypkg-1.0-py3-none-any.whl` | nur Wheels, die zu Plattform und Python-Version passen |
| VCS | `git+https://github.com/a/b.git@v1` | braucht `git` im PATH |
| pip-Option (nur `dependencies.txt`) | `--extra-index-url https://…`, `-f https://…` | wird unveraendert an pip durchgereicht |

Grenzen sind die von pip, nicht die der Bridge: Pakete ohne Wheel brauchen
einen C-Compiler (siehe `docs/ERSTE_SCHRITTE.md` §5.6) und teils
Systembibliotheken; fuer brandneue Python-Versionen fehlen manchmal noch
Wheels. Das Ergebnis steht in `<workspace>/tmp/pip.log`; ein Fehlschlag wird
als `DEPENDENCY_ERROR` gemeldet, nie still verschluckt.

**Web: nur, was Pyodide kennt.** Der Worker laedt Pakete per
`pyodide.loadPackage()` aus dem Pyodide-Repository (`web_packages` bzw. die
`__bridge_deps__` aus dem Bundle). Reine PyPI-Pakete, die dort nicht
enthalten sind, sowie alles mit kompilierten Anteilen ausserhalb des
Pyodide-Builds gibt es im Browser nicht — dafuer bleibt der Desktop-Weg.


### Instanzen

| Funktion | Beschreibung |
|---|---|
| `await start_instance(name := "default")` | Startet (bzw. holt) eine Instanz, wartet bis READY. |
| `get_instance(name)` | `BridgeInstance` oder `null`. |
| `instance_status(name)` | `none/provisioning/starting/connecting/handshake/ready/crashed/restarting/stopping/stopped/error`. |
| `stop_instance(name)` / `stop_all()` / `shutdown()` | Graceful Stop (non-blocking). |
| `await restart_instance(name, timeout_sec := 15.0)` | Stop abwarten, dann neu starten (z. B. nach Einstellungsänderungen). Direktes `stop_instance()` + `start_instance()` scheitert am `stopping`-Zustand. |
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

# --- Cython (Desktop-only) --------------------------------------------
# .pyx-Datei anlegen (im Editor-Dock per Toggle oder programmatisch):
PythonBridge.create_cython_script("mathtools", "def f(int n):\n    return n * 2\n")

# Inkrementellen Build anstossen (passiert sonst automatisch vor dem
# ersten call_script auf ein .pyx-Skript):
var cb := await PythonBridge.compile_cython()           # force=false
# Report: {ok, built[], skipped[], errors[], compiler, duration_s}

# Aufruf identisch zu .py - das kompilierte Modul wird importiert:
var r5 := await PythonBridge.call_script("mathtools", "f", [21])
```

### Skript-Verwaltung (Dateien)

```gdscript
# Alle persistenten Skripte: [{id, ext, path}]
for entry in PythonBridge.list_scripts():
    print(entry["id"], entry["ext"])

# Id fuer neue Dateien pruefen ("" = verwendbar)
var err := PythonBridge.validate_script_id("mein_modul")

# Rueckstandsfrei loeschen: Quelle, .py.uid, .pyc/__pycache__, .c, .so/.pyd,
# .o/.obj (cython_build_tmp), Build-Zustand und generierter Wrapper (+ .uid).
var del := PythonBridge.delete_script("mein_modul")
# del.value = {ok, existed, removed[], failed[], cython_state_cleared}
```

Zwischen `execute()` (temporaer, kein Dateisystem-Zugriff) und
`create_script()`/`call_script()` (persistent) wird strikt unterschieden -
Details in [ERSTE_SCHRITTE.md](ERSTE_SCHRITTE.md).

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

### Sync-/Invalidierungs-API (Web und Cython)

Diese Methoden ruft normalerweise das Editor-Dock; sie sind public, weil
eigene Dateischreiber sie ebenfalls brauchen (sonst laufen Python-Prozess und
Dateisystem auseinander):

```gdscript
# Nach dem Schreiben einer Skriptdatei aufrufen. Verwirft den Registry-Cache
# und spiegelt die Datei im Web-Export in den Pyodide-Workspace (MEMFS).
PythonBridge.notify_script_written(script_id, path)

# Vollstaendiger Speicher-Pfad: zusaetzlich Cython-Modul des Stems verwerfen
# (sonst liefe nach .pyx -> .py das alte .so/.pyd aus sys.modules weiter) und
# im Web die .pyx-Gegenprobe entfernen.
PythonBridge.notify_script_saved(script_id, path)

# Nach dem Loeschen: Kontexte + importiertes Modul verwerfen, im Web die
# Dateien im MEMFS entfernen.  -> {ok, existed, removed[], failed[], ...}
var del := PythonBridge.delete_script("rechner")
```

Im Browser laufen diese Meldungen ueber den einseitigen `file_op`-Kanal
(`write`/`delete`) und den `invalidate`-Kanal. Ist noch keine Instanz bereit,
werden sie gepuffert (letzte Operation pro Pfad gewinnt) und beim Wechsel nach
`ready` nachgezogen.

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
PythonBridge.scripts_dir()                         # .../scripts
PythonBridge.wrapper_dir()                         # .../wrappers
PythonBridge.config()                              # aktive Konfiguration
```

### Cython (Desktop)

```gdscript
# Report: {ok, built[], skipped[], errors[], compiler, duration_s}
# compiler = msvc | mingw32 | system | zig | none
var rep := await PythonBridge.compile_cython("", false)

# Ob ein Build noetig ist, entscheidet die Bridge per SHA-256 der .pyx gegen
# den Stand des letzten Builds - ein geaendertes .pyx wird also automatisch
# neu gebaut, bevor der naechste call_script importiert.
var r := await PythonBridge.call_script("mathx", "dot", [[1.0, 2.0], [3.0, 4.0]])
```

`hot_reload_script()` auf einem `.pyx` liefert `{mode: "cython_invalidate"}`:
Cython hat keinen exec-baren Source-Kontext, deshalb wird das kompilierte
Modul verworfen statt Quelltext neu definiert.

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

Im Editor-Dock: Skript öffnen → `⋯` → „GDScript-Wrapper generieren“.
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