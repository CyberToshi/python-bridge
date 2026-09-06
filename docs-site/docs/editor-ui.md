---
sidebar_position: 4
title: Godot-Integration (Editor-UI)
description: Bedienung des integrierten Python-Docks direkt im Godot-Editor, Schritt für Schritt mit Screenshots.
---

# Godot-Integration: Bedienung im Editor

Die Python Bridge ist **direkt in den Godot-Editor integriert**. Du verlässt den
Editor nicht: Python-Dateien anlegen, bearbeiten, ausführen und als
GDScript-Wrapper verfügbar machen passiert im Dock **„Python Bridge“** rechts
oben.

:::note Screenshots
Die Bilder dieser Seite sind aktuell **Platzhalter** – sie werden durch echte
Aufnahmen ersetzt, sobald die Screenshots per Flameshot erstellt und unter
`docs-site/static/img/ui/` mit gleichem Dateinamen abgelegt wurden
(Anleitung: `docs/Screenshot_Workflow.md`). Die beschriebenen Schritte und
Buttons entsprechen exakt dem aktuellen Addon-Code.
:::

## 1. Plugin aktivieren

| | |
|---|---|
| ![Plugin aktivieren](/img/ui/ui-01-plugin-aktivieren.png) | ① Öffne **Projekt → Projekt-Einstellungen → Tab „Plugins“**.<br/>② In der Liste erscheint **Python Bridge**.<br/>③ Setze den Haken (**Aktivieren**). |

Beim Aktivieren passieren zwei Dinge automatisch:

- Der Autoload-Singleton **`PythonBridge`** wird registriert
  (`addons/python_bridge/core/python_bridge.gd`).
- Das Dock **„Python Bridge“** erscheint oben rechts im Editor.

## 2. Das Dock im Überblick

![Dock-Übersicht](/img/ui/ui-02-dock-uebersicht.png)

Das Dock ist bewusst schlank aufgebaut – es spricht ausschließlich mit der
`PythonBridge`-Facade, nie mit internen Kernkomponenten.

:::note Warum ein eigener Python-Editor?
Godots eingebauter **Script-Editor** kann nur GDScript (und C#) bearbeiten –
Python-Dateien kann er nicht öffnen. Der Python-Bereich des Docks ist deshalb
der Ort, um deine `.py`-Dateien **direkt in Godot** mit Highlighting zu
schreiben. Alternativ schreibst du die Dateien extern (z. B. VS Code) –
Änderungen werden per Hot Reload übernommen.
:::

:::info Editor-Komfort
Der Code-Editor ist **frei skalierbar**: Zwischen Skriptliste und Editor sowie
zwischen Editor und Log sitzen **ziehbare Trennbalken**, und das Dock selbst
lässt sich wie jedes Godot-Dock an der Kante größer ziehen. Das Highlighting
deckt Keywords, Builtins, `self`/`cls`, Funktions-/Klassennamen, Decorators,
Zahlen (auch `0x…`/`0b…`/Floats mit Exponent) sowie Strings inklusive
**mehrzeiliger Docstrings** ab.
:::

| Nr. | Element | Funktion |
|---|---|---|
| ① | **Refresh** | Skriptliste neu einlesen (`res://python_bridge/scripts/`) |
| ② | **New script** | Neues Python-Skript anlegen (Dialog) |
| ③ | Statuszeile | `status: scripts: N` / `run ok` / Fehlerstatus |
| ④ | Skriptliste | Alle `.py`-Dateien des Workspace (Klick öffnet sie) |
| ⑤ | Tabs + Code-Editor | **Mehrere Dateien gleichzeitig offen** – jeder Tab ist ein eigener Editor mit Python-Syntax-Highlighting und eigener Undo-Historie. **Zeilennummern** (null-aufgefüllt), 4-Space-Indentation, sichtbare Tabs. Ungespeicherte Änderungen zeigen ein `*` im Tab; Schließen (X) fragt bei ungespeicherten Änderungen nach. |
| ⑥ | **Save** | Editor-Inhalt zurück in die `.py`-Datei schreiben |
| ⑦ | **Run** | Skript auf Instanz `default` ausführen (Timeout 30 s) |
| ⑧ | **Generate wrapper** | GDScript-Anbindung automatisch erzeugen |
| ⑨ | **Hot reload** | Python-Instanz neu definieren (Code-Änderung) |
| ⑩ | Log | Ausgaben: grün = ok, rot = Fehler, blau = Hinweise |

Der Standard-Workspace liegt unter `res://python_bridge/`:
Skripte in `res://python_bridge/scripts/`, generierte Wrapper in
`res://python_bridge/wrappers/`.

## 3. Ein Python-Skript anlegen

![Dialog New script](/img/ui/ui-03-neues-script.png)

1. Klick auf **New script** ①.
2. Skript-ID eingeben – z. B. `hello`, **ohne** `.py` ②.
3. Bestätigen ③ → die Datei `res://python_bridge/scripts/hello.py` wird mit
   einem Kommentar-Kopf angelegt.

![Editor mit Code](/img/ui/ui-04-hello-py-editor.png)

4. Das Skript erscheint in der Liste; ein Klick darauf ① öffnet es in einem
   **neuen Tab** (mehrere Skripte können gleichzeitig offen sein).
5. Schreibe normalen Python-Code – z. B.:

```python
def say_hello(message):
    print("Python received:", message)
    return "Hello Godot! " + message
```

6. **Save** schreibt die Datei zurück ② ③. Wichtig: Es bleibt eine **echte,
   normale `.py`-Datei** – außerhalb von Godot mit jedem Python lauffähig.

## 4. Skript ausführen (im Dock)

![Run mit Log](/img/ui/ui-05-run-log.png)

1. Klick auf **Run** ①. Das Dock ruft `execute_script("hello", {}, "default", 30.0)` auf.
2. Das Log zeigt den Ablauf ②:
   - `run hello`
   - `ok: Hello Godot! Python received: …` (grün)
3. Die Statuszeile wechselt auf `run ok` ③.

Fehler werden nicht verschluckt: Bei einer Python-Exception erscheinen Status,
Fehlermeldung und – falls vorhanden – der Traceback rot im Log.

## 5. Live im Spiel testen (F6/F5)

![Live-Ausgabe](/img/ui/ui-06-live-ausgabe.png)

Der Dock-„Run“ führt das Skript einmalig aus. Für **Live-Nutzung im
Spielbetrieb** hängst du ein GDScript an einen Node, das die Facade aufruft –
z. B. das lauffähige Beispiel `example/hello/hello_world.tscn`:

```gdscript
extends Node

func _ready() -> void:
    var started := await PythonBridge.start_instance("default")
    if not started:
        return
    var res := await PythonBridge.call_script("hello", "say_hello", ["Hello Python"])
    if res and res.is_ok():
        print("[Godot] Python antwortet:", res.value)
```

- **F6** auf der Szene (bzw. **F5** fürs Projekt) startet den Test.
- Das Output-Panel unten zeigt die Antwort aus Python ①.
- Auch wiederholte Aufrufe pro Frame (`execute()` in `_process`) laufen, ohne
  den Main-Thread zu blockieren ②.

## 6. GDScript-Wrapper automatisch erzeugen

![Wrapper generiert](/img/ui/ui-07-wrapper-generiert.png)

1. Klick auf **Generate wrapper** ①.
2. Das Addon liest die Python-Funktionen per `introspect_script` und schreibt
   eine GDScript-Anbindung nach
   `res://python_bridge/wrappers/<skript>_wrapper.gd` ②.
3. Die Datei erscheint im Dateisystem-Dock ③ und ist über den Dateinamen
   eindeutig als **generiert** erkennbar.

Sicherheitsregel: Eine **manuell geschriebene** Datei an gleicher Stelle wird
niemals überschrieben – das Addon bricht mit einer Fehlermeldung im Log ab.

## 7. Optional: Dock „HP GDScript“

![HP-Dock](/img/ui/ui-08-hp-dock.png)

Neben dem Python-Dock registriert das Plugin einen zweiten Dock:
**HP GDScript** ①. Er ist ein **reines Compute-Werkzeug** (GDScript → C++-
Skizze über den gebündelten GDScript2All-Konverter) und **kein
Kommunikationsweg** der Bridge ②. Für die normale Arbeit mit Python ist er
nicht nötig; sein End-to-End-Build ist noch nicht verifiziert ③.

## Zusammenfassung des Workflows

```text
Plugin aktivieren            (Projekt-Einstellungen → Plugins)
   ↓
Dock „Python Bridge“ öffnen  (rechts oben)
   ↓
New script → Python schreiben → Save        (echte .py-Datei)
   ↓
Run im Dock  oder  call_script aus GDScript (Live-Szene, F6)
   ↓
Generate wrapper → *.gd in wrappers/        (optional)
```

Mehr Kontext zur Architektur und zu den Grenzen findest du unter
[Architektur](/docs/architecture).
