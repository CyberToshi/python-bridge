---
sidebar_position: 3
title: Erste Schritte
description: Dein erstes Hello-World-Beispiel mit Godot und Python.
---

# Erste Schritte: Hello World

In diesem Beispiel startet Godot den Python-Prozess selbst, sendet eine
Nachricht und gibt die Python-Antwort in der Godot-Konsole aus.

Du brauchst zwei Dateien:

```text
res://scripts/hello_bridge.gd
res://python_bridge/scripts/hello.py
```

Die Python-Datei bleibt eine normale Python-Datei. Du musst sie nicht vorher im
Terminal starten.

## 0. Alternativ: Mitgelieferte Beispiele starten

Das Projekt enthält zwei lauffähige Beispiele:

- **`res://example/hello/`** (`hello_world.tscn`) — minimales Hello-World.
  Öffne die Szene im Editor und drücke **F6** – das Skript kopiert `hello.py`
  selbst in den Bridge-Workspace, startet die Instanz und zeigt die Antwort
  in der Konsole. Der manuelle Weg unten erklärt Schritt für Schritt, was
  dabei intern passiert.
- **`res://example/web_demo/`** — komplettes Web-Demo-Projekt: dieselbe Szene
  und derselbe Python-Code laufen auf Desktop **und** im Browser (Pyodide),
  inklusive Modul-Import (`modules/calculations.py`), Plugin-Import und
  fertigem Web-Export-Preset. Workflow und Deployment: siehe
  [Python im Browser](./web-runtime) bzw. `example/web_demo/README.md` im
  Repository.

## 1. Python-Datei erstellen

Lege die Datei

```text
res://python_bridge/scripts/hello.py
```

an und füge diesen Code ein:

```python
def say_hello(message: str) -> str:
    """Return a greeting for Godot."""
    return f"Hello Godot! Python received: {message}"
```

Die Funktion nimmt einen String entgegen und gibt einen String zurück.

## 2. GDScript-Datei erstellen

Lege die Datei

```text
res://scripts/hello_bridge.gd
```

an:

```gdscript
extends Node

const PYTHON_SCRIPT := "hello"
const PYTHON_INSTANCE := "default"

var _python_ready := false
var _frame_counter := 0

func _ready() -> void:
    var started: PythonBridgeResult = await PythonBridge.start_instance(
        PYTHON_INSTANCE
    )

    if started.is_error():
        push_error("Python Bridge start failed: " + started.error_message())
        return

    _python_ready = true
    await _send_hello()

func _send_hello() -> void:
    var result: PythonBridgeResult = await PythonBridge.call_script(
        PYTHON_SCRIPT,
        "say_hello",
        ["Hello Python"],
        {},
        PYTHON_INSTANCE,
        30.0
    )

    if result.is_ok():
        print("[Godot] Python antwortet: ", result.value)
    else:
        push_error(
            "Python task failed [" + result.error_code() + "]: "
            + result.error_message()
        )
        if result.error.has("traceback"):
            push_error(str(result.error["traceback"]))

func _process(_delta: float) -> void:
    if not _python_ready:
        return

    # Beispiel für eine asynchrone periodische Anfrage.
    _frame_counter += 1
    if _frame_counter % 60 == 0:
        _send_frame_update()

func _send_frame_update() -> void:
    var payload := {
        "frame": _frame_counter,
        "time_seconds": Time.get_ticks_msec() / 1000.0
    }

    var result: PythonBridgeResult = await PythonBridge.execute(
        "result = {\"python_says\": \"Hello Godot\", \"received\": input}",
        payload,
        PYTHON_INSTANCE,
        5.0
    )

    if result.is_ok():
        print("[Godot] Frame-Antwort: ", result.value)
    else:
        push_error("Frame task failed: " + result.error_message())

func _exit_tree() -> void:
    # Beendet den Python-Prozess kontrolliert, wenn diese Demo-Szene endet.
    PythonBridge.shutdown()
```

## 3. Script an einen Node anhängen

1. Öffne deine Szene, zum Beispiel `main.tscn`.
2. Wähle den Root-Node aus.
3. Klicke auf **Attach Script**.
4. Wähle `res://scripts/hello_bridge.gd`.
5. Speichere die Szene.
6. Starte sie mit **F6** oder das Projekt mit **F5**.

Fertig ist eine lauffähige Szene zum Ausprobieren:
`res://example/hello/hello_world.tscn` (per F6 startbar – sie erledigt den
Sync-Schritt aus Schritt 1 automatisch).

Der Node-Typ ist nicht festgelegt. Für dieses Beispiel funktionieren unter
anderem:

- `Node`
- `Node2D`
- `Control`

`PythonBridge` selbst ist ein Autoload und muss nicht an diesen Node angehängt
werden.

## 4. Erwartete Ausgabe

In der Godot-Konsole sollte ungefähr Folgendes erscheinen:

```text
[Godot] Python antwortet: Hello Godot! Python received: Hello Python
[Godot] Frame-Antwort: { ... }
```

Beim ersten Start kann die Erstellung der virtuellen Umgebung einige Zeit
dauern. Danach wird der vorhandene Python-Workspace wiederverwendet.

## 5. Was wird gesendet und empfangen?

Dieser Aufruf:

```gdscript
await PythonBridge.call_script(
    "hello",
    "say_hello",
    ["Hello Python"],
    {},
    "default",
    30.0
)
```

bedeutet:

| GDScript | Python |
|---|---|
| `"hello"` | Datei `hello.py` |
| `"say_hello"` | Funktion `say_hello` |
| `["Hello Python"]` | Funktionsargument `message` |
| `PythonBridgeResult.value` | Rückgabewert von `return` |

Die Antwort wird nicht direkt in einem Hintergrundthread in einen Node
geschrieben. Die Bridge puffert das Ergebnis und übergibt es kontrolliert an
den Godot-Main-Thread.

## 6. Strukturierte Daten senden

Python kann auch Dictionaries zurückgeben:

```python
def describe(value: dict) -> dict:
    return {
        "python_says": "Hello Godot",
        "received": value,
        "count": len(value),
    }
```

GDScript ruft die Funktion so auf:

```gdscript
var result: PythonBridgeResult = await PythonBridge.call_script(
    "hello",
    "describe",
    [{"name": "Ada", "language": "Python"}],
    {},
    "default",
    30.0
)

if result.is_ok():
    var answer: Dictionary = result.value
    print(answer.get("python_says"))
    print(answer.get("received"))
```

## 7. Python-Fehler behandeln

Python-Ausnahmen werden strukturiert zurückgegeben:

```gdscript
if result.is_error():
    print(result.error_code())
    print(result.error.get("type", ""))
    print(result.error.get("message", ""))
    print(result.error.get("traceback", ""))
```

Damit bleibt die eigentliche Ursache sichtbar und wird nicht durch eine
allgemeine Fehlermeldung ersetzt.

## 8. Typische Stolpersteine (aus der Praxis)

Die häufigsten Fehler, die Einsteiger treffen — und wie du sie in Sekunden
erkennst:

### `print(result.value)` zeigt `<RefCounted#...>`

`call_script` gibt ein **Ergebnis-Objekt** zurück, nicht den Wert. Der Wert
steckt in `.value`:

```gdscript
var r = await PythonBridge.call_script("hello", "say_hello", ["Hi"])
print(r.value)   # nicht: print(r)
```

### `result.value` ist `null`

Zwei mögliche Ursachen — der Unterschied liegt in `is_ok()`:

```gdscript
if r.is_ok():
    print("Python hat None zurückgegeben")   # return vergessen?
else:
    print("Aufruf fehlgeschlagen: ", r.error) # Ursache steht hier
```

- **`ok=true`, `value=null`**: Dein Python-Code hat kein `return` gesetzt.
- **`ok=false`**: Der Aufruf ist fehlgeschlagen — `r.error` enthält
  `code`, `message` und `traceback`. **Immer dieses Muster verwenden**, nie
  blind `.value` lesen. (Ein fehlender `return` oder falsche Argumente
  sehen ohne `is_ok()` identisch aus: `null`.)

### Argumente passen nicht zur Funktion

Cython-Funktionen haben typisierte Parameter — ein falscher Typ wird
hart abgelehnt (anders als in reinem Python):

```python
def smear(list xs, int passes):   # will Liste + Zahl
```

```gdscript
# FALSCH:  call_script("m", "smear", [3.5, 100000])   -> TypeError
# RICHTIG: call_script("m", "smear", [[1.0, 2.0, 3.0], 100000])
```

### Skript-Name vs. Datei-Name

Die Skript-ID ist der **Dateiname ohne Endung**: Datei `mathtools.pyx` →
`call_script("mathtools", ...)`. Existiert die Datei nicht im
`scripts`-Ordner des Workspaces, gibt es einen klaren
`BRIDGE_ERROR`-Fehler (kein Crash).

### Der goldenen Debug-Print

Wenn irgend etwas unklar ist, zuerst diese Zeile (temporär einbauen):

```gdscript
print("ok=", r.is_ok(), " | value=", r.value, " | error=", r.error)
```

Sie zeigt sofort, auf welcher Seite das Problem liegt — Python-Fehler
(`PYTHON_EXCEPTION` mit Traceback), fehlende Pakete (`DEPENDENCY_ERROR`)
oder falsche IDs (`BRIDGE_ERROR`).

## Nächste Schritte

- [Konfiguration](./konfiguration) – alle Einstellungen erklärt
- [Python-Seite verstehen](./python-seite) – Kontexte, Zustand, Abbruch
- [Große Daten (DataRefs)](./datenebene) – wenn deine Ergebnisse groß werden
- [API-Referenz](./api) – jede Funktion dokumentiert
- [Bedienung im Editor](./editor-ui) – das Python-Dock
- [Installation](./installation)
- Im Repository: `docs/HANDS_ON_CONNECT_GUIDE.md` für den ausführlichen
  manuellen Workflow
