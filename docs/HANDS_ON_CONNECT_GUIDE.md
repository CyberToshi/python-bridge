# HANDS-ON: GDScript mit Python verbinden (Copy-Paste-Anleitung)

Diese Anleitung zeigt die **exakten manuellen Schritte**: welcher Node
welches Skript bekommt, den vollständigen Code für **beide Seiten** und wie
die Daten dazwischen fließen. Sie ist die ausführliche Ergänzung zur
Online-Dokumentation unter <https://cybertoshi.github.io/python-bridge/>
(speziell [Erste Schritte](https://cybertoshi.github.io/python-bridge/docs/getting-started)).

Nach dieser Anleitung hast du:

- einen GDScript-Node, der die Bridge öffnet, `"Hello Python"` sendet und
  `"Hello Godot"` empfängt – gedruckt in der Godot-Konsole;
- eine normale Python-Datei, die den Aufruf beantwortet.

**Wichtig vorab:** Du startest Python **nicht** selbst im Terminal. Der
GDScript-Aufruf `PythonBridge.start_instance()` startet den Python-Prozess
(venv + Server) automatisch und verbindet sich per WebSocket. Deine `.py`-Datei
ist nur eine Datei – sie läuft nie eigenständig.

---

## 0. Einmalige Projekt-Einrichtung (falls noch nicht geschehen)

1. Kopiere `addons/python_bridge/` in deinen Projektordner.
2. Öffne das Projekt in Godot.
3. **Projekt → Projekt-Einstellungen → Plugins** → *Python Bridge* aktivieren.
   Das registriert den Autoload `PythonBridge` (das Singleton, das deine
   Skripte aufrufen) und das Editor-Dock.
4. Prüfen: **Projekt → Projekt-Einstellungen → Autoload** zeigt
   `PythonBridge → res://addons/python_bridge/core/python_bridge.gd`.

---

## 1. Die Python-Seite anlegen (der Gegenpart)

Im Godot-Editor:

1. Öffne das Dock **Python Bridge** (oben rechts).
2. Klick auf **New script** → Name `hello` (legt
   `res://python_bridge/scripts/hello.py` an – eine normale `.py`-Datei).
3. Diesen Code einfügen und **Save** klicken:

```python
"""Minimaler Gegenpart für die Godot-Bridge-Demo.

Konventionen:
  call_script:    Godot ruft eine Funktion auf; der Rückgabewert geht zurück.
  execute_script: `input` hält die von Godot gesendeten Daten, `result` hält,
                  was Godot zurückbekommt.
"""


def say_hello(message: str) -> str:
    """Beantwortet ein Hello von Godot."""
    return "Hello Godot (from Python, received: %s)" % message


def echo(input_data) -> dict:
    """Gibt zurück, was Godot gesendet hat, plus einen Marker."""
    return {"python_says": "Hello Godot", "received": input_data}


# Wird nur von execute_script benutzt: Godot setzt `input`, wir setzen `result`.
result = None
if input:
    result = echo(input)
```

Das ist die ganze Python-Seite. Kein Server-Code, keine Sockets, kein asyncio –
die Bridge injiziert das alles. Die Datei bleibt eine normale `.py`, die du
außerhalb von Godot importieren und testen kannst.

---

## 2. Die GDScript-Seite anlegen (die Schnittstelle)

Lege `res://scripts/hello_bridge.gd` mit diesem **vollständigen, lauffähigen
Code** an:

```gdscript
extends Node
## Vollständige Schnittstelle zwischen Godot und Python via Python Bridge.
## An einen beliebigen Node der Szene hängen. Startet den Python-Prozess,
## sendet "Hello Python", empfängt die Antwort und druckt sie.

const SCRIPT_ID := "hello"          # -> res://python_bridge/scripts/hello.py
const INSTANCE_NAME := "default"    # von der Bridge verwaltete Instanz

var _ready_to_call := false
var _frame_count := 0


func _ready() -> void:
    # --- 1) Python starten (venv, Server, WebSocket) und auf READY warten.
    #        Du startest Python NICHT selbst - dieser Call macht alles.
    var start: PythonBridgeResult = await PythonBridge.start_instance(INSTANCE_NAME)
    if start.is_error():
        push_error("Python-Start fehlgeschlagen: " + start.error_message())
        return

    # --- 2) Minimalbeispiel: "Hello Python" senden, "Hello Godot" empfangen.
    await _send_hello()

    # --- 3) Periodischen Aufruf in der Game-Loop aktivieren.
    _ready_to_call = true


func _send_hello() -> void:
    # SENDEN: die ersten Argumente gehen AN Python.
    # EMPFANGEN: `await` liefert ein PythonBridgeResult mit .value / .error.
    var r: PythonBridgeResult = await PythonBridge.call_script(
        SCRIPT_ID,          # welche .py-Datei
        "say_hello",        # welche Funktion darin
        ["Hello Python"],   # Positionsargumente -> def say_hello(message)
        {})                 # Keyword-Argumente -> z. B. {"extra": 42}
    if r.is_ok():
        # r.value enthält, was die Python-Funktion zurückgegeben hat.
        print("[GDScript] Python antwortet: ", r.value)
    else:
        print("[GDScript] Fehler: ", r.error_code(), " - ", r.error_message())


func _process(_delta: float) -> void:
    # Jeden Frame von der Engine aufgerufen. Python-Ergebnisse blockieren
    # diese Loop NIE: Calls sind asynchron (await), und die Bridge liefert
    # Antworten kontrolliert in Batches pro Frame in den Main-Thread.
    if not _ready_to_call:
        return
    _frame_count += 1
    if _frame_count % 60 == 0:      # einmal pro Sekunde bei 60 FPS
        _tick_python()


func _tick_python() -> void:
    # Periodischer Aufruf: zeigt den Roundtrip Game-Loop <-> Python.
    var payload := {"frame": _frame_count, "time": Time.get_ticks_msec() / 1000.0}
    var r: PythonBridgeResult = await PythonBridge.call_script(
        SCRIPT_ID, "echo", [], {"input_data": payload})
    if r.is_ok():
        var answer: Dictionary = r.value
        print("[GDScript] frame ", _frame_count,
              " -> Python: ", answer.get("python_says", "?"),
              " | gesendet: ", answer.get("received", {}))


func _exit_tree() -> void:
    # Sauberer Shutdown beim Schließen der Szene (beendet den Python-Prozess).
    PythonBridge.shutdown()
```

---

## 3. Welcher Node bekommt das Skript? (Klick für Klick)

1. Öffne (oder erstelle) deine Szene, z. B. `main.tscn`.
2. Wähle **einen beliebigen Node** im Szenenbaum. Für einen Hello-Test ist
   der Wurzel-`Node` in Ordnung:
   - 2D-Spiel → `Node2D` funktioniert genauso
   - UI → `Control` funktioniert genauso

   Die Bridge ist **nicht** an einen Node-Typ gebunden. Sie ist ein
   **Autoload-Singleton** (`PythonBridge`), das außerhalb deiner Szene lebt –
   der Node darunter ist nur der *Aufrufer*.
3. Im Inspector **Attach Script** (Symbol mit Schriftrolle) → **Load**
   `res://scripts/hello_bridge.gd`.
4. **F5** (Projekt) oder **F6** (diese Szene) drücken.

Optional: Statt anzuhängen kannst du das Skript als **Autoload** eintragen
(Projekt-Einstellungen → Autoload → `hello_bridge.gd`), wenn die Verbindung
in jeder Szene bestehen soll.

---

## 4. Was beim Drücken von F5 passiert

```text
Schritt 1  _ready()
           └─ PythonBridge.start_instance("default")
                ├─ findet/erstellt die venv (res://python_bridge/venv)
                ├─ startet den Python-Server als Subprozess   <-- HIER startet Python
                ├─ verbindet per WebSocket (localhost)
                └─ Handshake  ->  READY

Schritt 2  _send_hello()
           ├─ sendet  {func: "say_hello", args: ["Hello Python"]}
           └─ wartet auf das Ergebnis
                └─ print: [GDScript] Python antwortet: Hello Godot (from Python,
                          received: Hello Python)

Schritt 3  _process(delta)  (jeden Frame, non-blocking)
           └─ einmal pro Sekunde: Echo-Roundtrip mit Dictionary-Payload
                └─ print: [GDScript] frame 120 -> Python: Hello Godot | gesendet: {...}

Schritt 4  Szene schließt / Godot beendet
           └─ PythonBridge.shutdown()  -> WebSocket geschlossen, Prozess beendet,
              keine Zombie-Prozesse
```

Erwartete Konsolen-Ausgabe:

```text
[GDScript] Python antwortet: Hello Godot (from Python, received: Hello Python)
[GDScript] frame 60 -> Python: Hello Godot | gesendet: { "frame": 60, ... }
[GDScript] frame 120 -> Python: Hello Godot | gesendet: { "frame": 120, ... }
...
```

---

## 5. Wie die Daten fließen (Senden/Empfangen in GDScript)

| Richtung | GDScript | Python |
|---|---|---|
| **Senden** | `call_script(id, fn, args, kwargs)` – `args` ist ein `Array`, `kwargs` ein `Dictionary` | `def fn(*args, **kwargs)` empfängt sie konvertiert |
| **Empfangen** | `var r := await PythonBridge.call_script(...)` → `r.value` | `return <wert>` in der Python-Funktion |
| **Ganze Datei ausführen** | `execute_script(id, input)` → `r.value` | Modul-Ebene `result = ...` aus `input` |
| **Typen** | `int/float/String/bool/Array/Dictionary/PackedByteArray` | `int/float/str/bool/list/dict/bytes` |

Faustregeln:

- Alles, was du übergibst, muss JSON-serialisierbar sein (oder
  `PackedByteArray`, das als Binärframe reist).
- Der Aufruf ist **asynchron**: nutze `await`. Deine `_process` läuft weiter;
  Python blockiert nie einen Frame.
- Fehler kommen strukturiert zurück, nie als Crash:

```gdscript
if r.is_error():
    print(r.error_code())                 # z. B. "PYTHON_EXCEPTION"
    print(r.error.get("type"))            # z. B. "ValueError"
    print(r.error.get("message"))         # die Exception-Meldung
    print(r.error.get("traceback"))       # der Python-Traceback
```

---

## 6. Fehlerbehebung beim ersten Lauf

| Symptom | Ursache / Lösung |
|---|---|
| `Start fehlgeschlagen: python not found` | Python 3.8+ installieren oder einmal explizit setzen: `PythonBridge.configure({"python_executable": "/usr/bin/python3"})` (Windows: `"C:/Python312/python.exe"`). |
| `status = "not_ready"` | Du hast aufgerufen, bevor `await start_instance(...)` fertig war. Immer erst awaiten. |
| Erster Start dauert ~1 Minute | Die venv wird erstellt + `websockets` installiert. Passiert nur einmal; Log in `res://python_bridge/tmp/pip.log`. |
| `Script not found: hello` | Die `.py`-Datei liegt nicht in `res://python_bridge/scripts/`. Name prüfen (ID = Dateiname ohne `.py`). |
| Flatpak-Godot kann Python nicht starten | Sandbox-Beschränkung; wird automatisch erkannt (`flatpak-spawn --host`). Details in der Online-Doku unter „Fehlerbehebung“. |

---

## 7. Wie es weitergeht

- **Vollständige Online-Dokumentation:**
  <https://cybertoshi.github.io/python-bridge/>
- **API-Referenz (jede Funktion):**
  <https://cybertoshi.github.io/python-bridge/docs/api>
- **Python-Seite verstehen (Kontexte, Zustand, Abbruch):**
  <https://cybertoshi.github.io/python-bridge/docs/python-seite>
- **Große Daten (DataRefs):**
  <https://cybertoshi.github.io/python-bridge/docs/datenebene>
- **Screenshots aufnehmen:** siehe `docs/Screenshot_Workflow.md`.
- **Verifikations-Checkliste (echte Engine):**
  <https://cybertoshi.github.io/python-bridge/docs/godot-verification>
- **Architektur & Grenzen:**
  <https://cybertoshi.github.io/python-bridge/docs/architecture>
