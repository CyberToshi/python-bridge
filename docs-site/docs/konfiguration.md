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

## Cluster-Einstellungen

:::warning Eigene Konfiguration – nicht `PythonBridge.configure`
Alles oben gilt für die **lokale** Bridge (`PythonBridge.configure`). Das
Cluster-Modul hat eine **eigene** Konfiguration; die Schlüssel unten setzt man
mit `ClusterManager.configure(...)` (vor *oder* nach `add_child`).
Schlüssel wie `max_retries` gibt es in **beiden** – sie bedeuten dort aber
nicht dasselbe.
:::

```gdscript
cluster.configure({
    "cpu_block_pct": 90.0,          # früher sperren
    "queue_capacity": 12,           # mehr gleichzeitige Aufgaben annehmen
    "tls_allow_self_signed": true,  # selbstsignierte Zertifikate erlauben
    "max_retries": 3,               # Wiederholungen je Aufgabe
})
```

Unbekannte Schlüssel werden ignoriert (vorwärtskompatibel), Werte werden
begrenzt: `unresponsive_ms` liegt immer über `heartbeat_interval_ms`, und die
READY-Schwelle kann die BLOCK-Schwelle nicht überschreiten – sonst gäbe es
keine Hysterese.

Nicht über `configure()` laufen die **Node-Einstellungen** des
`ClusterManager` – die stehen im Inspektor (oder als `@export`):

| Feld | Standard | Bedeutung |
|---|---|---|
| `auto_discover` | `true` | Rechner automatisch per Broadcast suchen. |
| `discovery_port` | `8766` | UDP-Port der Suche. |
| `auto_connect` | `true` | Gefundene Rechner sofort verbinden. |
| `worker_token` | `""` | Token für Rechner, die keins im Beacon mitsenden. |
| `tls_allow_self_signed` | `false` | Selbstsignierte Zertifikate erlauben (siehe unten). |
| `tls_ca_path` | `""` | Angeheftetes Zertifikat (PEM) für alle Rechner. |
| `mirror_scene` | `false` | Legt einen Kind-Node `ClusterMirror` an, darunter je Rechner `Worker_<id>` und je Aufgabe `Task_<id>`. Der jeweilige Zustand steht als `get_meta("cluster")` bereit – so lässt sich der Cluster wie ein normales Node-System abfragen. |
| `state_path` | `user://cluster_workers.json` | Wo gemerkte Rechner und Token liegen. |

### Erreichbarkeit

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `heartbeat_interval_ms` | `2000` | Abstand der Lebenszeichen des Workers. |
| `unresponsive_ms` | `6000` | Ohne Lebenszeichen so lange → Rechner wird `UNRESPONSIVE`. |
| `disconnected_ms` | `20000` | Danach gilt die Verbindung als getrennt. |

### Kapazität (Capacity Gate)

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `queue_capacity` | `8` | Wie viele Aufgaben ein Rechner gleichzeitig annehmen darf. |
| `cpu_block_pct` | `85.0` | Ab dieser CPU-Last sperrt der Rechner (`BLOCKED`). |
| `cpu_ready_pct` | `70.0` | Darunter ist er wieder `READY` (Hysterese). |
| `ram_block_pct` | `90.0` | Wie `cpu_block_pct`, für den Arbeitsspeicher. |
| `ram_ready_pct` | `75.0` | Wie `cpu_ready_pct`, für den Arbeitsspeicher. |

Laufende Aufgaben werden nie abgebrochen, nur weil ein Rechner gesperrt wird.

### Aufgaben, Versuche, Zuweisung

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `task_timeout_ms` | `120000` | Obergrenze für eine Aufgabe im Manager. |
| `max_retries` | `2` | Zusätzliche Versuche je Aufgabe. |
| `retry_delay_ms` | `500` | Wartezeit vor einem erneuten Versuch. |
| `ack_timeout_ms` | `10000` | So lange darf die Quittung des Workers dauern. |
| `max_dispatch_per_tick` | `8` | Höchstens so viele Startversuche je Durchlauf. |
| `max_payload_bytes` | `3145728` (3 MB) | Obergrenze eines Auftrags (Projekt/Code als Text). |

### Routing (Router-Gewichte)

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `router_locality_bonus` | `60.0` | Vorteil, wenn die Datei schon auf dem Rechner liegt. |
| `router_latency_penalty_per_ms` | `0.5` | Abzug je Millisekunde Latenz. |
| `router_load_weight` | `1.0` | Gewicht der Auslastung. |

Höherer Wert = stärkerer Einfluss. Größerer `router_locality_bonus` schickt
Aufgaben lieber dorthin, wo die Daten schon liegen (siehe [Cluster](./cluster)).

### Sicherheit

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `worker_token` | `""` | Shared Secret. Wird für die Discovery automatisch übernommen; im Beacon steht es nur mit Auto-Pair. Taucht **nicht** in `describe()` auf. |
| `tls_ca_path` | `""` | Angeheftetes Zertifikat (PEM) → echte Prüfung. |
| `tls_allow_self_signed` | `false` | Selbstsignierte Zertifikate bewusst erlauben. **Standard aus** – deshalb scheitert die erste `wss://`-Verbindung sichtbar, bis das Häkchen gesetzt oder ein Zertifikat angeheftet ist. |

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
