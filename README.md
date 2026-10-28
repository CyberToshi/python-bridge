# Python Bridge für Godot 4

**Version 0.5.0** · verifiziert mit Godot 4.6- und 4.7-stable sowie Python 3.13

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

## Einstieg

➡️ **[docs/ERSTE_SCHRITTE.md](docs/ERSTE_SCHRITTE.md)** — die verbindliche
Anleitung von Null auf: Voraussetzungen, Installation in 5 Schritten, beide
Skript-Typen, Editor-Dock, rückstandsfreies Löschen, Konfiguration,
Fehlerbehebung, Versionsklarheit.

Ein Überblick über alle Dokumente (inklusive klar markierter historischer
Dateien): **[docs/README.md](docs/README.md)**.

## Zwei Arten von Python-Code

| | Temporär | Persistent |
|---|---|---|
| Aufruf | `await PythonBridge.execute(code, input)` | `execute_script` / `call_script` / `define_script` |
| Ablage | nur im Speicher (String, Scratch-Tab im Dock) | echte Datei `res://python_bridge/scripts/<id>.py` |
| Kontext | frisch pro Aufruf | bleibt pro Datei (Modul-State überlebt) |

```gdscript
func _ready() -> void:
    await PythonBridge.start_instance("default")          # erster Start: venv, 1-3 min
    await PythonBridge.execute("result = 6 * 7")          # temporär -> 42

    PythonBridge.create_script("rechner", "def calc(a, b):\n    return a * b\n")
    var r := await PythonBridge.call_script("rechner", "calc", [6, 7])
    print(r.value)                                        # 42

    # Aufräumen: entfernt Quelle, .c, .so/.pyd, .pyc, Build-Zustand und Wrapper
    PythonBridge.delete_script("rechner")
```

## Inhalt

```
addons/python_bridge/   das Add-on (Kern + Editor + Python-Paket + Web-Worker)
core/                   TaskManager, Scheduler, Instanzen, Protokoll, Skript-Dateien
editor/                 Dock-Panel, Tab-Layer, Dateischicht, Syntax-Highlighting
python/                 Python-Server (asyncio + Worker-Thread), Executor, Introspection
web/                    bridge_worker.js (Pyodide-Worker für Web-Exports)
docs/                   Einstieg, API, Architektur, Export, Web-Runtime, Changelog
example/minimal/       absolutes Minimum (eine Szene, drei Zeilen GDScript)
example/hello/          Minimalbeispiel (Szene + Beispielskript)
example/maximum/       alle Register (alle Config-Keys, 2 Instanzen, .py + .pyx, DataRef)
example/web_demo/       komplettes Web-Demo (Desktop + Browser, Bundle inklusive)
tests/python/           Python-`unittest`-Suite (205 Tests)
tests/gdscript/         GDScript-Headless-Testrunner (391 Assertions) + Editor-Verifikation
tests/live_cython_e2e.py  portables Live-E2E für den Cython-Pfad (baut wirklich)
tools/                  export_check.py, build_web_bundle.py, test_web_runtime.mjs
```

## Schnellstart

1. `addons/python_bridge/` nach `res://addons/python_bridge/` kopieren.
2. Plugin „Python Bridge“ in den Projekteinstellungen aktivieren (registriert
   den Autoload `PythonBridge` und das Editor-Dock).
3. Python 3.8+ installiert (wird automatisch gefunden oder per
   `python_executable` gesetzt).
4. Beim ersten `start_instance()` wird venv + `websockets` automatisch
   provisioniert (1–3 Minuten, nicht-blockierend).

Derselbe Code läuft unverändert im Browser (Pyodide-Transport wird auf
Web-Exports automatisch gewählt). Ausführlich:
[docs/ERSTE_SCHRITTE.md](docs/ERSTE_SCHRITTE.md), [docs/API.md](docs/API.md).

## Editor-Dock (neu in 0.4.0, ausgebaut in 0.5.0)

Python-Dateien direkt in Godot schreiben, ausführen und löschen — ohne den
Editor zu verlassen:

- **Stabile Tabs** (ein Tab pro Datei, eigene Undo-Historie, Drag & Drop,
  `●` für ungespeicherte Änderungen, Close-Button am aktiven Tab, `Strg+W`).
- **Korrektes Syntax-Highlighting** inkl. mehrzeiliger Docstrings; Farben
  werden sauber zurückgesetzt (kein „Rest der Zeile bleibt grün“).
- **Öffnen/Speichern ohne Rätselraten:** leere Datei ≠ Lesefehler, klare
  Fehlermeldung im Log, CRLF/BOM werden normalisiert.
- **Zwei Tab-Arten:** persistente `.py`/`.pyx`-Dateien und temporäre
  Scratch-Tabs, die per `execute()` laufen und nur auf Wunsch gespeichert werden.
- **Löschen ohne Rückstände:** Quelle, `.c`, `.so`/`.pyd`, `.pyc`,
  `__pycache__`, `cython_build_tmp`-Reste, Cython-Build-Hash und der generierte
  Wrapper verschwinden mit einem Klick.
- Umbenennen, GDScript-Wrapper-Generierung, Hot Reload und Cython-Build im
  `⋯`-Menü; Shortcuts `Strg+N`, `Strg+S`, `Strg+W`, `Strg+Enter`.
- **Einstellungen an zwei Orten**: *Projekt → Projekteinstellungen → Python
  Bridge* oder direkt `⋯ → Einstellungen …` (mit „Speichern & neu starten“).
  Zusätzlich liegt unter *Projekt → Werkzeuge* ein `Python Bridge`-Menü
  (Dock anzeigen, Neue Datei, Einstellungen, Instanz starten/stoppen,
  Cython kompilieren) — nichts ist nur im Dock versteckt.

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

Ein komplettes, lauffähiges Beispiel mit Web-Export-Preset liegt unter
[example/web_demo/](example/web_demo/) — Desktop und Browser mit exakt
derselben Szene und demselben Python-Code (Modul-Import, Plugin, Skripte).
Der Workflow steht in [example/web_demo/README.md](example/web_demo/README.md).

## Tests

```bash
# GDScript-Headless-Suite (Kern, Task-Layer, Serializer, Wrapper, Editor-Dateischicht)
godot --headless --path . --script res://tests/gdscript/run_tests.gd

# Editor-Dock im echten Editor-Kontext (Dock-Aufbau, Tabs, Speichern, Löschen)
godot --headless --editor --path . --script res://tests/gdscript/verify_editor.gd

# Python-Tests (inkl. Web-Host-, Server-Integration und Science-Stack-Tests;
# braucht `websockets` im verwendeten Python, siehe requirements.txt)
# Ohne websockets werden die Integrations-/Server-Tests sauber übersprungen -
# wer sie mitlaufen lassen will, legt einmalig eine lokale Test-venv an:
#   python -m venv .venv-test
#   .venv-test/Scripts/python -m pip install "websockets>=11" cython setuptools
#   .venv-test/Scripts/python -m unittest discover -s tests/python -t tests/python
python3 -m unittest discover -s tests/python -p "test_*.py"

# Cython-Pfad wirklich kompilieren (braucht C-Compiler, s. docs/ERSTE_SCHRITTE.md §5.6)
python3 tests/live_cython_e2e.py

# Echte Pyodide-Runtime (Node nötig): Runtime, vFS, file_op-Sync,
# NumPy/SciPy/Pandas — 23 Checks, läuft auch unter Windows
npm install pyodide@0.26.4          # einmalig, z. B. in .webtest/
PYODIDE_PKG=.webtest/node_modules/pyodide node tools/test_web_runtime.mjs

# Optional: mit fertigem Workspace-Bundle (statt Addon-Direktkopie)
python3 tools/build_web_bundle.py --project . --out build/web_bridge
PYODIDE_PKG=.webtest/node_modules/pyodide node tools/test_web_runtime.mjs \
    --bundle build/web_bridge/bridge_workspace.tar
```

## Versionshistorie

- **v0.5.0** — **Web-Sync und Cython wirklich lauffähig**: neuer `file_op`-Kanal
  spiegelt Skripte in den Pyodide-Workspace (mit Puffer, falls noch keine
  Instanz läuft), das Editor-Dock meldet Speichern/Umbenennen an die Bridge,
  Cython baut jetzt auch auf Windows (MSVC → MinGW, POSIX: gcc → zig) und
  erkennt geänderte `.pyx` per Hash; Modulnamen werden plattformfest abgeleitet
  (Cython-Calls liefen auf Windows vorher in `ModuleNotFoundError`). Speichern
  als `.py` räumt Cython-Reste ab, ohne die Datei bei Schreibfehlern zu
  verlieren. **Einstellungen sind auffindbar**: Projekt → Projekteinstellungen →
  Python Bridge (7 Felder), `⋯ → Einstellungen …` im Dock mit „Speichern &
  neustarten“, neues Werkzeuge-Menü und optionale `config.json`
  (Praezedenz: Defaults → Projekt-Einstellungen → `config.json` → `configure()`).
- **v0.4.0** — **Editor-Dock-Redesign**: Tab-Container mit stabilen Tabs,
  korrigiertes Syntax-Highlighting (Farb-Reset + gecachter Mehrzeilen-Zustand),
  fehlerfreies Öffnen/Speichern (leere Datei ≠ Fehler, CRLF/BOM-Normalisierung),
  temporäre Scratch-Tabs (`execute()`), rückstandsfreies Löschen
  (`PythonBridge.delete_script` entfernt Quelle, `.c`, `.so`/`.pyd`, `.pyc`,
  `__pycache__`, Build-Zustand und Wrapper), Umbenennen, Shortcuts,
  testbare Dateischicht (`editor/script_store.gd`, `core/script_files.gd`),
  neue Headless-Tests (Editor-Dateischicht + Highlighter) und die neue
  verbindliche Anleitung `docs/ERSTE_SCHRITTE.md`.
- **v0.3.3** — `__bridge_deps__` wird überall erkannt (auch in `.pyx`),
  Dependencies im Workspace-Scan.
- **v0.3.2** — Cython-Sonderpfad (`.pyx`, inkrementeller Build, zig-Fallback),
  Export-Skripte, ZIP-Build, Belastungsprobe.
- **v0.3.1** — Stabilitäts- und Doku-Fixes.
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
