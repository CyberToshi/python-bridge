# Task Orchestrator (visueller Python-Task-Orchestrator)

Zusätzliches, **rein additives** Modul der Python Bridge. Es ersetzt nichts:
Python bleibt normaler Python-Code, die Bridge führt Aufgaben weiterhin aus.
Der Orchestrator sitzt als Ebene darüber und entscheidet:

> **Auf welchem verbundenen Rechner** soll eine bestehende Python-Aufgabe
> laufen, **welche Eingabedateien** braucht dieser Rechner und **wann** darf
> die Aufgabe starten?

Der Python-Worker bleibt für die eigentliche Ausführung zuständig; der
Orchestrator ist für **Verteilung und Überwachung** zuständig.

## Status

| Phase | Inhalt | Status |
|---|---|---|
| 1 | Analyse des Bestands | ✅ |
| 2 | Server Manager + Server Nodes + Heartbeat | ✅ `core/orchestrator_server*.gd` |
| 3 | Task Model + Task State Machine | ✅ `core/orchestrator_task*.gd` |
| 3b | Graph-Modell (Node-Typen, Verbindungen, Speichern/Laden) | ✅ `core/orchestrator_graph_model.gd` |
| 3c | Editor-Dock (GraphEdit) | ✅ `editor/orchestrator_panel.gd` |
| 4 | Router + Capacity Gate (Auswahl-/Schedulinglogik) | ✅ `core/orchestrator_router.gd` |
| 5 | Task Assignment + ACK + Retry + Reassignment | ✅ `core/orchestrator_dispatcher.gd` |
| 5b | Echter Transport (WebSocket) + Worker-Prozess | ✅ `transport/` + `worker/` |
| 5c | Security: Token-Auth, Pfad-Schutz, Limits | ✅ `worker/orchestrator_worker.py` |
| 12 | **Cluster V1:** LAN-Discovery, automatisches Verbinden, Node-Integration | ✅ `addons/python_bridge/cluster/` |
| 12b | **Worker-App** (dunkle Oberfläche, Doppelklick, kein Terminal) | ✅ `worker/worker_app.py` |
| 12c | **Projekt-/Cython-Builds automatisch** (venv, pip, Compiler, Cache) | ✅ `worker/python_build.py` |
| 12d | Fortschrittsmeldungen, Build-Bericht, Fehler-Hinweise im UI | ✅ Transport/Dispatcher/Panel |
| 6–8 | File Registry, Chunk-Transfer + Verifikation, Task/File-Dependencies | ⏳ geplant |
| 9–11 | Ausbau Monitoring, Sub-Graphs | ⏳ geplant |

## Cluster V1 – der einfache Weg

Wer nicht manuell IP und Token eintragen will, benutzt das Cluster-Modul:

```text
ClusterPanel (dunkle Oberfläche)   ├── ClusterManager (Node)
                                   │     ├── ClusterDiscovery (UDP, LAN)
                                   │     └── Orchestrator-Kern + Transport
                                   └── Worker-App auf den anderen PCs
```

* **Manager:** `addons/python_bridge/cluster/cluster_main.tscn` starten oder
  `cluster_panel.gd` als Skript auf ein `Control` legen. Übernimmt Discovery,
  Verbindung, Aufgaben und Anzeige.
* **Worker:** `worker/Worker-Windows.bat` bzw. `worker/start_worker_linux.sh`
  (Doppelklick). Die App erzeugt das Token selbst, startet den Worker und zeigt
  Log/Status.
* **Kein manuelles IP-Eintragen:** die Worker melden sich per UDP-Broadcast
  (Standardport 8766) im LAN; der Manager verbindet sich danach per WebSocket.
* **Code-Übertragung:** der Manager schickt den Python-Quelltext als
  Inline-Source mit; der Worker führt ihn in einem temporären Arbeitsverzeichnis
  aus. Vorbereitete Skript-Ordner auf den Clients sind **nicht** nötig.
* **Verschlüsselt ab Werk (TLS):** die Worker-App startet den Worker mit
  `wss://`; er meldet das samt Zertifikat-Fingerabdruck im Discovery-Beacon, und
  der Manager verbindet automatisch verschlüsselt. Selbstsignierte Zertifikate
  erlaubt man einmal per Häkchen im Panel – oder man heftet `worker-cert.pem` an
  und bekommt echte Prüfung. Anleitung: Abschnitt 3b in
  [CLUSTER_V1_SETUP.md](CLUSTER_V1_SETUP.md).
  **Nicht** verschlüsselt ist der Beacon selbst (unverschlüsselter UDP-Broadcast)
  und ein Worker, den man von Hand **ohne** `--tls-self-signed` startet.
* **Projekte & Cython:** ein ganzer Projektordner kann gesendet werden. Der
  Worker legt eine isolierte Umgebung an, installiert `requirements.txt`,
  kompiliert `.pyx`/`setup.py` und cached den Build (Fingerabdruck aus Quellen,
  Requirements, Python-Version und Plattform). Der Benutzer tippt weder `pip`
  noch `cython` noch Compiler-Befehle. Siehe
  [CYTHON_AND_BUILD.md](CYTHON_AND_BUILD.md).
* **Einfach in der Oberfläche:** Datei/Projektordner wählen, optional über
  **Dateien** Eingabedateien anhängen (Anzeige mit Anzahl und Größe), Ziel
  wählen, **Aufgabe starten**. Große Eingaben zeigen beim Warten den Transfer
  mit Balken; die Spalte *Fortschritt* sagt „Daten werden übertragen“ statt
  „wartet“.
* **Große Eingabedateien (Phase 6–8):** Dateien werden inhaltsadressiert
  registriert (SHA-256), in 256-KB-Stücken übertragen und **vor** dem Start der
  Aufgabe auf dem Zielrechner geprüft. Ist die Datei schon da, findet **kein**
  Transfer statt. Der Task steht bis dahin auf `WAITING_FOR_DATA`; im Programm
  liegen die Dateien im Arbeitsverzeichnis und als `input['_files']`. Grenzen
  (Größe pro Datei, Cache, Restplatz) sind einstellbar und werden im Klartext
  gemeldet. Details: Abschnitt 3a in `CLUSTER_V1_SETUP.md` und
  [SAFETY.md](SAFETY.md).

Schritt-für-Schritt (inkl. Firewall, Sicherheit, Fehlersuche):
**[CLUSTER_V1_SETUP.md](CLUSTER_V1_SETUP.md)**. Sicherheit, Stabilität und
bewusste Grenzen: **[SAFETY.md](SAFETY.md)**.

**Wichtig:** Es gibt hier **keine zweite Kommunikationswelt**. Der Kern ist
transportunabhängig: `on_heartbeat(...)` speist Server-Metriken ein, `tick(...)`
treibt Timeouts, und der Dispatcher meldet seine Absicht über die Signale
`dispatch_requested` / `cancel_requested`. Wer das verschickt (bestehende
Bridge, Cluster-Manager, …) ist Sache der darüberliegenden Schicht. Das Dock hat
einen **Demo-Modus** (lokale Simulation von Heartbeat und Worker) nur zur
Anzeige – ausdrücklich kein Kommunikationsweg.

## Architektur

```text
Graph Model (UI)          data-only, speicher-/ladbar
     │
Server Manager ──┐
Task Manager  ───┼──► Dispatcher ──► Router ──► gewählter Server
Config       ───┘         │
                          ├─ ACK-/Task-Timeouts
                          ├─ Retry / Reassignment
                          └─ Kapazitätsreservierung
                                   │
                          (Transport: bestehende Bridge)
```

Die UI rendert nur das Graph-Modell und ruft die Manager (§23) – die
Orchestrierungslogik liegt vollständig im transportunabhängigen Kern.

## Zustände

**Server:** `READY 🟢` · `LIMITED 🟡` · `BLOCKED 🔴` · `UNRESPONSIVE 🟠` · `DISCONNECTED ❌`
**Task:** `CREATED → QUEUED → ASSIGNED → WAITING_FOR_DATA → RUNNING → COMPLETED`
sowie `FAILED`, `RETRYING`, `CANCELLED`.

Zustandsübergänge sind **validiert** (`OrchestratorTaskManager.allowed_transition`);
ungültige Übergänge werden abgelehnt statt still den Zustand zu verbiegen.
`RUNNING → QUEUED` ist z. B. nicht erlaubt – ein Reassignment eines laufenden
Tasks läuft deshalb über `RETRYING` (`reassign()` erledigt das intern).
`COMPLETED` und `CANCELLED` sind terminal; ein abgeschlossener Task wird **nie**
erneut ausgeführt.

## Capacity Gate (Hysterese)

Damit ein Server nicht ständig zwischen `READY` und `BLOCKED` flattert:

```text
CPU >= 85 %                      → BLOCKED
CPU <= 70 % (erst aus BLOCK)     → READY
dazwischen (nicht blockiert)     → LIMITED
```

Zusätzlich zählt die Queue: `effective_queue_used = max(worker-Meldung, vom
Orchestrator reservierte Slots)`. Der Dispatcher **reserviert** bei jeder
Zuweisung einen Platz und gibt ihn bei Abschluss, Fehler oder Abbruch wieder
frei – so kann er zwischen zwei Heartbeats nicht über die Kapazität hinaus
zuweisen.

Alle Schwellen und Timeouts liegen in `OrchestratorConfig` und sind
konfigurierbar (`unresponsive_ms`, `disconnected_ms`, `queue_capacity`,
`cpu_block_pct`, `cpu_ready_pct`, `ram_block_pct`, `ram_ready_pct`,
`ack_timeout_ms`, `task_timeout_ms`, `max_retries`, `retry_delay_ms`, …).

## Router (Phase 4)

Zwei Stufen, bewusst getrennt:

1. **Eignung (harte Kriterien):** Gate offen, freie Slots, Ziel-Pin
   (`task.target`) und erfüllte Anforderungen (`requirements`:
   `gpu`, `min_free_ram_pct`, `min_free_slots`, `max_cpu_pct`).
2. **Bewertung (Score, höher = besser):**

```text
score = 100
        − router_load_weight              · Auslastung (CPU/RAM/Queue)
        − router_latency_penalty_per_ms   · Latenz
        + min(freie Slots, 4) · 2
        + 10   wenn READY (statt LIMITED)
        + router_locality_bonus   wenn alle required_files auf dem Server liegen
```

Punkt 2 ist **Data Locality** (§17): Liegt eine benötigte Datei bereits auf
einem Server, wird dieser bevorzugt – ein Transfer wird eingespart. Der Bonus
(Standard 60) ist bewusst groß genug, um moderate Mehrlast zu überstimmen.

Modular erweiterbar ohne Umbau:
* `router.file_locality` – Hook `(file_id, server_id) -> bool` (später die File Registry),
* `router.score_hook` – Hook `(server, task, base_score) -> float` für eigene Scheduling-Ideen.

Die Sortierung ist deterministisch (Score absteigend, bei Gleichstand
Server-ID aufsteigend).

## Dispatcher (Phase 5)

* **Zuweisung:** wartende Tasks nach Priorität (`HIGH` → `LOW`), pro Tick
  begrenzt durch `max_dispatch_per_tick`.
* **ACK-System:** Nach dem Verschicken läuft `ack_timeout_ms`. Ohne gültiges ACK
  bleibt der Task unter Kontrolle des Orchestrators und wird neu bewertet –
  kein Task geht stillschweigend verloren. Nur der zugewiesene Server darf
  bestätigen.
* **Task-Timeout:** Läuft ein Task länger als `task_timeout_ms`, gilt er als
  nicht abgeschlossen und wird neu bewertet.
* **Retry mit Grenze:** Fehler/Timeout/ACK-Verlust führen zu `RETRYING` und nach
  `retry_delay_ms` zurück in die Queue, solange `max_retries` nicht erschöpft ist
  – danach sauberes `FAILED` statt Endlosschleife. Reine Python-Ausführungsfehler
  werden also nicht endlos wiederholt (§19).
* **Reassignment bei Server-Ausfall (§9):** Fällt ein Server auf
  `DISCONNECTED`, werden seine Tasks in `ASSIGNED`, `WAITING_FOR_DATA` oder
  `RUNNING` neu bewertet und dem Router erneut vorgelegt. `COMPLETED` bleibt
  unangetastet. Doppelte Ausführung verhindern die eindeutigen Task-IDs, die der
  Worker wiedererkennt (§10).
* **Abbruch (§20):** `cancel()` setzt `CANCELLED` und sendet
  `cancel_requested`; `on_cancel_ack()` quittiert die Bestätigung des Workers.
* **Ereignisprotokoll (§22):** `dispatcher.event_log()` liefert strukturierte
  Zeilen wie `Task task-… assigniert → Server B (Versuch 1)`.

## Dock öffnen

Plugin aktivieren → das Dock **„Task Orchestrator"** erscheint (rechts). Es
zeigt Knoten `Task → Router → Server`; Buttons:

| Button | Wirkung |
|---|---|
| `Refresh` | Graph neu aufbauen |
| `+ Demo-Server` | Server-Knoten anlegen |
| `Demo-Modus` | simulierte Heartbeats **und** Worker (ACK/Start/Ergebnis) |
| `+ Test-Task` | Task in die Queue legen |
| `Dispatch` | wartende Tasks über den Router zuweisen |
| `Speichern` / `Laden` | Graph unter `res://orchestrator_graph.json` |

## Programmieren (ohne UI)

```gdscript
var cfg := OrchestratorConfig.from_dict({"cpu_block_pct": 90.0, "retry_delay_ms": 0})
var servers := OrchestratorServerManager.new(cfg)
var tasks := OrchestratorTaskManager.new(cfg)
var router := OrchestratorRouter.new(servers, cfg)
var dispatcher := OrchestratorDispatcher.new(servers, tasks, cfg, router)

# Transport-Anbindung: hier würde die bestehende Bridge den Task verschicken.
dispatcher.dispatch_requested.connect(func(task_id, server_id, python_task, files):
    print("Führe %s (%s) auf %s aus" % [task_id, python_task, server_id]))

servers.add_server("worker-a", "Worker A", "10.0.0.5", 8765)
servers.add_server("worker-b", "Worker B", "10.0.0.6", 8765)
servers.on_heartbeat("worker-a", {"cpu": 30.0, "ram": 40.0, "queue_used": 1}, Time.get_ticks_msec())
servers.on_heartbeat("worker-b", {"cpu": 75.0, "ram": 50.0, "queue_used": 2}, Time.get_ticks_msec())

var task := dispatcher.submit("numpy_bench", OrchestratorTask.Priority.HIGH,
    ["model.dat"], {"min_free_ram_pct": 20})

dispatcher.tick()        # Server bewerten, Retries/Timeouts prüfen
dispatcher.dispatch()    # → Router wählt Worker A (geringere Last), verschickt

# Rückmeldungen des Workers:
dispatcher.on_ack(task.task_id, "worker-a")
dispatcher.on_task_started(task.task_id, "worker-a")
dispatcher.on_task_result(task.task_id, "worker-a", true, {"value": 42})
```

## Sicherheit (Transport)

Der Worker führt Python-Code aus; ohne Absicherung wäre jeder im LAN ein
Remote-Code-Execution-Risiko. Deshalb gilt:

* **Token-Pflicht:** Der Worker startet **nur** mit `--token`/`--token-file`
  (16–256 Zeichen, `secrets.token_urlsafe(32)`). Jede Verbindung muss sich
  zuerst mit `hello_auth` authentifizieren (Constant-Time-Vergleich, max. 3
  Fehlversuche, 10 s Handshake-Fenster). Ohne Auth wird **kein** Frame
  verarbeitet; Fehlversuche enden mit Close-Code `4401 unauthorized`.
* **Controller-Seite:** `transport.add_worker(..., token)` sendet das Token
  nach dem WebSocket-Open; vor dem `hello`-OK werden alle anderen Nachrichten
  verworfen. Das Token wird pro Worker in `orchestrator_workers.json`
  gespeichert (Datei ist git-ignoriert).
* **Kein Pfad-Traversal:** Script-Namen müssen auf `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`
  passen, dürfen keine `..`/Trenner enthalten und müssen direkt in
  `--scripts-dir` liegen.
* **Limits:** Frames > 4 MB werden verworfen; Inline-Source max. 2 MB;
  Argumente/Input max. 1 MB; Dedup-/Replay-Speicher sind LRU-begrenzt;
  stdout/stderr werden gekürzt.
* **Datei-Transfer:** Datei-IDs sind reine SHA-256-Werte, Transfer-IDs sind
  zeichenbeschränkt (kein `.`/`..`), Anzeigenamen werden auf den Basisnamen
  reduziert. Pro Datei ist eine Größe begrenzt, der Cache insgesamt sowie der
  freie Plattenplatz (Reserve); Empfangene Dateien werden erst nach geprüfter
  Prüfsumme übernommen (keine halben Dateien).
* **Verschlüsselung (TLS, ab 0.4.0):** Die Worker-App startet den Worker
  standardmäßig verschlüsselt (`wss://`); er erzeugt sein Zertifikat beim ersten
  Start selbst –
  ohne `openssl`, ohne Zusatzpakete. Der Manager bietet genau zwei ehrliche
  Vertrauensarten: *selbstsigniert erlauben* (verschlüsselt, Identität ungeprüft)
  oder **Zertifikat anheften** (`worker-cert.pem` → echte Prüfung inkl.
  Fingerabdruck-Vergleich in der Oberfläche). Ohne beides scheitert ein
  verschlüsselter Worker **sichtbar** – es gibt keinen stillen Rückfall auf
  Klartext. TLS < 1.2 wird abgelehnt; der private Schlüssel verlässt den
  Rechner nie.
* **Bekannte Grenze:** Ohne angeheftetes Zertifikat schützt TLS gegen Mitlesen,
  nicht gegen einen **aktiven** Angreifer im selben Netz; über unsichere Netze
  daher zusätzlich VPN (WireGuard/Tailscale). Godot gibt bei
  `WebSocketPeer` das empfangene Zertifikat nicht heraus – eine clientseitige
  Fingerabdruck-Prüfung ist damit nicht möglich und wird auch nicht behauptet.

Die vollständige Prüfung (Funde, Behebung, Grenzen, Ressourcenschutz):
**[SAFETY.md](SAFETY.md)**.

Aufsetzen von Client-PCs:

* **Empfohlen (V1):** [CLUSTER_V1_SETUP.md](CLUSTER_V1_SETUP.md) – automatische
  Erkennung, Worker-App per Doppelklick, Code-Übertragung.
* Manuell/erweitert (Discovery aus, feste URL + Token):
  [CLIENT_SETUP.md](CLIENT_SETUP.md) und [WORKER_SETUP.md](WORKER_SETUP.md).

## Tests

```bash
flatpak run org.godotengine.Godot --headless --path /home/toshix/briding-new-coming \
  --script res://tests/orchestrator/run_orchestrator_tests.gd

# Echter Transport inkl. Token-Auth (startet lokal einen Worker):
bash tests/orchestrator/run_transport_e2e.sh

# Cluster V1: Discovery -> Auto-Verbinden -> Code-Übertragung -> Ergebnis
bash tests/orchestrator/run_cluster_e2e.sh

# Worker offline während einer Aufgabe + Wiederverbindung
bash tests/orchestrator/run_cluster_offline_e2e.sh

# Verschlüsselt (TLS): Discovery → Handshake abgelehnt → Freigabe → wss-Aufgaben
# + Datei-Transfer über TLS + Zertifikat angeheftet
bash tests/orchestrator/run_cluster_tls_e2e.sh

# TLS auf der Worker-Seite (wss, Pinning, Fingerabdruck, Beacon, kein Klartext)
python_bridge/venv/bin/python tests/orchestrator/test_tls_worker.py

# Auslieferung: sind die ZIPs vollständig und lauffähig?
# (führte zum Fund, dass worker.spec/python_build/file_store/tls_cert fehlten)
python_bridge/venv/bin/python tests/orchestrator/test_release_package.py

# Worker-Weg in Python (ohne Godot): Projekte, Cython, Cache, Fehler, Cancel
python_bridge/venv/bin/python tests/orchestrator/test_worker_project.py
```

`tests/orchestrator/test_orchestrator_core.gd` deckt Konfiguration/Normalisierung,
Capacity Gate inkl. Hysterese, Heartbeat-Timeouts, Server-Manager-Übergänge, den
Task-Zustandsautomaten, ACK/Retry/Cancel, Prioritäts-Reihenfolge,
Graph-Serialisierung und die Kompilierung der Editor-Skripte ab.
`tests/orchestrator/test_orchestrator_routing.gd` deckt Eignung/Anforderungen,
Last- und Locality-Bewertung, Begründungen ohne Route, den ACK-Timeout,
Retry-Grenzen, den Task-Timeout, Server-Ausfall mit Reassignment, Kapazitäts-
reservierung und das Ereignisprotokoll ab.
`tests/orchestrator/run_transport_e2e.gd` fährt den echten WebSocket-Pfad
gegen einen Worker-Prozess: Auth (inkl. Negativtest mit falschem Token),
Heartbeat/Name-Übernahme, `call`- und `run`-Ausführung, Ergebnis-Rückweg,
Reservierungs-Freigabe.
`tests/orchestrator/test_cluster_v1.gd` deckt die Discovery ab (Beacon-Parsing,
fehlendes Token, ungültige/fremde Pakete, gleiche Namen auf zwei Rechnern,
Timeout, ID-Bereinigung) sowie den `ClusterManager` (manueller Worker,
Code-Übertragung, Queue ohne Worker, Abbruch, Statistik).
`tests/orchestrator/run_cluster_e2e.gd` prüft den kompletten V1-Ablauf gegen
einen echten Worker **ohne Skript-Ordner**: Discovery, Auto-Verbindung,
`run`- und `call`-Aufgabe mit übertragenem Code, Cython-Projekt inkl. Build,
Build-Cache, Projektordner-Übertragung, Fortschrittsmeldungen,
Ergebnis-Rückweg.
`tests/orchestrator/run_cluster_offline_e2e.gd` beendet den Worker mitten in
einer Aufgabe und prüft: Ausfall erkannt, Aufgabe nicht verloren (RETRYING),
Wiederverbindung, Reassignment (Versuchszähler steigt), Ergebnis kommt an.
`tests/orchestrator/test_worker_project.py` fährt den Worker direkt über
WebSocket (ohne Godot): `.py`-Projekt, `requirements.txt`, `.pyx`-Build ohne
vorbereitete Umgebung, Cache-Treffer, Rebuild nach Änderung, Build-Fehler,
Laufzeitfehler, fehlendes Paket mit Hinweis, Pfad-Ausbruch, Abbrechen,
mehrere Aufgaben gleichzeitig und das Altverhalten mit Inline-Source.
