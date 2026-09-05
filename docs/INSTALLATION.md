# Installation & Erste Schritte

## Voraussetzungen

- Godot 4.2+ (getestete Basis; die verwendeten APIs existieren ab 4.2)
- Python 3.8+ (wird automatisch gefunden oder per `python_executable` gesetzt)

## Installation — Schritt für Schritt

### Schritt 1: Addon in das Projekt kopieren

Den kompletten Ordner `addons/python_bridge/` in das Wurzelverzeichnis
des Zielprojekts kopieren, sodass er unter
`res://addons/python_bridge/` liegt (im Godot-**FileSystem**-Dock
sichtbar).

### Schritt 2: Das Plugin aktivieren

1. Godot öffnen (das Projekt muss neu gescannt werden, damit das Addon
   im **FileSystem**-Dock unter `addons/` auftaucht).
2. Hauptmenü oben: **Projekt → Projekteinstellungen…**
3. Im Dialog oben auf den Reiter **Plugins** klicken.
4. Genau ein Eintrag: **Python Bridge** → rechts das Häkchen bei
   **Aktivieren** setzen.
5. Godot fragt ggf. nach einem **Editor-Neustart** → zustimmen.

Wichtig: **Ohne diesen Schritt existiert das Dock noch nicht.** Die
Aktivierung bewirkt zwei Dinge:

- Der Autoload-Singleton **`PythonBridge`** wird registriert
  (Projekt → Projekteinstellungen → Autoload; von dort rufen alle
  deine Skripte `PythonBridge.call_script(...)` usw. auf).
- Das Editor-Dock wird in den rechten Dock-Streifen gehängt.

### Schritt 3: Das „Python Bridge“-Dock finden

Das Dock ist ein Panel in der **rechten Dock-Leiste des Editors** —
derselbe vertikale Streifen, in dem auch **FileSystem** (Standard:
oberer Bereich) und **History/Node/Editor-Doku** (unterer Bereich)
liegen. Genauer Ort: **rechts, oberer Slot, direkt neben dem
FileSystem-Tab** (Registrierung: `DOCK_SLOT_RIGHT_UL`).

```
┌─ Editor ────────────────────────────┬──────────────────────────┐
│ Szene        │                      │ FileSystem │ rechter     │
│              │    2D/3D-Viewport    │ Python     │ Dock-Streifen│
│              │                      │ Bridge   ◄─│ DIESER Tab  │
│              │                      │ ═══════════│             │
│              │                      │ History, Node, … (unten) │
├──────────────┴──────────────────────┴──────────────────────────┤
│ Unterer Bereich: Output, Debugger, …                            │
└────────────────────────────────────────────────────────────────┘
```

So erkennst du es:

- Am **rechten Fensterrand** steht eine **vertikale Spalte von
  Tab-Beschriftungen** (gedrehter Text, nur die Beschriftung sichtbar,
  solange das Panel zugeklappt ist).
- Klicke auf den vertikalen Tab **„Python Bridge“** → das Panel fährt
  aus und enthält von oben nach unten:
  1. Kopfzeile: **Refresh** + **New script** + Statusanzeige
  2. **Skriptliste** (alle `.py`-Dateien aus `res://python_bridge/scripts/`)
  3. **Code-Editor** mit Python-Syntax-Highlighting
  4. Aktionszeile: **Save** · **Run** · **Generate wrapper** · **Hot reload**
  5. **Log**-Bereich
- Falls der Tab fehlt oder verschoben wurde: **Editor → Editor-Layout →
  Standard-Layout** setzt alle Docks zurück.

### Schritt 4: Erste Python-Datei über das Dock anlegen

1. Im Dock auf **New script** klicken → Name eingeben (z. B. `hallo`)
   → es entsteht `res://python_bridge/scripts/hallo.py` — eine
   **ganz normale .py-Datei** (auch außerhalb von Godot ausführbar).
2. Code eintippen/einfügen → **Save**.
3. Optional: **Run** führt die Datei sofort aus (Ergebnis im Log),
   **Generate wrapper** erzeugt eine GDScript-Anbindung,
   **Hot reload** lädt Änderungen ohne Neustart.

### Schritt 5: Was beim ersten Start automatisch passiert

Beim ersten `await PythonBridge.start_instance("default")` (aus
gdscript, siehe Minimalbeispiel unten) legt die Bridge automatisch an:

- `res://python_bridge/` mit `scripts/`, `tmp/`, `config/`, `venv/`,
- eine venv (falls fehlt),
- `websockets>=11` (+ konfigurierte Dependencies) — nicht-blockierend,
  Log in `tmp/pip.log`,
- den Python-Server als Subprozess + WebSocket-Verbindung bis READY.

Du startest **niemals selbst ein Terminal** für Python — die Bridge
verwaltet Prozess, Verbindung und Tasks vollständig.

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