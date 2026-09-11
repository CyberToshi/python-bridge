---
sidebar_position: 1
title: Willkommen bei Python Bridge
description: Python natürlich in Godot 4 integrieren – Konzepte, Begriffe und Systemanforderungen.
---

# Willkommen bei Python Bridge

**Python Bridge** verbindet Godot 4 mit Python – ohne Python in eine eigene
Sprache zu verwandeln. Du schreibst weiterhin **normale `.py`-Dateien**,
GDScript bleibt deine Godot-Schnittstelle, und die Bridge übernimmt die
gesamte technische Infrastruktur dazwischen:

- Start, Überwachung und kontrolliertes Beenden von Python-Prozessen
- asynchrone WebSocket-Kommunikation (Godot blockiert nie auf Python)
- strukturierte Ergebnisse und Fehler (Exception-Typ, Message, Traceback)
- Task-Verwaltung: Queue, Prioritäten, Timeouts, Retry, Batching
- Frame-Synchronisation: Antworten werden kontrolliert pro Frame abgearbeitet
- mehrere Python-Instanzen und getrennte Python-Kontexte
- projektbezogene Python-Umgebung (`venv`) mit automatischer Einrichtung
- Hot Reload für Python-Code
- Python-Editor-Dock direkt im Godot-Editor
- optionale automatische GDScript-Wrapper
- DataRefs plus binärer bzw. dateibasierter Transport für große Daten

## Die wichtigste Regel

> **Godot wartet nie blockierend auf Python – und Python wartet nie auf einen
> Godot-Frame.**

Alle Aufrufe sind asynchron: Du `await`-est ein Ergebnis, während der
Godot-Main-Thread frei weiterläuft.

## Wer startet Python?

**Godot startet Python selbst – du musst im Terminal nichts starten.** Beim
ersten `PythonBridge.start_instance("default")` passiert automatisch:

1. Python-Interpreter suchen (Details: [Installation](./installation)),
2. eine projektbezogene `venv` im Workspace anlegen (falls nicht vorhanden),
3. benötigte Pakete installieren (`websockets` u. a.),
4. den Bridge-Server-Prozess starten,
5. den lokalen WebSocket-Kanal öffnen und per Handshake verbinden.

Die Python-Datei `res://python_bridge/scripts/hello.py` ist eine **ganz
normale Python-Datei**: Du kannst sie außerhalb von Godot mit jedem Python
öffnen und ausführen.

## Begriffe (Glossar)

Damit die weiteren Kapitel eindeutig sind, hier die wichtigsten Begriffe:

| Begriff | Bedeutung |
|---|---|
| **PythonBridge (Autoload)** | Der globale Singleton (`PythonBridge`), deine einzige GDScript-Schnittstelle. Alle Funktionen sind `await`-bar. |
| **Instanz** | Ein Python-Prozess + ein WebSocket-Kanal. Benannt (`default`, `worker-a`, …). Mehrere Instanzen laufen parallel. |
| **Task** | Eine Arbeitseinheit („run“ / „call“ / „define“). Durchläuft `QUEUED → RUNNING → COMPLETED/FAILED/CANCELLED/TIMEOUT`. |
| **Kontext (Context)** | Ein persistenter Python-Namespace innerhalb einer Instanz (erkennbar an einer Context-ID). Skripte erhalten den Kontext `script:<pfad>`. |
| **Skript** | Eine normale `.py`-Datei unter `<workspace>/scripts/`. Wird gecacht und nur bei Änderung neu übertragen. |
| **Wrapper** | Automatisch generierte GDScript-Klasse, die eine Python-Datei als `PyBridge<Name>` verfügbar macht. |
| **Workspace** | Projektordner `res://python_bridge/` mit `scripts/`, `wrappers/`, `venv/`, `tmp/`, `config/`. |
| **DataRef** | Leichtgewichtiges Handle auf einen großen Datensatz, der im Python-Prozess liegt – die Daten selbst werden erst bei Bedarf geholt. |
| **Hot Reload** | Python-Code-Änderung gezielt in die laufende Instanz übernehmen, ohne den Godot-Zustand anzutasten. |
| **Frame-Sync** | Ergebnisse werden nicht unkontrolliert in Nodes geschrieben, sondern im Sync-Punkt pro Frame mit Budget abgearbeitet. |
| **Batching** | Mehrere kurz aufeinanderfolgende, kompatible Tasks werden zu einer Nachricht zusammengefasst (max. 32 Tasks / 32 ms Fenster). |

## Was du damit bauen kannst

- numerische Berechnungen und Simulationen
- Datenaufbereitung, Data Engineering
- KI-/ML-Workflows (NumPy, PyTorch, …)
- Punktwolken, Matrizen, große Arrays (über DataRefs)
- Editor- und Entwicklungswerkzeuge

## Systemanforderungen

### Plattformen

- Linux, Windows, macOS (Desktop)

### Software

| Voraussetzung | Details |
|---|---|
| Godot | **4.2 oder neuer**; dieses Projekt wurde mit **4.7.2** verifiziert (auch als Flatpak) |
| Python | **3.8 oder neuer**; gesucht in dieser Reihenfolge: ① `python_executable`-Konfiguration, ② `PYTHON_PATH`-Umgebungsvariable, ③ `PATH`-Suche (`python`, `python3`, `py`, …), ④ Plattform-Fallback |
| Schreibzugriff | auf den Workspace (`res://python_bridge`), damit `venv`, temporäre Dateien und Skripte angelegt werden können; für exportierte Spiele `user://` verwenden |
| Netzwerk | Zugriff auf `localhost` (WebSocket zwischen Godot und Python) |
| Flatpak-Godot (Linux) | wird erkannt; venv/pip/Server laufen dann über `flatpak-spawn --host` mit Host-Python |

### Verifizierter Stand

Mit der echten Engine verifiziert: 0 GDScript-Kompilierfehler, 193/193
GDScript-Assertions, Autoload + Dock + Plugin (`VERIFY: PASS`), Live-
Hello-World und die komplette DataRef-Datenebene (36/36 Checks, inkl.
Datei-Transport). Details und Prüfbefehle: [Godot-Verifikation](./godot-verification).

## Dokumentationsweg

1. [Installation](./installation) – Addon aktivieren, Voraussetzungen
2. [Erste Schritte](./getting-started) – Hello World mit beiden Seiten
3. [Bedienung im Editor](./editor-ui) – das Python-Dock mit Screenshots
4. [Konfiguration](./konfiguration) – alle Einstellungen erklärt
5. [Python-Seite verstehen](./python-seite) – was in Python passiert
6. [Große Daten (DataRefs)](./datenebene) – Data-Plane
7. [API-Referenz](./api) – jede Funktion dokumentiert
   - [Tasks & Scheduling](./api-tasks)
   - [Daten & Serialisierung](./api-data)
   - [Kern-Komponenten](./api-internals)
   - [Editor & HP-Werkzeuge](./api-editor)
8. [Fehlerbehebung](./fehlerbehebung) – Probleme und Fehlercodes

Ausblick (bewusst getrennt): ein zweiter, geplanter Pfad für sehr große
lokale Daten über Shared Memory ([Kommunikationspfade](./hochleistungspfade))
und die konzeptionell vorbereitete Cluster-Verteilung
([`docs/CLUSTER_INTEGRATION_PLAN.md`](https://github.com/CyberToshi/python-bridge/blob/main/docs/CLUSTER_INTEGRATION_PLAN.md))
– beides ist noch nicht Teil des verifizierten Standardwegs.

Für den ausführlichen manuellen Workflow (welcher Node, welcher Code,
Schritt für Schritt) liegt im Repository der
[HANDS-ON-Connect-Guide](https://github.com/CyberToshi/python-bridge/blob/main/docs/HANDS_ON_CONNECT_GUIDE.md)
bereit.
