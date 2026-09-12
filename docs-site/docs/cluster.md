---
sidebar_position: 7
title: Cluster – Aufgaben auf andere PCs verteilen
description: Das Cluster-Modul der Python Bridge – Überblick, Architektur, Node-Nutzung und Abgrenzung zum lokalen Betrieb.
---

# Cluster – Aufgaben auf andere PCs verteilen

Die Python Bridge führt Python **lokal** in Godot aus. Das **Cluster-Modul**
setzt eine Ebene darüber: dieselben Python-Aufgaben laufen statt auf dem
Hauptrechner auf einem **anderen PC im selben LAN** – ohne Docker, ohne VPN,
ohne Router-Konfiguration und ohne dass auf dem Client-Rechner ein Terminal
geöffnet werden muss.

```text
Godot + ClusterPanel                      Client-Rechner
(Du klickst „Aufgabe starten“)            (Worker-App, Doppelklick-Start)
        │                                          │
        │◄────── Discovery per UDP-Broadcast ──────┤   „ich bin da“
        │                                          │
        ├──────── Auftrag + Python-Code ──────────►│   Code ankommen
        │         (verschlüsselt, wss://)          │   Projekt bauen
        │◄──────── Status, Fortschritt, Ergebnis ──┤   Ergebnis zurück
```

## Die zentrale Definition

> Das Cluster-Modul ist **kein neues Python-System**. Es ist ein **visueller
> Task- und Daten-Orchestrator für die bestehende Bridge.**

Python-Aufgaben bleiben normale Python-Aufgaben. Das Modul entscheidet nur:

1. **Wo** läuft die Aufgabe (welcher Rechner ist verfügbar, hat Kapazität und
   die nötigen Daten)?
2. **Welche Dateien** braucht dieser Rechner dafür, und liegen sie schon dort?
3. **Wann** darf gestartet werden (erst wenn die Daten geprüft vorliegen)?
4. **Was passiert bei einem Ausfall** (Aufgabe neu bewerten, nicht verlieren)?

Der Code läuft weiterhin in einem normalen Python-Prozess – auf einem anderen
Rechner statt auf deinem.

## Die zwei Rollen

| Rolle | Rechner | Was läuft dort |
|---|---|---|
| **Manager** | der Hauptrechner | Godot mit dem Addon, Node `ClusterPanel` (dunkle Oberfläche) |
| **Worker** | jeder weitere PC | die Worker-App `worker_app.py` (Doppelklick, eigenes Fenster) |

Die Worker-App ist ein **eigenes kleines Programm** im Addon
(`addons/python_bridge/orchestrator/worker/`). Sie erzeugt ihr Token selbst,
startet den Worker-Prozess und zeigt Status, Log, Aufgabenkarten mit
Fortschrittsbalken und die Diagnose.

## So ist es in Godot eingebunden

Das Cluster-Modul ist ein **Node**, kein Fremdprogramm. Eine Szene mit
`ClusterPanel` genügt – der Panel bringt seinen eigenen `ClusterManager` mit:

```text
ClusterPanel (Control)                 ← fertige Oberfläche (cluster_main.tscn)
└── ClusterManager (Node)
    ├── Worker(s)     automatisch erkannt + verbunden
    ├── Task(s)       Python-Aufgaben inkl. Zustandsautomat
    └── Scheduler     Router + Dispatcher + Transport
```

Wer keine Oberfläche braucht, benutzt den Manager direkt. Zwei Dinge sind am
Beispiel wichtig zu verstehen:

* Der **erste Parameter ist nur der Anzeigename** der Aufgabe – kein Dateipfad,
  den es auf dem Worker geben müsste. Er steht später in der Tabelle und im
  Protokoll.
* Ausgeführt wird, was in `source` steht (oder die übertragene Projektdatei).
  Der Worker legt dafür ein eigenes Arbeitsverzeichnis an.

```gdscript
var cluster := ClusterManager.new()
add_child(cluster)   # startet Discovery und lädt gemerkte Rechner
cluster.task_finished.connect(func(task_id: String, ok: bool, value: Variant, error: String) -> void:
    print(task_id, " → ", ok, " ", value, " ", error))

# "mein_lauf" ist der Name; der Code kommt aus "source" mit.
# command "run": der Code liest `input` und setzt `result`.
cluster.submit_script("mein_lauf", {
    "command": "run",
    "input": {"werte": [1, 2, 3]},
    "source": "result = sum(input['werte'])",
})
```

Für den Alltag gibt es passende Kurzwege – statt Code als Text zu übergeben:

| Aufruf | Was passiert |
|---|---|
| `submit_project_dir("res://mein_projekt")` | liest den Ordner (nur Textdateien, ohne `venv`/`__pycache__`), bestimmt den Einstieg (`main.py`, `app.py`, …) und lässt bauen, falls nötig |
| `submit_script_file("res://scripts/bench.py", {...})` | eine einzelne Datei als Aufgabe |
| `submit_with_files({...}, ["res://daten/modell.dat"])` | Aufgabe **plus** Eingabedateien; übernimmt Registrierung und Transfer |
| `cancel_task(task_id)` | bricht Aufgabe und laufenden Datei-Transfer ab |

`call` statt `run`: dann wird eine Funktion im Code aufgerufen – dazu `function`
und optional `args`/`kwargs` setzen. `input` gibt es nur bei `run`.

## Was das Modul übernimmt

| Baustein | Aufgabe |
|---|---|
| **LAN-Discovery** | UDP-Broadcast: Rechner finden sich selbst. Keine IP, kein Port zum Eintippen. Der Beacon ist **nicht** verschlüsselt – deshalb ist Auto-Pair eine bewusste Entscheidung ([Cluster-Sicherheit](./cluster-sicherheit)). |
| **Worker-Transport** | WebSocket-Verbindung pro Rechner (`wss://`), Heartbeat, automatische Wiederverbindung. |
| **Capacity Gate** | Ein Rechner nimmt nur so viele Aufgaben an, wie seine Grenzen (CPU/RAM/Queue) zulassen. Zustände je Rechner: `READY` (nimmt an), `LIMITED` (knapp, nimmt noch an), `BLOCKED` (gesperrt), `UNRESPONSIVE` (Heartbeat fehlt), `DISCONNECTED`. Mit Hysterese: die Freigabe aus `BLOCKED` kommt erst **unter** der READY-Schwelle, damit der Zustand nicht flattert. |
| **Router** | Wählt den passenden Rechner: verfügbar + Kapazität + Ressourcen + **Daten schon da** (Data Locality). |
| **Task-Zustandsautomat** | `CREATED → QUEUED → ASSIGNED → WAITING_FOR_DATA → RUNNING → COMPLETED/FAILED/RETRYING/CANCELLED`. |
| **ACK & Wiederzuweisung** | Ein Auftrag gilt erst nach Quittung als übertragen. Fällt ein Rechner aus, werden betroffene Aufgaben neu bewertet – abgeschlossene **nicht** wiederholt. |
| **Datei-Registry + Chunk-Transfer** | Große Eingaben werden inhaltsadressiert (SHA-256), in 256-KB-Stücken übertragen und **vor** dem Start geprüft. Schon vorhandene Dateien werden nicht erneut geschickt. |
| **Projekte mit Build** | Enthält der Ordner `.pyx` oder `requirements.txt`, legt der Worker eine isolierte Umgebung an, installiert und kompiliert – im Cache, damit der zweite Lauf sofort startet. |
| **TLS** | In der Worker-App standardmäßig verschlüsselt (`ws://` nur, wenn der Worker von Hand ohne TLS gestartet wird); Zertifikat entsteht automatisch. Siehe [Cluster-Sicherheit](./cluster-sicherheit). |
| **Monitoring** | CPU, RAM, GPU (optional), Latenz, Queue, aktive Aufgaben – pro Rechner in der Oberfläche. |

## Bewusst *nicht* enthalten

* Kein virtuelles Netzwerk, kein Docker, keine Router- oder Portfreigaben.
* Kein Ersatz für die lokale Instanz: die normale
  [Python Bridge](./getting-started) arbeitet unverändert weiter.
* Keine Sandbox: übertragener Code läuft mit den Rechten des Worker-Benutzers.
* Keine ausgleichende Fairness über mehrere Manager: **ein** Manager steuert die
  Rechner, die er kennt. Prioritäten (`LOW`/`NORMAL`/`HIGH`) gibt es je Aufgabe,
  sie ordnen nur die Warteschlange **innerhalb** dieses Managers.

## Weiterlesen

1. [Cluster aufsetzen](./cluster-setup) – Hauptrechner und Client in 5 Minuten
2. [Cluster-Sicherheit](./cluster-sicherheit) – Token, TLS, Fingerabdruck
3. [Fehlerbehebung](./fehlerbehebung) – auch für Cluster und TLS

:::tip Ausführliche Fassungen im Repository
Im Addon liegen zusätzlich:

- `addons/python_bridge/orchestrator/CLUSTER_V1_SETUP.md` – Aufsetzen mit
  Firewall-Tabelle und Fehlersuche
- `addons/python_bridge/orchestrator/SAFETY.md` – Sicherheitsprüfung, Funde,
  Grenzen
- `addons/python_bridge/orchestrator/CYTHON_AND_BUILD.md` – Build-Schritte,
  Umgebungen und Cache im Detail
:::
