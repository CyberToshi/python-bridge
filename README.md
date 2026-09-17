# Python Bridge für Godot 4

Eine allgemeine, production-orientierte Python-Bridge: Python-Code wird direkt
aus Godot heraus geschrieben, verwaltet und ausgeführt. Python bleibt echter
Python-Code; Godot bleibt der kontrollierende Host. Die Bridge übernimmt die
gesamte Infrastruktur: Python-Prozesse, WebSocket-Kommunikation, Task-Verwaltung
mit Priorität/Batching/Backpressure, Frame-Synchronisation, Health Monitoring,
Crash-Restart, venv-Provisioning, Hot Reload, Python-Editor und automatische
GDScript-Wrapper-Generierung — **nativ auf Windows/Linux und im Browser über
Pyodide (WebAssembly)**.

> **Wichtigste Architekturregel:** Die Bridge macht Python **nicht** zu einem
> zweiten GDScript. Python bleibt Python, Godot bleibt Godot — verbunden über
> eine klar definierte, modulare Kommunikationsschicht.
>
> **Invariante:** Python wartet nie auf einen Godot-Frame, und Godot wartet
> nie auf Python.

## Inhalt

```
addons/python_bridge/   das Add-on (Kern + Editor + Python-Paket + Web-Worker)
core/                   TaskManager, Scheduler, Instanzen, Protokoll, Typ-Mapping
editor/                 Dock-Panel, Syntax-Highlighting, Wrapper-Generator
python/                 Python-Server (asyncio + Worker-Thread), Executor, Introspection
web/                    bridge_worker.js (Pyodide-Worker für Web-Exports)
docs/                   Architektur, API, Installation, Export, Web-Runtime, Changelog
example/                Minimalbeispiel (demo.gd + Beispielskript)
tests/python/           Python-`unittest`-Suite (ausführbar, 136 Tests grün)
tests/gdscript/         GDScript-Headless-Testrunner (godot --headless)
tools/                  export_check.py, build_web_bundle.py, test_web_runtime.mjs
```

## Schnellstart

1. `addons/python_bridge/` nach `res://addons/python_bridge/` kopieren.
2. Plugin „Python Bridge“ in den Projekteinstellungen aktivieren.
3. Python 3.8+ installiert (wird automatisch gefunden oder per
   `python_executable` gesetzt).
4. Beim ersten `start_instance()` wird venv + `websockets` automatisch
   provisioniert (1–3 Minuten, nicht-blockierend).

```gdscript
func _ready() -> void:
    await PythonBridge.start_instance("default")
    PythonBridge.create_script("beispiel", "def calc(a, b):\n    return a * b\n")
    var r := await PythonBridge.call_script("beispiel", "calc", [6, 7])
    print(r.value)   # 42
```

Derselbe Code läuft unverändert im Browser (Pyodide-Transport wird auf
Web-Exports automatisch gewählt). Ausführlicher:
[docs/INSTALLATION.md](docs/INSTALLATION.md), [docs/API.md](docs/API.md),
[docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md).

## Export-Prüfung

Vor einem Export prüft das stdlib-basierte Tool Runtime, Bridge-Dateien,
Workspace, Export-Presets und Plattformgrenzen:

```bash
python3 tools/export_check.py --project . --platform all
```

Windows/Linux: prüft Python-Runtime, -Version, Workspace, Presets und
Berechtigungen. Web: prüft das gebaute Pyodide-Bundle (Worker, virtuelles
Dateisystem, Lockfile, Pakete). Details: [docs/EXPORT.md](docs/EXPORT.md).

## Web-Export (Pyodide, ohne externen Server)

Python läuft im Browser über Pyodide in einem Web Worker mit virtuellem
Dateisystem — auf normalem Static Hosting, ohne Python-Server:

```bash
python3 tools/build_web_bundle.py --project . --out build/web_bridge \
  --packages numpy,scipy,pandas
python3 tools/export_check.py --project . --platform web
```

Das Bundle (Worker + Workspace-Tar + optionale lokale Pyodide-Runtime +
Lockfile) wird neben den Godot-Web-Export gelegt: lokal gebündelt zuerst,
CDN als Fallback. NumPy/SciPy/Pandas werden **funktional** getestet
(echte Berechnungen, nicht nur Import). Architektur und Grenzen:
[docs/WEB_RUNTIME.md](docs/WEB_RUNTIME.md).

## Tests

```bash
# Python-Tests (inkl. Web-Host-, Server-Integration und Science-Stack-Tests)
python3 -m unittest discover -s tests/python -p "test_*.py"

# GDScript-Tests (Godot-Binary nötig; Projekt einmal im Editor öffnen)
godot --headless --path . --script res://tests/gdscript/run_tests.gd

# Echte Pyodide-Runtime (Node nötig): Runtime, vFS, NumPy/SciPy/Pandas
python3 tools/build_web_bundle.py --project . --out build/web_bridge
node tools/test_web_runtime.mjs
```

## Versionshistorie

- **v0.3.0** — Web-Transport: Pyodide im Web Worker mit virtuellem
  Dateisystem, `BridgeWebInstance`/`BridgeWebConnection` unter der bestehenden
  `BridgeInstance`-State-Machine, `browser_host.py` (dieselbe Protocol-v2-/
  Executor-Schicht wie der Desktop-Server), Workspace-Bundle-Builder
  (lokal-first + CDN-Fallback, Lockfile), funktionaler NumPy/SciPy/Pandas-
  Nachweis in echter Pyodide-Runtime, erweiterter Export-Check für
  Windows/Linux/Web, 18 neue Web-Host-Tests und 6 neue Server-Integrationstests
  (Crash, Disconnect, Multi-Task, Science-Stack).
- **v0.2.1** — Stabilitäts-Fix für Godot 4.7: Addon kompiliert wieder als
  Autoload/Editor-Plugin (mehrzeilige `match`/Signaturen, nicht-literalische
  Konstanten, `class_name`-Parametername, Parse-Zeit-Klassen-Zugriff,
  Binary-Frame-Roundtrip, deterministische Retry-Zeiten). GDScript-Headless-
  Suite erstmals lauffähig (34 Tests / 99 Assertions grün).
- **v0.2.0** — Task Manager, Scheduler (Frame-Sync), Batching, Backpressure,
  Health Monitoring, Crash-Restart mit Backoff, Protokoll v2, Editor-Dock,
  Wrapper-Generierung, Hot Reload, Tests, Dokumentation.
- **v0.1.0** — Basis (Instanzen, WebSocket, venv, Serialisierung, Editor-Plugin).

Siehe [docs/CHANGELOG.md](docs/CHANGELOG.md).

## WebAssembly-Status

Implementiert und funktional getestet: Pyodide im Web Worker, virtuelles
Dateisystem, Module/Plugins, DataRefs mit Binary-Frames, NumPy/SciPy/Pandas.
Der Desktop-Transport bleibt vollständig erhalten; dieselbe öffentliche API
gilt auf beiden Wegen. Grenzen (kein `OS.create_process`, nur WASM-Wheels,
serielle Ausführung) sind in [docs/WEB_RUNTIME.md](docs/WEB_RUNTIME.md)
dokumentiert.
