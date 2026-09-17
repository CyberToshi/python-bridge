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
