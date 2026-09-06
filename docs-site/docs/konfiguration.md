---
sidebar_position: 5
title: Konfiguration
description: Alle Einstellungen der Python Bridge – Schlüssel, Standardwerte und Wirkung.
---

# Konfiguration

Die Bridge wird komplett über eine zentrale Konfiguration gesteuert. Du
übergibst ein Dictionary an `PythonBridge.configure()` – alle nicht genannten
Schlüssel behalten ihre Standardwerte.

## Wann konfigurieren?

**Vor dem ersten `start_instance()`.** Die Instanz übernimmt beim Start eine
Momentaufnahme der Einstellungen. Sinnvoll ist ein kleiner Bootstrap-Node,
dessen `_ready()` als Erstes läuft, oder ein eigenes Autoload-Skript:

```gdscript
extends Node

func _ready() -> void:
    PythonBridge.configure({
        "workspace_dir": "user://python_bridge",   # z. B. für exportierte Spiele
        "python_executable": "/usr/bin/python3",   # nur nötig, wenn nicht im PATH
        "dependencies": ["numpy"],
        "data_ref_threshold_bytes": 8 * 1024 * 1024,
    })
    PythonBridge.start_instance("default")
```

`configure()` **merged** über die Standardwerte: fehlende Schlüssel fallen auf
die Defaults zurück, unbekannte Schlüssel werden toleriert (vorwärtskompatibel).
Aktuelle Werte liest du mit `PythonBridge.config()` (Kopie).

## Referenz aller Schlüssel

### Allgemein

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `workspace_dir` | `"res://python_bridge"` | Ablage für Skripte, Wrapper, venv, tmp. Für exportierte Spiele auf einen beschreibbaren Pfad setzen (z. B. `user://python_bridge`). |
| `python_executable` | `""` | Expliziter Python-Pfad. Leer = automatische Suche (Reihenfolge: dieser Schlüssel → `PYTHON_PATH` → `PATH` → Plattform-Fallback). |
| `dependencies` | `[]` | Zusätzliche Pakete, die in die venv installiert werden (zusätzlich zu `websockets`). Beispiel: `["numpy"]`. |
| `autostart` | `false` | Wenn `true`, startet die Instanz `default` automatisch, sobald der Autoload im Baum ist. Für kontrollierte Projekte lieber `false` lassen und explizit starten. |

### Tasks, Queue & Timeouts

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `max_queued_tasks` | `1000` | Backpressure: maximale Anzahl wartender Tasks. Danach lehnt `submit` neue Tasks ab (`TASK_ERROR`). |
| `max_inflight_per_instance` | `1` | Maximale gleichzeitig offene Einheiten pro Instanz (ein Batch zählt als eine Einheit). Für Parallelität zusammen mit `workers_per_instance` erhöhen. |
| `workers_per_instance` | `1` | Worker-Threads im Python-Prozess. Tasks **verschiedener** Kontexte laufen parallel, **gleiche** Kontexte strikt seriell. Hinweis: reine CPU-Python-Last skaliert wegen des GIL nur über mehrere Prozesse. |
| `task_timeout_ms` | `30000` | Ausführungs-Timeout eines Tasks, gemessen ab **RUNNING**. |
| `queue_timeout_ms` | `60000` | Maximale Wartezeit auf einen Worker-Slot (QUEUED). `0` = unbegrenzt. |
| `max_payload_bytes` | `64 MiB` | Obergrenze der geschätzten Task-Payload (Argumente + Source). |
| `max_result_bytes` | `256 MiB` | Obergrenze einer Ergebnis-Nachricht (inkl. eingebetteter Chunks). |
| `max_stdout_bytes` | `1 MiB` | Wie viele Bytes `print()`-Ausgabe eines Tasks erfasst werden; Rest wird verworfen und als `truncated` markiert. |
| `max_stderr_bytes` | `1 MiB` | Wie oben für `stderr`. |
| `max_retries` | `0` | Wie oft ein Task nach Fehlschlag erneut eingereiht wird. **Default: keine Retries.** |
| `retry_policy` | `"connection_error"` | Welche Fehler retry-fähig sind: `none` \| `connection_error` \| `process_error` \| `all`. |
| `retry_delay_ms` | `250` | Wartezeit vor einem Retry. |
| `runaway_grace_ms` | `10000` | Watchdog: Läuft ein per Timeout abgebrochener Job danach weiter (Thread nicht killbar), beendet sich der Prozess selbst und wird über die Restart-Policy neu gestartet. `0` = deaktiviert. |

### Batching

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `max_batch_size` | `32` | Maximale Tasks pro Batch-Nachricht. |
| `max_batch_delay_ms` | `32` | Fenster, in dem eintreffende Tasks gesammelt werden, bevor ein Batch losgeschickt wird. |

Batching greift nur für **kompatible, batchbare Tasks** auf dieselbe Instanz;
`execute()` (temporärer Code) ist bewusst nicht batchbar. Erscheint ein
höherpriorer Task, wird das Fenster sofort geschlossen.

### Frame-Synchronisation (Godot-Main-Thread)

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `max_dispatch_per_frame` | `16` | Maximal verschickte Task-Einheiten pro Frame. |
| `max_results_per_frame` | `64` | Maximal pro Frame an Tasks ausgehändigte Ergebnisse. |
| `max_inbox_size` | `512` | Puffergrenze für eingehende Antworten. Ist die Inbox voll, wird der Dispatch gedrosselt (Backpressure). |
| `max_decode_bytes_per_frame` | `16 MiB` | Wie viele eingehende Bytes pro Frame dekodiert werden. Große Antworten verteilen sich so über mehrere Frames – kein Frame-Stall. |

### Datenebene (DataRefs)

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `data_ref_threshold_bytes` | `16 MiB` | numpy-Ergebnisse ab dieser Größe werden nicht direkt übertragen, sondern als DataRef-Handle gehalten. `0` = deaktiviert (direkter Transfer). |
| `file_read_bytes_per_frame` | `16 MiB` | Bytes pro Frame, die bei einer dateibasierten DataRef gelesen werden (FileAccess, chunkweise). |

### Verbindung & Provisioning

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `connect_timeout_ms` | `20000` | Timeout für den WebSocket-Aufbau nach Prozessstart. |
| `shutdown_timeout_ms` | `3000` | Wartezeit auf die SHUTDOWN-Bestätigung, bevor der Prozess erzwungen beendet wird. |
| `provision_venv_timeout_ms` | `120000` | Reserviert – der Provisioner erzwingt intern aktuell ein festes Limit von 300 s. |
| `provision_pip_timeout_ms` | `300000` | Reserviert – siehe oben. |

### Health-Monitoring

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `health_check_interval_ms` | `5000` | Ping-Intervall an den Python-Prozess. |
| `health_missed_pong_limit` | `3` | Anzahl verpasster Pongs, nach denen die Instanz als abgestürzt behandelt und neu gestartet wird. |

### Crash & Restart

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `max_restart_attempts` | `3` | Maximale automatische Neustart-Versuche nach einem Crash. |
| `restart_base_delay_ms` | `500` | Basis-Verzögerung des ersten Neustarts. |
| `restart_backoff_factor` | `2` | Exponentieller Faktor (0,5 s → 1 s → 2 s …). |
| `stable_uptime_ms` | `30000` | Nach so langer fehlerfreier Laufzeit wird der Neustart-Zähler zurückgesetzt. |

### Hot Reload

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `hot_reload_mode` | `"reload_context"` | `none` (aus) \| `reload_context` (nur der betroffene Python-Kontext wird neu definiert; Standard) \| `restart_instance` (ganzer Prozess wird neu gestartet). |

### Editor / Wrapper (reserviert)

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `auto_generate_wrappers` | `false` | **Reserviert** – Wrapper werden derzeit explizit über den Dock-Button „Generate wrapper“ erzeugt. |
| `wrapper_dir` | `"res://python_bridge/wrappers"` | **Reserviert** – Wrapper werden derzeit unter `<workspace_dir>/wrappers/` abgelegt. |

## Typische Konfigurationsprofile

### Standard (Entwicklung)

```gdscript
PythonBridge.configure({})  # alles Default
```

### Mit NumPy und 2 Worker-Threads

```gdscript
PythonBridge.configure({
    "dependencies": ["numpy"],
    "workers_per_instance": 2,
    "max_inflight_per_instance": 2,
    "data_ref_threshold_bytes": 8 * 1024 * 1024,
})
```

### Exportierte Spiele (beschreibbarer Workspace)

```gdscript
PythonBridge.configure({
    "workspace_dir": "user://python_bridge",
    "autostart": true,
})
```

### Robust gegen Verbindungsabbrüche

```gdscript
PythonBridge.configure({
    "max_retries": 2,
    "retry_policy": "all",
    "retry_delay_ms": 500,
})
```

## Details zu schwierigen Schlüsseln

**`max_inflight_per_instance` + `workers_per_instance`:** Beide steuern
Parallelität. `workers_per_instance` bestimmt die Threads im Python-Prozess,
`max_inflight_per_instance` bestimmt, wie viele Task-Einheiten Godot
gleichzeitig offen hält. Für echte Parallelität beide erhöhen (z. B. beide
auf 4). Gleiche Python-Kontexte bleiben trotzdem seriell – das garantiert
deterministischen Modulzustand.

**`max_retries`:** Standardmäßig `0`. Erst wenn du Retries aktivierst
(`max_retries > 0`), werden fehlgeschlagene Tasks gemäß `retry_policy`
wieder eingereiht. Python-Fehler (`PYTHON_EXCEPTION`) sind nie retry-fähig –
nur Verbindungs-/Prozessfehler je nach Policy.
