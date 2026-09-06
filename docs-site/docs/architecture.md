---
sidebar_position: 6
title: Architektur
description: Komponenten, Datenflüsse und Grenzen der Python Bridge.
---

# Architektur

## Rollenverteilung

Die Bridge mischt die Welten nicht. Jede Komponente hat eine klar getrennte
Rolle:

| Komponente | Rolle |
|---|---|
| GDScript | normale Godot-Logik, einfache Schnittstelle |
| Python | echte Python-Runtime mit vollem Ökosystem |
| Python Bridge | Prozesse, Tasks, Kommunikation, Frame-Sync |
| Shared Memory | Datenpfad für große Datenmengen (lokal, in Vorbereitung) |
| GDScript2All / GDExtension | optionales CPU-Werkzeug für Godot-seitige Berechnung – **kein Kommunikationsweg** |

## Grundregel

> Godot wartet nie auf Python, und Python wartet nie auf einen Godot-Frame.

Aus dieser Regel folgt die gesamte Struktur: Godot dispatcht Tasks und nimmt
Ergebnisse frame-synchronisiert entgegen. Python arbeitet eigenständig und
liefert Ergebnisse, sobald sie fertig sind.

## Komponentenüberblick

```text
┌─────────────────────────────┐
│      Godot Main Loop        │
│   _process / _physics       │
└─────────────┬───────────────┘
              │
      PythonBridge.poll()
              │
   ┌──────────┴───────────┐
   │   TaskManager (Policy)│
   │   Scheduler (Frames)  │
   └──────────┬───────────┘
              │
   BridgeInstance (einmal pro Instanz)
   ProcessManager · ConnectionManager · HealthMonitor
              │
      WebSocket (localhost)
              │
   ┌──────────┴───────────┐
   │   Python-Server      │
   │   asyncio + Worker   │
   │   Executor / Contexts│
   └──────────────────────┘
```

## Zuständigkeiten

### Godot-Seite

| Modul | Aufgabe |
|---|---|
| `PythonBridge` (Autoload) | zentrale API-Fassade, Signale, Polling |
| `PythonBridgeTaskManager` | Queue, Prioritäten, Retries, Batching-Policy |
| `PythonBridgeScheduler` | Frame-Dispatch, Inbox, Backpressure, Timeouts |
| `BridgeInstance` | Lifecycle eines Python-Prozesses inkl. Restart |
| `BridgeConnectionManager` | WebSocket-Transport mit Decode-Budget |
| `BridgeSerializer` / `TypeMapper` | Typkonvertierung inkl. Binary-Chunks |
| `PythonBridgeDataRef` / `DataFile` | Handles und file-basierter Transport |

### Python-Seite

| Modul | Aufgabe |
|---|---|
| `server.py` | WebSocket-Server, Worker-Pool, Watchdog |
| `executor.py` | persistente Kontexte, define/run/call, Cancellation |
| `protocol.py` | Nachrichtenformate und Framing |
| `serializer.py` | Encoding/Decoding inkl. numerischer Chunks |
| `data_registry.py` | DataRef-Speicher mit Datei-Transport |
| `ipc_region.py` / `ipc_platform.py` | Shared-Memory-Koordination (Linux-Backend) |

## Datenflüsse

### Steuerfluss (kleine Nachrichten)

```text
GDScript-Aufruf
   ↓
Task wird eingereiht (Priorität, Backpressure)
   ↓
Scheduler dispatcht pro Frame
   ↓
WebSocket-Nachricht an Python
   ↓
Python führt aus (Kontext gesperrt)
   ↓
Antwort puffern (Inbox)
   ↓
Main-Thread verarbeitet max. N Ergebnisse pro Frame
```

### Datenfluss (große Ergebnisse)

```text
Python erzeugt großes Ergebnis (z. B. numpy-Array)
   ↓
Schwelle überschritten? → DataRef-Handle statt Rohdaten
   ↓
Godot materialisiert bei Bedarf (Datei- oder Binärtransport)
   ↓
Frame-Budget begrenzt die Decode-Last pro Frame
   ↓
release_data() gibt den Speicher im Python-Prozess frei
```

Der Shared-Memory-Pfad (aktuell Linux-Backend) ermöglicht später direkten
RAM-Zugriff ohne Kopie. Er ist bewusst vom normalen WebSocket-Pfad getrennt:
kleine Steuerdaten über WebSocket, große Daten über den Datenpfad.

## Batching

Mehrere schnell aufeinanderfolgende Tasks für dieselbe Instanz können zu
einem Batch zusammengefasst werden:

- Fenster öffnet sich ab zwei kompatiblen Tasks
- Schließt bei `max_batch_size` oder `max_batch_delay_ms`
- Reihenfolge bleibt garantiert
- Fehler in einem einzelnen Batch-Item betragen nur dieses Item

Batching ist ein Optimierungsdetail der Dispatch-Ebene. Die Aufruf-Semantik
ändert sich für den Entwickler nicht.

## Hot Reload

Beim Speichern oder externen Ändern einer Python-Datei kann die Bridge den
geänderten Code neu laden:

| Modus | Verhalten |
|---|---|
| `none` | kein Reload |
| `reload_context` | Python-Kontext wird mit neuem Source neu definiert (Standard) |
| `restart_instance` | ganzer Python-Prozess wird neu gestartet |

Godot-State, Task-State und Connection-State werden dabei getrennt behandelt:
Der Godot-Spielzustand geht nicht verloren, nur der Python-Kontext wird
erneuert.

## Fehlermodell

Alle Fehler kommen strukturiert mit Kategorie zurück, etwa:

- `PYTHON_EXCEPTION` mit Typ, Message und Traceback
- `TIMEOUT_ERROR` getrennt nach Queue- und Ausführungs-Timeout
- `CONNECTION_ERROR` / `PROCESS_ERROR` für Instanz-Probleme
- `SERIALIZATION_ERROR` für Typ- oder Größenprobleme
- `DEPENDENCY_ERROR` für fehlende Python-Umgebung

Ein Python-Fehler beendet nie den Godot-Main-Loop und wird nie zu einer
generischen Meldung verkürzt.

## Aktueller Grenzbereich

Ehrliche Standortbestimmung für die Weiterentwicklung:

- Python-Kern und IPC-Tests sind stabil (Testsuite grün).
- Die Godot-Editor-Integration wurde zuletzt direkt im Editor geprüft; die
  [Verifikations-Checkliste](./godot-verification) beschreibt den Stand.
- Das GDScript2All-basierte HP-Dock existiert als experimentelles Werkzeug;
  es ist bewusst **kein Kommunikationsweg** (siehe
  [Kommunikationspfade](./hochleistungspfade)).
- Cluster-/Docker-Verteilung ist konzeptionell vorbereitet
  (`docs/CLUSTER_INTEGRATION_PLAN.md`), aber nicht implementiert.
