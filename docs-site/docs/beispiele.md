---
sidebar_position: 3
title: Zwei Beispielprojekte (Minimum & Maximum)
description: Vom Drei-Dateien-Projekt bis zur vollen Deklaration — beide Enden zum Nachbauen, mit lauffähigem Code.
---

# Zwei Beispielprojekte: Minimum und Maximum

Die Bridge hat eine unangenehme Eigenschaft: sie kann sehr wenig und sehr viel.
Diese Seite zeigt beide Enden an lauffähigem Code — erst das absolute Minimum,
dann alles, was man heute deklarieren kann. Beides liegt im Repository unter
`example/minimal/` und `example/maximum/` und wurde headless ausgeführt.

## 1. Minimum: drei Dateien, ein Aufruf

Mehr braucht es nicht. Kein Python-File, keine Konfiguration, kein Wrapper.

```text
mein_projekt/
├── project.godot
├── addons/
│   └── python_bridge/      ← Release-ZIP hierher entpacken
├── main.tscn
└── main.gd
```

`project.godot` — die zwei Zeilen, die das Plugin beim Aktivieren selbst
schreibt:

```ini
[autoload]

PythonBridge="*res://addons/python_bridge/core/python_bridge.gd"
```

`main.gd` — das ist der komplette Code:

```gdscript
extends Node

func _ready() -> void:
	var started := await PythonBridge.start_instance()
	if started.is_error():
		push_error(started.error_message())
		return
	var result := await PythonBridge.execute("result = 6 * 7")
	print("6 * 7 = ", result.value)   # 6 * 7 = 42.0
```

Was dabei automatisch passiert:

| Schritt | Wer | Dauer |
|---|---|---|
| Python suchen (`python_executable` → `PYTHON_PATH` → `PATH`) | Bridge | sofort |
| venv im Workspace anlegen, `websockets` installieren | Provisioner | beim **ersten** Start 1–3 min |
| Server-Prozess starten, WebSocket + Handshake | Bridge | danach ~1 s |
| Code ausführen, Ergebnis zurück | Executor | Millisekunden |

Das ist bewusst die untere Grenze: kein Skript auf der Platte, keine
Einstellungen, keine Struktur. Für „einmal etwas ausrechnen“ reicht das
dauerhaft.

## 2. Maximum: alles deklarieren, was es gibt

Dasselbe Projekt, nur mit allen Registern. Die folgenden Blöcke sind keine
Wunschliste, sondern der aktuelle Stand von `PythonBridgeConfig.defaults()` —
jeder Schlüssel existiert und wirkt.

### 2.1 Wo die Werte stehen können

| Ort | Reichweite | Typischer Einsatz |
|---|---|---|
| **Projekt → Projekteinstellungen → Python Bridge** | im Projekt, auch im Export | Projekt-Defaults, die das Team teilt |
| **`<workspace_dir>/config.json`** | pro Arbeitskopie | CI, Server, generierte Projekte |
| **`PythonBridge.configure({…})`** | Laufzeit-Code | Sonderfälle, Tests, Bootstrapping |

Präzedenz beim Start (später gewinnt): Defaults → Projekt-Einstellungen →
`config.json` → `configure()`.

`project.godot` mit gesetzten Projekt-Einstellungen:

```ini
[python_bridge]

general/autostart=false
general/workspace_dir="res://python_bridge"
general/python_executable=""
general/dependencies="numpy,scipy"
general/hot_reload_mode="reload_context"
general/auto_generate_wrappers=false
```

`config.json` im Workspace (überschreibt die Projekt-Einstellungen):

```json
{
  "autostart": true,
  "dependencies": ["numpy", "scipy", "pandas"],
  "task_timeout_ms": 120000,
  "data_ref_threshold_bytes": 8388608
}
```

### 2.2 Die vollständige Deklaration

```gdscript
PythonBridge.configure({
	# --- Allgemein -------------------------------------------------------
	"autostart": false,                       # true = Instanz startet mit dem Autoload
	"workspace_dir": "res://python_bridge",   # im Export z. B. user://python_bridge
	"python_executable": "",                  # leer = automatische Suche
	"dependencies": ["numpy"],                # zusätzlich zu websockets
	# --- Tasks, Queue, Backpressure --------------------------------------
	"max_queued_tasks": 2000,
	"max_inflight_per_instance": 2,
	"workers_per_instance": 2,
	"task_timeout_ms": 60000,
	"queue_timeout_ms": 120000,
	"max_payload_bytes": 64 * 1024 * 1024,
	"max_result_bytes": 256 * 1024 * 1024,
	"max_stdout_bytes": 256 * 1024,
	"max_stderr_bytes": 256 * 1024,
	"runaway_grace_ms": 15000,
	# --- Retries ---------------------------------------------------------
	"max_retries": 2,
	"retry_policy": "connection_error",       # none | connection_error | process_error | all
	"retry_delay_ms": 500,
	# --- Batching --------------------------------------------------------
	"max_batch_size": 16,
	"max_batch_delay_ms": 16,
	# --- Frame-Sync ------------------------------------------------------
	"max_dispatch_per_frame": 16,
	"max_results_per_frame": 64,
	"max_inbox_size": 1024,
	"max_decode_bytes_per_frame": 8 * 1024 * 1024,
	# --- Datenebene ------------------------------------------------------
	"data_ref_threshold_bytes": 4096,         # absichtlich klein: DataRef sichtbar
	"file_read_bytes_per_frame": 8 * 1024 * 1024,
	# --- Verbindung / Provisioning ---------------------------------------
	"connect_timeout_ms": 30000,
	"provision_venv_timeout_ms": 120000,      # derzeit reserviert
	"provision_pip_timeout_ms": 300000,       # derzeit reserviert
	"shutdown_timeout_ms": 5000,
	# --- Health & Restart ------------------------------------------------
	"health_check_interval_ms": 5000,
	"health_missed_pong_limit": 3,
	"max_restart_attempts": 3,
	"restart_base_delay_ms": 500,
	"restart_backoff_factor": 2.0,
	"stable_uptime_ms": 30000,
	# --- Hot Reload ------------------------------------------------------
	"hot_reload_mode": "reload_context",      # none | reload_context | restart_instance
	# --- Editor / Wrapper (reserviert) -----------------------------------
	"auto_generate_wrappers": false,          # reserviert, wirkt derzeit nicht
	"wrapper_dir": "res://python_bridge/wrappers",
	# --- Web-Transport (greift nur im Web-Export) ------------------------
	"web_transport": false,                   # true erzwingt Pyodide auch auf Desktop
	"web_worker_url": "bridge_worker.js",
	"web_pyodide_dir": "",                    # lokal gebündelte Runtime
	"web_cdn_url": "https://cdn.jsdelivr.net/pyodide/v0.26.4/full/",
	"web_bundle_url": "bridge_workspace.tar",
	"web_packages": "numpy,scipy,pandas",
	"web_tag": "web",
})
```

Das sind **45 Schlüssel**. Ein `print(PythonBridge.config().size())` bestätigt
den Stand zur Laufzeit.

### 2.3 Zwei Instanzen statt einer

```gdscript
for instance in ["default", "worker"]:
	var started := await PythonBridge.start_instance(instance)
	if started.is_error():
		push_error("Start von %s fehlgeschlagen: %s" % [instance, started.error_message()])
		return
```

`"worker"` ist ein eigener Python-Prozess mit eigenem Kontext, eigener
Speicherbelegung und eigener Crash-Domäne. Aufrufe wählen die Instanz als
letztes Argument:

```gdscript
await PythonBridge.call_script("max_stats", "describe", [werte], {"bins": 4}, "worker")
```

### 2.4 Ein `.py`-Skript, das seine Pakete selbst deklariert

```python
# scripts/app_stats.py
import numpy as np

__bridge_deps__ = ["numpy"]          # Top-Level, Position in der Datei frei


def describe(values, bins=8):
    arr = np.asarray(values, dtype="float64")
    hist, edges = np.histogram(arr, bins=bins)
    return {"count": int(arr.size), "mean": float(arr.mean()),
            "std": float(arr.std()), "hist": hist.tolist(), "edges": edges.tolist()}


def big_matrix(n=64):
    """Ergebnis über der DataRef-Schwelle: kommt als Handle an."""
    return np.arange(n * n, dtype="float64").reshape(n, n)
```

### 2.5 Ein `.pyx`-Modul daneben

```python
# scripts/fastmath.pyx
__bridge_deps__ = []


def dot(list a, list b):
    cdef double total = 0.0
    cdef int i
    for i in range(len(a)):
        total += a[i] * b[i]
    return total
```

Der Aufruf ist identisch zum `.py`-Fall — der Build läuft automatisch davor
(oder explizit über `compile_cython()`).

### 2.6 DataRef statt Payload

Mit `data_ref_threshold_bytes = 4096` rutscht ein 64×64-`float64`-Ergebnis
(32 KiB) über die Schwelle und kommt als Handle an:

```gdscript
var result := await PythonBridge.call_script("max_stats", "big_matrix", [64])
if result.value is PythonBridgeDataRef:
	var ref := result.value as PythonBridgeDataRef
	print(ref.kind, ref.dtype, ref.shape, ref.nbytes)   # ndarray float64 [64, 64] 32768
	var bytes := await PythonBridge.materialize_data(ref)
	# bytes.value ist ein typisiertes Array (hier 64 Zeilen à 64 float64)
	PythonBridge.release_data(ref)
```

### 2.7 Signale, Introspection, Aufräumen

```gdscript
PythonBridge.instance_state_changed.connect(
	func(instance: String, state: String) -> void: print(instance, " -> ", state))
PythonBridge.task_done.connect(func(task: PythonBridgeTask) -> void: print(task.id))
PythonBridge.bridge_event.connect(
	func(instance: String, event: Dictionary) -> void: print(instance, event))
PythonBridge.pulse.connect(func() -> void: pass)

var schema := await PythonBridge.introspect_script("max_stats")
for entry in schema.value:
	print(entry["name"], entry["params"])          # describe, big_matrix
```

## Was das Maximalbeispiel tatsächlich ausgibt

Headless ausgeführt (Godot 4.7, Windows, `example/maximum/maximum.tscn`):

```text
[maximum] 45 Konfigurationsschlüssel aktiv
[maximum] Instanz 'default' bereit
[maximum] Instanz 'worker' bereit
[maximum] validate_script_id: abgelehnt
[maximum] Skripte im Workspace: hello, max_fastmath, max_stats
[maximum] 'default' describe: n=10.0 mean=6.40 std=3.35
[maximum] 'worker' describe: n=10.0 mean=6.40 std=3.35
[maximum] DataRef: kind=ndarray dtype=float64 shape=[64.0, 64.0] nbytes=32768
[maximum] materialisiert: 64 Zeilen x 64 float64
[maximum] Cython: compiler=msvc gebaut=[] übersprungen=["max_fastmath"]
[maximum] Cython dot(...) = 32.0
[maximum] Funktionen in max_stats: describe, big_matrix
[maximum] Ende, Fehler: 0
```

## Was davon wirklich nötig ist

| Kategorie | Schlüssel |
|---|---|
| **Pflicht** | Autoload, `await start_instance()` — alles andere hat Defaults |
| **Fast immer sinnvoll** | `workspace_dir` (im Export `user://`), `dependencies`, `task_timeout_ms` |
| **Nur bei Bedarf** | `workers_per_instance`, Batching, `data_ref_threshold_bytes`, Retries, `hot_reload_mode` |
| **Nur im Web-Export** | `web_*` (Pyodide-Runtime, Pakete, Bundle-URLs) |
| **Reserviert** | `provision_venv_timeout_ms`, `provision_pip_timeout_ms`, `auto_generate_wrappers`, `wrapper_dir` |

Alle Schlüssel im Detail: [Konfiguration](./konfiguration). Die API hinter den
Beispielen: [API-Referenz](./api).
