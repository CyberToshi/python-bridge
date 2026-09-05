# Python Bridge für Godot 4

Eine allgemeine, production-orientierte Python-Bridge: Python-Code wird direkt
aus Godot heraus geschrieben, verwaltet und ausgeführt. Python bleibt echter
Python-Code; Godot bleibt der kontrollierende Host. Die Bridge übernimmt die
gesamte Infrastruktur: Python-Prozesse, WebSocket-Kommunikation, Task-Verwaltung
mit Priorität/Batching/Backpressure, Frame-Synchronisation, Health Monitoring,
Crash-Restart, venv-Provisioning, Hot Reload, Python-Editor und automatische
GDScript-Wrapper-Generierung.

> **Wichtigste Architekturregel:** Die Bridge macht Python **nicht** zu einem
> zweiten GDScript. Python bleibt Python, Godot bleibt Godot — verbunden über
> eine klar definierte, modulare Kommunikationsschicht.
>
> **Invariante:** Python wartet nie auf einen Godot-Frame, und Godot wartet
> nie auf Python.

## Inhalt

```
addons/python_bridge/   das Add-on (Kern + Editor + Python-Paket)
core/                   TaskManager, Scheduler, Instanzen, Protokoll, Typ-Mapping
editor/                 Dock-Panel, Syntax-Highlighting, Wrapper-Generator
python/                 Python-Server (asyncio + Worker-Thread), Executor, Introspection
docs/                   Architektur, API, Installation, Troubleshooting, Changelog
example/                Minimalbeispiel (demo.gd + Beispielskript)
tests/python/           Python-`unittest`-Suite (ausführbar, 33 Tests grün)
tests/gdscript/         GDScript-Headless-Testrunner (godot --headless)
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

Ausführlicher: [docs/INSTALLATION.md](docs/INSTALLATION.md),
[docs/API.md](docs/API.md), [docs/ARCHITEKTUR.md](docs/ARCHITEKTUR.md).

## Tests

```bash
# Python-Tests
python3 -m unittest discover -s tests/python -p "test_*.py"

# GDScript-Tests (Godot-Binary nötig; Projekt einmal im Editor öffnen)
godot --headless --path . --script res://tests/gdscript/run_tests.gd
```

## Versionshistorie

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