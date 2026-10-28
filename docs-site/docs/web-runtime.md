---
sidebar_position: 5
title: Python im Browser
description: Pyodide-WebAssembly-Integration — implementiert und funktional getestet.
---

# Python im Browser

## Status: implementiert

Die Bridge läuft auf Web über **Pyodide (WebAssembly) im Web Worker** — direkt
im Browser, ohne externen Python-Dienst, auf normalem Static Hosting. Auf
Web-Exports wird der Web-Transport automatisch gewählt; Desktop (Windows/
Linux) bleibt unverändert, und dieselbe öffentliche API gilt auf beiden Wegen.

```gdscript
await PythonBridge.start_instance("default")
PythonBridge.create_script("hello", source)
var result := await PythonBridge.call_script("hello", "greet", ["Godot"])
```

```text
Godot Web
  → JavaScriptBridge
  → Web Worker (bridge_worker.js)
  → Pyodide / WebAssembly
  → browser_host.py (dieselbe Protocol-/Executor-Schicht)
  → virtuelles Dateisystem (python/, modules/, plugins/, packages/)
```

Wiederverwendet werden Facade, TaskManager, Scheduler, Protocol v2,
Serializer, Context-/Source-Hash-Logik, Introspection, Hot Reload und
Fehler-Taxonomie — nur der Transport wurde ausgetauscht.

## Build & Static Hosting

```bash
python3 tools/build_web_bundle.py --project . --out build/web_bridge \
  --packages numpy,scipy,pandas
python3 tools/export_check.py --project . --platform web
```

Der Builder erzeugt Worker, Workspace-Tar, Lockfile und optional eine lokale
Pyodide-Runtime — lokal gebündelt zuerst, CDN als Fallback. GitHub Pages,
Cloudflare Pages oder jeder statische Webserver genügen (HTTPS, korrekter
WASM-MIME-Type, CORS nur bei Cross-Origin).

## Skript-Abhängigkeiten im Web-Build

`__bridge_deps__`-Deklarationen aus den Skripten landen automatisch in der
`bridge_deps.json` des Bundles und als Pyodide-Pakete im Worker — du musst
sie nicht doppelt pflegen. Pakete, die **nicht** im Bundle stecken, führt die
Bridge beim Aufruf nicht still aus, sondern meldet eine klare
`DEPENDENCY_ERROR`-Meldung (kein `ModuleNotFoundError` zur Laufzeit).

## Dateien zur Laufzeit: der `file_op`-Kanal (ab 0.5.0)

Godots `user://` und das MEMFS des Pyodide-Workers sind **zwei getrennte
Dateisysteme**. Bis 0.4.0 existierten Skripte, die erst **nach** dem Bundle
entstanden, im Worker gar nicht: `create_script()` schrieb die Datei auf
Godot-Seite, der `import` im Worker scheiterte — und gelöschte Skripte blieben
weiter importierbar.

Seit 0.5.0 spiegelt die Facade jede Änderung als **einseitige Nachricht**
(`file_op` mit `op = "write"` bzw. `"delete"`, ohne Ack) in den Worker:

| Auslöser | Wirkung im Worker |
|---|---|
| `create_script()` / `notify_script_saved()` | Datei wird im Workspace geschrieben; `__pycache__` und der `sys.modules`-Eintrag werden verworfen, damit der nächste Import den neuen Code zieht |
| `notify_script_deleted()` | Datei verschwindet, das Modul ist nicht mehr importierbar |
| noch keine Instanz `ready` | Ops werden gepuffert (letzte Op pro Pfad gewinnt, FIFO, hart begrenzt) und bei `ready` nachgezogen — genau der Fall „Skript anlegen, bevor Python startet“ |

Das Dock meldet Speichern/Umbenennen/Löschen selbst an die Bridge; bei eigenem
Dateihandling außerhalb des Docks rufst du dieselben Funktionen auf.

Sicherheitsnetz im Worker: Pfade müssen innerhalb von `scripts/`, `modules/`,
`plugins/` oder `packages/` liegen. `..`, absolute Pfade und ein fehlender
Workspace-Root werden abgelehnt, ohne den Worker zu beenden. Geschrieben wird
atomar (`.tmp` + `os.replace`) mit 8-MB-Limit; `scripts/` landet automatisch
auf `sys.path`.

## Server-Hardening seit v0.3.2

Auch der Web-Pfad profitiert von der Desktop-Hardening-Runde: Ergebnisse
über `max_result_bytes` werden **vor** der Serialisierung abgelehnt (im
WASM-Heap der wichtigste OOM-Schutz), beim Shutdown wartende Queue-Jobs
bekommen geordnete `task_error`-Antworten statt einem Timeout, und
Server-Fehler enden mit sauberem Exit-Code + sichtbarem Log (das
Lifecycle-Logging schreibt auf fd 2 und bleibt so auch während laufender
Tasks sichtbar).

## Wissenschafts-Stack

NumPy, SciPy und Pandas sind **verbindlich unterstützt und funktional
getestet** (echte Berechnungen in echter Pyodide-Runtime, nicht nur Import):
lineare Systeme, FFT, Matrixmultiplikation, numerische Integration und
Optimierung, GroupBy und Merge. Native Desktop-Wheels (`.so`/`.pyd`) können
nicht über Static Hosting verteilt werden — sie werden über das
Pyodide-Paket-Repository geladen; die Bridge meldet nicht portierbare
Bibliotheken als klare Plattformmeldung.

## Browser-Grenzen

Kein `OS.create_process`, keine lokalen TCP-Sockets, kein venv, kein POSIX
Shared Memory, keine Python-Threads. Python läuft zunächst seriell in einem
Worker; Godot-seitige Queues, Timeouts, Batching und Cancellation bleiben
vollständig erhalten. Große Daten laufen über ArrayBuffer/DataRefs mit
Binary-Frames.

Ein externer Python-WebSocket-Dienst bleibt optional verfügbar, ist für den
Standard-Web-Workflow aber nicht mehr erforderlich. Die vollständige
technische Beschreibung steht in `docs/WEB_RUNTIME.md` im Repository.
