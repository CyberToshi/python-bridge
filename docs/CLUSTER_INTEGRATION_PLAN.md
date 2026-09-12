# Cluster-Integration: Python Bridge → Verteilte Worker

Status: **Umgesetzt (v0.4.0)** – dieses Dokument bleibt als Planungs- und
Entscheidungsgrundlage erhalten. Die tatsächliche Umsetzung weicht bewusst in
zwei Punkten vom ursprünglichen Plan ab (kein Docker/Swarm, keine
Portfreigaben: es geht ausschließlich um dasselbe lokale LAN):

| Dokumentation zur Umsetzung | Inhalt |
|---|---|
| [`docs-site/docs/cluster.md`](../docs-site/docs/cluster.md) | Überblick, Architektur, Node-Nutzung |
| [`docs-site/docs/cluster-setup.md`](../docs-site/docs/cluster-setup.md) | Aufsetzen von Hauptrechner und Clients |
| [`docs-site/docs/cluster-sicherheit.md`](../docs-site/docs/cluster-sicherheit.md) | Token, TLS, Vertrauensarten, Grenzen |
| [`addons/python_bridge/orchestrator/CLUSTER_V1_SETUP.md`](../addons/python_bridge/orchestrator/CLUSTER_V1_SETUP.md) | Aufsetzen in 5 Minuten, Firewall, Fehlersuche |
| [`addons/python_bridge/orchestrator/SAFETY.md`](../addons/python_bridge/orchestrator/SAFETY.md) | Sicherheitsprüfung, Funde, ehrliche Grenzen |
| [`versions/RELEASE_NOTES_0.4.0.md`](../versions/RELEASE_NOTES_0.4.0.md) | Was in welcher Version dazukam |

Ursprünglicher Planungstext (zur Nachvollziehbarkeit der Entscheidungen):

Zielbild: Die lokale Bridge bleibt der Kontrollkern. Ein Task kann wahlweise
lokal oder an einen entfernten Worker (gleiches Netz / Swarm) gehen. Für den
Entwickler ändert sich wenig: `start_instance("worker-a")` verbindet eben
eine *remote* statt einer lokalen Instanz; große Daten bleiben hinter
DataRef-Handles, der Transport wird von der Bridge entschieden.

---

## 1. Was der Prototyp bereits zeigt (Wiederverwendung)

| Prototyp-Element (`ClusterComputing/`) | Nutzen für die Bridge |
|---|---|
| Manager als zentrale WebSocket-Taskverteilung | Der *Manager* kann 1:1 die Rolle des Godot-seitigen Schedulers als Netzwerk-Dienst übernehmen |
| `register` / `task_result`-Protokoll mit Retry | Deckt sich mit unserem Task-Zustandsmodell (QUEUED→RUNNING→COMPLETED) |
| `available_workers`-Queue + Dispatcher | Routing-Muster, das der Scheduler schon lokal kann |
| Docker-Compose/Swarm (Manager + N Worker) | Deployment-Muster für "Worker überall im Netz" |
| Einfaches JSON-Payload (`submit_task`) | Nur für kleine Payloads; große Daten NICHT über JSON |

Grenzen des Prototyps (nicht übernehmen):
- Kein Task-Timeout / keine Runaway-Erkennung auf Workerseite
- Kein Health-Monitoring außer "Verbindung weg"
- Kein strukturiertes Fehlermodell (nur `status: success`)
- Daten immer als JSON eingebettet → für große Daten ungeeignet
- Worker laufen ohne Isolation pro Task (Zustand geteilt)

## 2. Architektur-Entscheidungen

1. **WebSocket bleibt der Control Channel** (auch remote). Der Manager ist
   ein Gateway, das das *bestehende* Bridge-Protokoll spricht – keine zweite
   Protokoll-Welt.
2. **Worker = bestehender Bridge-Server.** Ein entfernter Worker ist
   nichts anderes als ein `run_server.py`-Prozess, der per Flag als
   "extern erreichbar" gestartet wird (Bind an 0.0.0.0, Manager-URL als
   Registrierungsziel). Damit gelten Timeout-, Worker-Slot-, Watchdog- und
   DataRef-Logik unverändert.
3. **Manager kennt Tasks, nicht Quellcode-Inhalte.** Ein Task trägt
   `source_hash` + kontextuelle Referenz; der Worker fordert fehlende
   Skript-Bytecode/Quellen gezielt nach (`script_get`), statt sie pro Task
   zu senden → entspricht unserem "Persistent Context"-Prinzip.
4. **Daten bleiben hinter DataRef-Handles.** Für große Ergebnisse liefert
   der Worker einen `data_ref`-Descriptor. Die Datei-basierte
   Materialisierung (Phase 4) wird remote zur *Pull*-Operation über
   HTTP/HTTPS oder einen schlichten Datei-Endpunkt statt Shared Memory
   (Shared Memory ist nur für lokal sinnvoll).
5. **Instanz-Routing bleibt explizit.** `instance := "worker-b"` wählt die
   Instanz; der Scheduler verteilt *nicht* stillschweigend zwischen lokal
   und remote, weil persistenter Context pro Worker gilt.

## 3. Komponenten (neu im Addon)

```
addons/python_bridge/
  core/remote/
    remote_manager.gd      # Godot-seitiger Client zum Cluster-Manager
    remote_worker.gd       # registriert sich beim Manager (nur im Worker-Build)
    cluster_client.py      # Python: Manager-Prozess (aus Prototyp übernommen,
                           # erweitert um Health/Timeout/Fehlermodell)
    worker_entry.py        # Python: run_server.py + Registrierungsflag
  tools/cluster/
    docker-compose.yml     # aus ClusterComputing/, angepasst an Bridge-Image
    Dockerfile.worker      # venv + python_bridge + run_server.py
    Dockerfile.manager
```

## 4. Datenfluss

```
Godot (lokal)                      Cluster-Manager                 Remote-Worker
start_instance("w1") ──connect──►  verwaltet Instanzen ──connect──► run_server.py
submit_task(task) ───────────────► queue + routing ───────────────► context + slots
        ◄── task_result / error ──◄         ◄── result / error ──────
DataRef (groß): Worker schreibt Datei; Godot holt sie über HTTP-GET
  (FileAccess-HTTP-Client) statt über den WS-Kanal.
```

## 5. Phasen

| Phase | Inhalt | Akzeptanz |
|---|---|---|
| C1 | Worker-Startmodus (`--manager ws://...`), Manager aus Prototyp erweitern (Timeout, Fehler, Health) | 1 Worker registriert sich; Godot startet remote Instanz; kleiner Task läuft |
| C2 | Remote-DataRef: Datei-Endpunkt + HTTP-Materialisierung | 16-MiB-Array remote erzeugen und in Godot materialisieren |
| C3 | Swarm-Deployment (Compose aus Prototyp), mehrere Worker | 3 Worker, parallele Tasks, Worker-Ausfall → Retry auf anderen Worker |
| C4 | Skript-Cache remote (`script_get`), Hot Reload über Manager | Änderung am Skript erreicht alle Worker gezielt |
| C5 | Shared-Memory-Fallback nur lokal; Remote-Zero-Copy nur wenn später sinnvoll | Dokumentierte Transportmatrix |

## 6. Bewusst NICHT sofort

- Apache Arrow / Zero-Copy über Netz: erst bei gemessenem Bedarf
- Task-Migration zwischen Workern (Context-Zustand wandert nicht)
- Öffentliche Cluster (TLS/Auth) vor C3-C5 (erst LAN + Swarm)

## 7. Offene Entscheidungen

- Manager als *eigener* Python-Prozess (empfohlen) oder als Godot-Node?
- Remote-Auth (Pre-Shared Token) ab wann zwingend?
- HTTP-File-Endpunkt vs. WS-Binär-Chunks für remote DataRefs?
