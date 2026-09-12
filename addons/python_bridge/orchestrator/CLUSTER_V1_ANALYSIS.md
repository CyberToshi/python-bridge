# Cluster V1 – Analyse & Umsetzungsplan

Diese Datei ist eine **Arbeitskarte**, keine User-Doku. Sie wird erweitert, sobald
Details von dir kommen.

## 1. Ziel für V1 (aus Auftrag)

Ein kleines, benutzbares System, das Python-Aufgaben auf andere PCs im gleichen
LAN verteilt, **ohne**:

- VPN, Docker, Router-Konfiguration, Portfreigaben
- manuelle IP/Port-Eingabe durch den Benutzer
- manuelle Terminalbefehle (Worker-Start, Python-Kommando)
- Ordner-/Server-Manauf dem Worker (IDEAL-FALL; V1 kann damit beginnen,
  dass der Worker lokal läuft, bis die Portable-App da ist)

Zielarchitektur (ohne Neuerfindung):

```text
ClusterManager (Node)
├── Worker(s)       # entdeckte / verbundene Rechner
├── Task(s)         # Python-Aufgaben (aus der bestehenden Bridge-Task-Idiom)
└── Scheduler       # wählt Worker, triggert Transfer, triggert Ausführung
```

**V1 darf einfacher sein als der Auftrag-Heimatplan**, aber sie muss mit dem Bestand
funktionsfähig bleiben und Stage-kompatibel bleiben.

---

## 2. Was es bereits gibt (bestand und was wirklich genutzt wird)

### 2.1 Bestehende Godot-Architektur

- **Autoload-Singleton `PythonBridge`** (`addons/python_bridge/core/python_bridge.gd`).
  Registriert als Node `PythonBridge` im Root. Verantwortet Instanzen, Scheduler,
  TaskManager, ScriptRegistry, Introspection, DataRefs.
- **Task-Idiome**: `PythonBridgeTask` und `PythonBridgeTaskManager` / `_submit_and_await`
  mit `task.done` Signal, `task.result`, `task.instance_id`. Tasks sind also bereits
  ereignisgesteuert und betreffen `PythonBridgeResult`.
- **Wrapper-Generator**: erzeugt `.gd`-Dateien, die `PythonBridge.call_script(...)` nutzen.
  Das ist die vorhandene "benutzerfreundliche Script-Auswahl in der Godot-Node-Kette".

### 2.2 Bestehender vorgelagerter Worker/Transport (Orchestrator)

- Dispatcher ist **transportunabhängig**: `dispatch_requested(task_id, server_id, python_task, required_files)`
  und `cancel_requested(task_id, server_id)`.
- Transport (`orchestrator_transport.gd`) ist ein realer WebSocket-Transporter zu einem
  externen Worker-Prozess.
- Worker (`orchestrator_worker.py`) ist ein eigenständiger Python-Process mit Token-Auth,
  Pfad-Schutz, Limits.

### 2.3 Was hier funktioniert und wiederverwendet werden kann

- **Task model / Scheduler-Semantik**: die Submite-/Done-Semantik bleibt.
- **Worker-Service-Semantik** (ein Prozess, der Tasks annimmt und ausführt): solide.
- **Safety**: Pfad-Schutz, Limits, eindeutige Task-IDs, Retry-Grenzen sind bereits
  im Werkzeug und können 1:1 oder verschränkt bleiben.
- **Autoload-Nutzung**: Godot hat ein Node-System. Die Cluster-Logik kann
  `ClusterManager` als Node im Main-Scene haben und das `PythonBridge`-Singleton als
  Task-Quelle / Ergebnis-Übernahme nutzen. Nicht neu erfinden.

---

## 3. Was für V1 angepasst werden muss

### 3.1 Transport und Discovery

- Bode aktueller Transport braucht Port/IP von Hand. Für V1 gilt:
  **Discovery + Auto-Connection (LAN)**, nicht manuelle Eintragung.
- Das ist **neu**: UDP-Broadcast/Broadcast-Hello oder eine LAN-basierte Antwort, plus
  persistente Verbindung danach.
- Trennung Discovery / eigentliche Kommunikation ist korrekt und muss bleiben.

### 3.2 Manager-Node und Godot-Node-Modell

- Aktuell gibt es keinen `ClusterManager`-Node im Haupt-Szenenbaum; der Orchestrator-Dock
  ist editorisch und nutzt den Core unter der Haube.
- Kompatibel mit dem Auftrag: Cluster kann als Node im Baum entstehen, das `PythonBridge`
  zum Erzeugen/Submite von Tasks und zum Auswerten von `task.done` nutzt, und
  das Transport/Worker-System darunter hängt.

### 3.3 Worker-Anwendung statt Terminalbefehle

- Aktuell ist der Worker ein Python-Skript, das man in einem Terminal startet.
- V1-Vorgabe: **Worker soll keine Terminal-Eingabe erfordern**.
- Darum muss es eine Worker-Anwendung geben:
  - Windows: `.exe` / kleine eigenständige App (oder Python-symlink/App-Launcher),
  - Linux: eigenständiges Starter-Paket.
- Ideal für V1: Worker führt **kein Python selbst installieren**, aber V1 darf bei
  fehlendem Python eine klare Meldung zeigen; voll “ohne Python vorhanden” ist
  technisch nicht trivial (Python-Loader wäre ein eigenes Thema). Falls du das
  zwingend willst, wird's eine separate Schicht.

### 3.4 Script/Code auf Worker

- Bestandsworker benötigt `scripts/` lokal. V1 will Tasks **von Manager zu Worker**,
  ohne Vor-Ordner-Management auf jeden PC.
- Das ist **der größte Unterschied zum Bestand**: Manager muss Task-Code/Param-Daten
  zum Worker geben. V1 darf aber stepwise bleiben:
  - Eerst eine strikte Fallback-Lösung: Task-Code via Transport als definierter Payload,
  - Worker führt ihn in temp-Workdir aus.
  - Datei/Input kann zwischenlaufend sein (dann Chunk/Verification später, Phase-8-Niveau).

---

## 4. Was neu implementiert werden muss (V1)

### 4.1 LAN-Discovery + Auto-Verbindung

- Discovery: Broadcast (UDP) mit einer simplen Hello/Correlation.
- Nach Discovery: persistente Verbindung (WebSocket). Re-Connect-Logik vorhanden.

### 4.2 ClusterManager-Node

- Node im Main-Scene-Tree (wird als Kind von Main oder oben eingehängt).
- Steuert: Worker-Collection, Task-Collection, Scheduler-Wahl, Discovery-Start,
  Verbindungs-Zustand, GUI-Anbindung (wenn GUI gewünscht ist; V1 kann
  leicht eine einfache Godot-UI oder Panel sein).

### 4.3 Task-Modell (Cluster)

- Tasks müssen **auf Worker geeignet** sein: V1 soll die bekannte Godot-Seite
  nutzen (`PythonBridge.call_script` etc.), und Cluster entscheidet **weiterleiten**.
- Möglichkeit: Task wird im Manager 1:1 aus bestehendem Model gebildet und dann
  durch den Scheduler zur Ausführung auf Worker gesendet. Das passt zum
  `task.done` Schema.

### 4.4 Worker-bedingte Voraussetzungen

- Worker muss:
  - Tasks empfangen
  - Code/Input ausführen
  - Ergebnis + Status + stdout/stderr zurückmelden
  - Discovery/Heartbeat/Connect unterstützen

---

## 5. Was bewusst zurückgestellt wird

- Mehrere Worker + Fortgeschrittenes Scheduling (wird später)
- Datenmengen / große Transfers / File Registry (Phase 6-8-Roadmap)
- Worker-Sandbox/Isolation (spaeter)
- VPN/Komplexes Netz (spaeter)
- Docker, virtuelle Netze

---

## 6. Phasenplan V1

### Phase 0: Inventar + Schnittstellen klären (jetzt)

- Vorhandene Godot-Node-Struktur und `PythonBridge` Singleton verstehen.
- Festlegen, ob ClusterManager **eigener Node** in der Scene sein soll, oder ob
  das Dock/Oberfläche genutzt wird.
- Festlegen, welcher Pool: **Task-Code und Inputs vom Manager an Worker übergeben**,
  oder Worker hat lokalen `scripts/`-Ordner (falls V1 halbjährlich rückwärts
  möglich sein soll).

### Phase 1: Discovery + Verbindung

- Discovery-Server und Client-Komponente.
- Manager erkennt Worker automatisch, persistiert Verbindung.
- Trennung Discovery/Task-Kommunikation.

### Phase 2: Aufgabenverteilung

- ClusterManager sendet Task-Code/Inputs an Worker.
- Worker führt aus, meldet Ergebnis, stdout/stderr, Status.
- Godot-Seite kann Tasks aus bestehendem Model bilden und Warten.

### Phase 3: GUI (benutzerfreundlich)

- Einfache Godot-Oberfläche: Worker-Liste, Aufgaben-Liste, Status, Resultate.
- Benutzer startet Tasks per Aufklapp-Menü oder Button (von bestehender Godot-UI bewahrt).

### Phase 4: Auto-Start Worker-Anwendung

- Worker-Anwendung (Windows/Linux) startbar ohne Terminal.
- Auto-Connect nach Start.

### Phase 5: Robustheit + Offline

- Timeouts, Offline-Erkennung, Wiederverbinden.

---

## 7. Offene Entscheidungen

- **Worker-Art V1**: eigenständige Windows-/.exe-App, oder Python-Portablerunner,
  oder Node-basierte Godot-Instanz?
- **Task-Code-Lieferung an Worker**: Manager sendet Code, oder Worker hält `scripts/`-Ordner? (Frontend-Ansatz)
- Soll **ClusterManager als Node im Main-Scene-Tree** von dir genutzt werden (wie
  ein ClusterManager-Node, den du in Szenen einhängen kannst), oder nur als
  Steuerung/Oberfläche (Action-basiert, kein eigener Node im MainTree)?

Sobald diese Punkte stimmen, kann ich Phase 1 konkret und ohne Mehr konzipieren.

---

# 8. Stand der Umsetzung (V1)

Getroffene Entscheidungen (ohne Rückfrage, weil logisch aus dem Auftrag):

* **ClusterManager ist eine Node** im Godot-Node-System
  (`addons/python_bridge/cluster/cluster_manager.gd`).
* **Worker ist eine App**, nicht nur ein Skript: `worker/worker_app.py`
  (dunkle Oberfläche, Doppelklick, Windows + Linux). Der headless-Modus bleibt
  über `orchestrator_worker.py` erhalten.
* **Der Manager liefert den Code** als Inline-Source mit; der Worker führt ihn in
  einem temporären Arbeitsverzeichnis aus. Kein Skript-Ordner nötig.
* **Discovery ist UDP-Broadcast** (Port 8766) und getrennt von der
  Aufgabenkommunikation (WebSocket, Port 8765).

## Umgesetzt

| Baustein | Datei |
|---|---|
| LAN-Discovery (Beacon, Suchanfrage, Timeout, ID-Bereinigung) | `cluster/cluster_discovery.gd` |
| Manager-Node (Kern, Auto-Connect, Task-API, Szenen-Spiegel, Persistenz) | `cluster/cluster_manager.gd` |
| Dunkle Runtime-Oberfläche (Worker, Aufgaben, Protokoll, Schalter) | `cluster/cluster_panel.gd` |
| Fertige Szene | `cluster/cluster_main.tscn` |
| Worker-Discovery + temporäres Arbeitsverzeichnis + Code ohne lokale Datei | `worker/orchestrator_worker.py` |
| Worker-App (Token, Start/Stop, Log, Paket-Installation) | `worker/worker_app.py` |
| Doppelklick-Starter | `worker/Worker-Windows.bat`, `worker/start_worker_linux.sh` |
| Eigenständiger Build | `worker/worker.spec` |
| Aufbau-Anleitung | `CLUSTER_V1_SETUP.md` |

## Nachgewiesen (headless, echte Prozesse)

* `tests/orchestrator/test_cluster_v1.gd` – Discovery + Manager (56 Prüfungen).
* `tests/orchestrator/run_cluster_e2e.sh` – kompletter Ablauf gegen einen echten
  Worker **ohne Skript-Ordner**: Discovery → Auto-Verbindung → `run`- und
  `call`-Aufgabe mit übertragenem Code → Ergebnis → Reservierung frei.
* `tests/orchestrator/run_transport_e2e.sh` – bestehender Transportpfad bleibt grün.

## Nachtrag: Projekte, Cython und Feinschliff

### Neu (Plug & Play fuer Builds)

* `worker/python_build.py`: erkennt Python/OS/Architektur/pip/venv/Compiler,
  legt isolierte Umgebungen im Benutzer-Cache an, installiert Requirements und
  Build-Werkzeuge, kompiliert `.pyx`/`setup.py`, fuehrt einen **Build-Cache**
  ueber einen Fingerabdruck (Dateien, Requirements, Umgebung, Buildlogik) und
  raeumt sich selbst auf. Kein System wird veraendert, keine Adminrechte noetig.
* `orchestrator_worker.py`: Projekt-Modus (`files`, `entry`, `requirements`,
  `build`), Ausfuehrung im temporaeren Arbeitsverzeichnis, `{"t":"progress"}`
  waehrend Vorbereitung/Build, Ergebnis mit `build`-Bericht, `error_hint`,
  `error_action`, `stage`, `--diagnose`, `--cache-dir`, `--no-build`,
  `--no-auto-install`.
* Manager: `submit_project()`, `submit_project_dir()`, `collect_project_dir()`,
  `configure()`, Fortschritt/Stufe/Hinweis/Build im Aufgabenbild,
  Payload-Groessenpruefung mit klarer Ablehnung.
* Oberflaeche: Projektordner-Knopf, Fortschritts- und Build-Spalte,
  Loesungshinweis als Tooltip, Arbeitsweise-Toggles; Worker-App mit
  „Umgebung pruefen“ und Live-CPU/RAM/Verbindungszustand.

### Gefundene und behobene Fehler (Audit)

1. **Aufgaben wurden nach einem Ausfall/Timeout nie wieder gestartet.**
   Wartende Aufgaben wurden nur beim Erstellen einer neuen Aufgabe verteilt;
   ein Task, der nach einem Worker-Verlust in die Queue zurueckkam, blieb dort
   fuer immer liegen. Jetzt verteilt der Manager regelmaessig selbst.
2. **Versuchsnummer im Auftrag war veraltet**, dadurch wurde der Worker-ACK als
   „alter Versuch“ verworfen und der Task lief in einen ACK-Timeout (Ursache
   fuer wiederholte Fehlversuche nach einem Reconnect).
3. **Spaet eintreffender Abbruch konnte den neuen Versuch mitbeenden** - der
   Abbruch traegt jetzt die Versuchsnummer, und der Worker ignoriert ihn, wenn
   bereits ein neuerer Lauf aktiv ist.
4. **Reconnect-Spam:** alle 1,5 s erneut versuchen und protokollieren; jetzt
   Backoff bis 30 s und ruhigeres Log.
5. **Stilles Senden:** grosse Auftraege konnten ohne Meldung scheitern; jetzt
   Puffergroessen gesetzt, Rueckgabecode geprueft und eine Groessengrenze mit
   klarer Begruendung.
6. **Unbegrenztes Wachstum:** Ergebnis-Speicher im Manager begrenzt (LRU),
   Cache-Aufraeumen im Worker, Dedup-/Replay-Grenzen unveraendert aktiv.
7. **Kein "haengen bleiben":** unerwartete Ausnahmen in einer Aufgabe werden
   zu einem klaren Fehlerergebnis statt zu einem haengenden Task.

### Nachgewiesen

* `tests/orchestrator/test_worker_project.py`: 45 Pruefungen (Projekte,
  Requirements, Cython-Build, Cache, Rebuild, Build-/Laufzeitfehler, Hinweise,
  Pfad-Ausbruch, Abbruch, Parallelitaet, Altverhalten).
* `test_cluster_v1.gd`: 91 Pruefungen (zusatzlich: Projekt-Payload,
  Ordner-Einlesen, Groessenlimit, Fortschritt, Hinweis-Weitergabe).
* `run_cluster_e2e.sh`, `run_cluster_offline_e2e.sh`:
  echter Worker, echter Cython-Build, echter Prozess-Kill und Wiederaufnahme.

## Bewusst noch offen (unverändert)

* Datei-Transfer für große Eingabedaten (File Registry, Chunk-Transfer, SHA-256).
* Compiler-Auto-Installation (braucht Adminrechte) - dafuer gibt es einen
  verstaendlichen Hinweis in der Worker-App.
* TLS/VPN-Fähigkeit, Worker-Sandbox, Sub-Graphs, erweiterte Scheduling-
  Strategien.
* Broadcast-Discovery funktioniert nur im eigenen LAN (kein AP-Isolation-Netz);
  für diesen Fall bleibt der manuelle Eintrag im Panel.
