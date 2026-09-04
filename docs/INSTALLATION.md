# Installation & Erste Schritte

## Voraussetzungen

- Godot 4.2+ (getestete Basis; die verwendeten APIs existieren ab 4.2)
- Python 3.8+ (wird automatisch gefunden oder per `python_executable` gesetzt)

## Installation

1. Den Ordner `addons/python_bridge` in das Zielprojekt nach
   `res://addons/python_bridge/` kopieren.
2. Godot öffnen → Projekt → Projekteinstellungen → Plugins →
   „Python Bridge“ aktivieren.
3. Das Plugin registriert den Autoload `PythonBridge` und fügt das
   Python-Editor-Dock (rechts) hinzu.
4. Beim ersten `start_instance()` wird automatisch:
   - `res://python_bridge/` mit `scripts/`, `tmp/`, `config/`, `venv/`
     angelegt,
   - eine venv erzeugt (falls fehlt),
   - `websockets>=11` (+ konfigurierte Dependencies) installiert
     (nicht-blockierend, Log in `tmp/pip.log`),
   - der Python-Server gestartet und per WebSocket verbunden (READY).

Hinweis: `python_bridge/venv/` enthält eine `.gdignore`-Datei, damit Godot
sie nicht als Ressourcen importiert.

## Minimalbeispiel

```gdscript
# script.gd (beliebiger Node)
func _ready() -> void:
    var start := await PythonBridge.start_instance("default")
    if start.is_error():
        push_error("Start: " + start.error_message())
        return

    PythonBridge.create_script("beispiel", """
def calculate(a, b):
    return a * b
""")

    var r := await PythonBridge.call_script("beispiel", "calculate", [6, 7])
    print("Ergebnis: ", r.value)   # 42
```

Oder das beiliegende Beispielprojekt nutzen (Wurzel dieses Repos ist ein
minimales Godot-Projekt): `example/demo.gd` zeigt `calculate/greet/fibonacci`
plus die Task-API.

## Tests

```bash
# Python-Tests (benötigt nur Python 3.8+ und websockets im PATH)
python3 -m unittest discover -s tests/python -p "test_*.py"

# GDScript-Tests (benötigt Godot-Binary; Projekt einmal im Editor öffnen,
# damit die class_names registriert sind)
godot --headless --path . --script res://tests/gdscript/run_tests.gd
```

## Python suchen / konfigurieren

Die Bridge findet Python in dieser Reihenfolge:

1. `python_executable` (konfiguriert, muss existieren)
2. `PYTHON_PATH` (Umgebungsvariable)
3. PATH-Suche (`python.exe`, `python3.exe`, `python`, `python3`, `py`)
4. Plattform-Fallback (`where python` / `command -v python3`)

Bei Problemen: `PythonBridge.configure({"python_executable": "/abs/pfad/zum/python"})`
vor dem ersten `start_instance()` setzen.

## Mehrere Instanzen

```gdscript
await PythonBridge.start_instance("worker1")
await PythonBridge.start_instance("worker2")
# Tasks an eine bestimmte Instanz:
await PythonBridge.call_script("skript", "f", [1], {}, "worker2")
# Oder Auto-Zuordnung: instance-Parameter weglassen bzw. "" übergeben.
```

Parallelität entsteht durch mehrere Instanzen (je ein Python-Prozess);
innerhalb einer Instanz wird strikt sequenziell ausgeführt.