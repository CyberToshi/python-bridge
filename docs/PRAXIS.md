# Praxis: Python-Code in dein Godot-Projekt einbetten

Diese Anleitung zeigt den kompletten Workflow an einem durchgängigen Beispiel:
Eine Python-Datei, die Punkte berechnet, wird in Godot eingebettet und aus
einer Scene heraus aufgerufen.

---

## 1. Wo liegt dein Python-Code?

Alle Python-Dateien liegen im **Bridge-Workspace**:

```
res://python_bridge/
├── scripts/        <-- HIER schreibst du deine .py-Dateien
│   └── mein_skript.py
├── wrappers/       <-- generierte GDScript-Wrapper (vom Editor erzeugt)
├── venv/           <-- automatisch angelegte Python-Umgebung (nicht anfassen)
└── tmp/            <-- Laufzeitdaten, Ports, Logs
```

Das ist eine **normale .py-Datei** — du kannst sie auch außerhalb von Godot
mit einem normalen Python importieren und testen.

> Hinweis: Der Workspace wird beim ersten Start automatisch angelegt.
> Der Default ist `res://python_bridge/`, änderbar über
> `PythonBridge.configure({"workspace_dir": "res://..."})`.

---

## 2. Eine Python-Datei anlegen

Lege z. B. `res://python_bridge/scripts/mein_skript.py` an:

```python
"""Mein erstes Bridge-Skript."""

def addiere(a: float, b: float) -> float:
    """Addiert zwei Zahlen."""
    return a + b

def begruesse(name: str, praefix: str = "Hallo") -> str:
    """Begrüßt jemanden."""
    return "%s, %s!" % (praefix, name)

def fibonacci(n: int) -> list:
    seq = [0, 1]
    while len(seq) < n:
        seq.append(seq[-1] + seq[-2])
    return seq[:n]
```

Zwei Wege, die Datei anzulegen:

- **Im Editor-Dock** (empfohlen): Rechts den vertikalen Tab
  **„Python Bridge“** anklicken (rechter Dock-Streifen, oberer Slot,
  neben dem FileSystem-Tab — genaue Klick-Anleitung:
  `docs/INSTALLATION.md`, Schritt 2–3) → **New script** → Namen eingeben
  → Code schreiben → **Save**. Das Dock zeigt die Skripte aus
  `res://python_bridge/scripts/` automatisch.
- **Von Hand**: Datei im Dateisystem anlegen; das Dock erkennt sie über den
  mtime-Watcher automatisch.

Die Buttons im Dock im Überblick:

| Button | Wirkung |
|---|---|
| **Refresh** | Skriptliste neu einlesen |
| **New script** | Neue `.py`-Datei im Workspace anlegen |
| **Save** | Aktuell geöffneten Code speichern |
| **Run** | Datei sofort ausführen (`execute_script`), Ausgabe im Log |
| **Generate wrapper** | GDScript-Klasse für das Skript erzeugen (siehe Abschnitt 5) |
| **Hot reload** | Geänderten Code ohne Neustart neu laden |

---

## 3. Die Bridge starten (einmal pro Session)

In deiner Szene (z. B. im `_ready()` des Root-Nodes):

```gdscript
extends Node

func _ready() -> void:
    # Startet Python, legt ggf. die venv an, installiert Dependencies,
    # startet den Server und wartet, bis die Instanz READY ist.
    var start: PythonBridgeResult = await PythonBridge.start_instance("default")
    if start.is_ok():
        print("Python bereit!")
    else:
        push_error("Start fehlgeschlagen: " + start.error_message())
```

Die Instanz heißt standardmäßig `"default"`. Beim Beenden von Godot fährt
die Bridge automatisch sauber herunter (kein Zombie-Prozess).

---

## 4. Python aus GDScript aufrufen

### 4.1 Einfachster Weg: `call_script`

```gdscript
# Args (positional) und Kwargs (keyword) getrennt übergeben:
var r: PythonBridgeResult = await PythonBridge.call_script(
    "mein_skript",          # Skript-ID = Dateiname ohne .py
    "addiere",              # Funktionsname
    [2.0, 3.0],             # positional args
    {},                     # keyword args
    "default",              # Instanz
    30.0)                   # Timeout in Sekunden

if r.is_ok():
    print("2 + 3 = ", r.value)      # -> 5.0
else:
    print("Fehler: ", r.error_message())
```

### 4.2 Optionale Parameter (Defaults bleiben in Python!)

```gdscript
# begruesse("Welt", praefix="Servus"):
var g: PythonBridgeResult = await PythonBridge.call_script(
    "mein_skript", "begruesse", ["Welt"], {"praefix": "Servus"})
print(g.value)   # -> "Servus, Welt!"

# Default-Parameter nutzen (praefix bleibt "Hallo"):
var g2: PythonBridgeResult = await PythonBridge.call_script(
    "mein_skript", "begruesse", ["Welt"])
print(g2.value)  # -> "Hallo, Welt!"
```

### 4.3 Ergebnis-Typen

Die Bridge konvertiert automatisch (siehe Typ-Mapping):

| Python                  | Godot                    |
|-------------------------|--------------------------|
| `int` / `float`         | `int` / `float`          |
| `str`                   | `String`                 |
| `bool` / `None`         | `bool` / `null`          |
| `list`                  | `Array`                  |
| `dict`                  | `Dictionary`             |
| `bytes`                 | `PackedByteArray` (Binary Frame) |
| `numpy.ndarray`         | `PackedFloat32Array`/`PackedInt32Array`/... |
| `datetime`/`date`/`time`| `String` (ISO 8601)       |
| `Decimal`               | `String` (exakte Dezimaldarstellung) |
| `UUID`                  | `String`                  |
| `pathlib.Path`          | `String` (Pfad)           |
| `enum.Enum`             | Wert des Members (z. B. `String`/`int`) |
| Objekt (nicht JSON-fähig) | String (repr-Fallback)  |

---

## 5. Wrapper generieren (optional, aber praktisch)

Statt `call_script` jedes Mal von Hand zu schreiben, erzeugt dir die Bridge
eine GDScript-Klasse pro Python-Datei:

1. Im Editor-Dock dein Skript auswählen → **Generate wrapper**.
2. Es entsteht `res://python_bridge/wrappers/mein_skript.gd` mit einem
   Marker-Header (`# ===== GENERATED BY PYTHON BRIDGE - DO NOT EDIT =====`).
3. In GDScript nutzt du dann direkt:

```gdscript
var skript := MeinSkript.new()          # class_name aus der .py abgeleitet
var r: PythonBridgeResult = await skript.addiere(2.0, 3.0)
print(r.value)                          # -> 5.0
```

Der Wrapper ruft intern `PythonBridge.call_script()` auf — er enthält
keinerlei Python-Logik. Änderst du die Python-Datei, klicke im Dock einfach
erneut auf **Generate wrapper** (nur markierte Dateien werden überschrieben,
dein manueller Code bleibt unangetastet).

> Die Type-Hints in deiner .py sind nur Hinweise — der Wrapper übergibt alles
> als Variant und die Python-Seite ist die Autorität.

---

## 6. Vollständiges Beispiel: Scene + Node + Python

`example/demo_scene.tscn` zeigt genau diesen Ablauf. Der minimale Kern:

```gdscript
# res://scripts/mein_spieler.gd  (an einem Node in deiner Scene)
extends Node

var _bereit := false

func _ready() -> void:
    await PythonBridge.start_instance("default")
    _bereit = true

func _on_button_pressed() -> void:
    if not _bereit:
        return
    var r: PythonBridgeResult = await PythonBridge.call_script(
        "mein_skript", "fibonacci", [10])
    if r.is_ok():
        print("Fibonacci: ", r.value)   # -> [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
```

---

## 7. Fehler aus Python ansehen

```gdscript
var r: PythonBridgeResult = await PythonBridge.call_script(
    "mein_skript", "gibt_es_nicht", [])
if r.is_error():
    print("Code:    ", r.error_code())      # z. B. "PYTHON_EXCEPTION"
    print("Typ:     ", r.error.get("type"))       # z. B. "AttributeError"
    print("Message: ", r.error.get("message"))
    print("Trace:   ", r.error.get("traceback"))
    print("Task-ID: ", r.error.get("task_id"))
```

---

## 8. Mehrere Python-Instanzen

```gdscript
# Zweite Instanz starten:
await PythonBridge.start_instance("worker")

# Task explizit einer Instanz zuordnen:
var task := PythonBridgeTask.make_call(
    "mein-task", "script:mein_skript",
    PythonBridge.get_script_source("mein_skript"),
    "addiere", [1.0, 2.0], {}, 30000)
task.instance_id = "worker"
PythonBridge.submit_task(task)
var res: PythonBridgeResult = await task.done
print(res.value)

PythonBridge.stop_instance("worker")
```

---

## 9. Dependencies (requirements.txt)

Lege `res://python_bridge/requirements.txt` an oder setze die Abhängigkeiten
in der Konfiguration:

```gdscript
PythonBridge.configure({"dependencies": PackedStringArray(["numpy"])})
```

Die Bridge erkennt fehlende Pakete, installiert sie in die projektbezogene
venv (nicht-blockierend, mit Log unter `python_bridge/tmp/pip.log`) und
verifiziert den Import.

---

## 10. Typischer Ablauf auf einen Blick

```
1. Addon kopieren:            addons/python_bridge/  →  res://addons/python_bridge/
2. Plugin aktivieren:         Projekt → Projekteinstellungen → Plugins
                              → "Python Bridge" aktivieren
                              (registriert Autoload "PythonBridge" + Dock)
3. Dock öffnen:               rechter Dock-Streifen, vertikaler Tab
                              "Python Bridge" (neben FileSystem)
4. Python-Datei schreiben:    im Dock: New script → Code → Save
                              → res://python_bridge/scripts/mein_skript.py
5. (optional) Wrapper:        im Dock: Skript wählen → Generate wrapper
6. In GDScript:               await PythonBridge.start_instance("default")
7. Aufrufen:                  await PythonBridge.call_script("mein_skript", "fn", [args])
   oder:                      await MeinSkript.new().fn(args)
8. Ergebnis ist ein PythonBridgeResult → .is_ok() / .value / .error_message()
```

Die Schritte 1–3 im Detail (mit Editor-Menus und Dock-Anatomie):
`docs/INSTALLATION.md`. Beide Seiten komplett als Copy-Paste-Code:
`docs/HANDS_ON_CONNECT_GUIDE.md`.

Mehr Details zu jedem Baustein: `docs/API.md`, `docs/ARCHITEKTUR.md`,
`docs/ARCHITEKTUR_V3.md` (Plan; Phasen 0–3 inkl. ScriptRegistry,
Data-Plane-Kern und Worker/Recovery sind implementiert),
`docs/DATA_PLANE.md` (grosse Daten, DataRef-Handles, Frame-Budget),
`docs/WORKERS.md` (parallele Worker, kooperative Cancellation, Watchdog),
`docs/BOTTLENECKS.md`,
`docs/PythonBridge_Dokumentation.pdf` und die lauffähige Demo-Szene
`example/demo_scene.tscn`.