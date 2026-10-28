---
sidebar_position: 4
title: Godot-Integration (Editor-UI)
description: Bedienung des integrierten Python-Docks direkt im Godot-Editor, Schritt für Schritt mit Screenshots.
---

# Godot-Integration: Bedienung im Editor

:::caution Stand 0.5.0 — Screenshots sind Platzhalter
Das Dock wurde in **0.4.0** neu gebaut (Tab-Container mit stabilen Tabs,
schmale Symbol-Toolbar, temporäre Scratch-Tabs, Löschen/Umbenennen) und in
**0.5.0** um den Einstellungsdialog erweitert; außerdem meldet das Dock jeden
Speichervorgang an die Bridge, damit im Web-Export auch Skripte ankommen, die
**nach** dem Python-Start entstehen. Die Bilder auf dieser Seite ersetzen
noch Platzhalter — die beschriebenen Beschriftungen und Wege sind aber der
Code-Stand von 0.5.0. Verbindlich bleibt
[docs/ERSTE_SCHRITTE.md](https://github.com/CyberToshi/python-bridge/blob/main/docs/ERSTE_SCHRITTE.md) §6.
:::

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

Die Toolbar ist bewusst schmal: drei Aktionen plus zwei Statuslabels und das
`⋯`-Menü. Alles Seltene liegt im Menü, nicht als Button.

| Element | Beschriftung / Kürzel | Funktion |
|---|---|---|
| **Neu** | `＋`, **Strg+N** | Menü mit **„Neue Datei …“** (Dialog, ID ohne `.py`) und **„Temporäres Skript“** (Scratch-Tab, landet nie auf der Platte). |
| **Speichern** | **Strg+S** | Schreibt den aktiven Tab in die Datei und meldet die Änderung an die Bridge. Im Web-Export ist das der Weg, auf dem ein neu angelegtes Skript überhaupt im Pyodide-Workspace ankommt. |
| **Ausführen** | **Strg+Enter** | `execute_script(id, {}, "default", 30.0)` — bewusst nicht F5/F6, die gehören im Editor dem Projekt. |
| Statuszeile | `bereit` / `run ok` / Fehler | Ergebnis des letzten Laufs, links neben dem Instanzlabel. |
| **Python: …** | `Python: ready` | Zustand der Instanz `default` (`none`, `provisioning`, `ready`, `crashed`, …). |
| **`⋯`** | **Weitere Aktionen** | GDScript-Wrapper generieren · Hot Reload · **Als Cython-Modul speichern (.pyx)** (Haken) · Cython kompilieren · Umbenennen … · Löschen … · Log leeren · **Einstellungen …** |
| Filterfeld | `Filtern …` | Blendet die Skriptliste live auf passende IDs ein. |
| Skriptliste | links | Alle `.py`/`.pyx`-Dateien unter `<workspace>/scripts`; Klick öffnet im Tab, Rechtsklick bietet Öffnen / Umbenennen / Löschen. |
| Tabs + Code-Editor | Mitte | **Mehrere Dateien gleichzeitig offen** – jeder Tab mit eigener Undo-Historie, **Zeilennummern**, 4-Space-Indentation, sichtbaren Tabs und Python-Highlighting inklusive mehrzeiliger Docstrings. `*` im Tab = ungespeichert; Schließen fragt nach. |
| Log | unten | grün = ok, rot = Fehler (mit Traceback), blau = Hinweise. |

Der Standard-Workspace liegt unter `res://python_bridge/`:
Skripte in `res://python_bridge/scripts/`, generierte Wrapper in
`res://python_bridge/wrappers/`.

## 3. Ein Python-Skript anlegen

![Dialog New script](/img/ui/ui-03-neues-script.png)

1. **Neu → Neue Datei …** (`＋` in der Toolbar, **Strg+N**).
2. Skript-ID eingeben – z. B. `hello`, **ohne** `.py`. Die ID wird geprüft
   (`validate_script_id`); leerer Rückgabewert = verwendbar.
3. Bestätigen → die Datei `res://python_bridge/scripts/hello.py` wird mit
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

6. **Speichern** (**Strg+S**) schreibt die Datei zurück. Wichtig: Es bleibt
   eine **echte, normale `.py`-Datei** – außerhalb von Godot mit jedem Python
   lauffähig. Das Dock ruft dabei `notify_script_saved()` auf; im Web landet
   der Inhalt so im Pyodide-Workspace, auf dem Desktop wird der Quelltext-Cache
   verworfen (nächster Aufruf kompiliert neu).

## 4. Skript ausführen (im Dock)

![Run mit Log](/img/ui/ui-05-run-log.png)

1. **Ausführen** (**Strg+Enter**). Das Dock ruft `execute_script("hello", {}, "default", 30.0)` auf.
2. Das Log zeigt den Ablauf:
   - `run hello`
   - `ok: Hello Godot! Python received: …` (grün)
3. Die Statuszeile wechselt auf `run ok`.

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

1. **`⋯` → GDScript-Wrapper generieren**.
2. Das Addon liest die Python-Funktionen per `introspect_script` und schreibt
   eine GDScript-Anbindung nach
   `res://python_bridge/wrappers/<skript>_wrapper.gd`.
3. Die Datei erscheint im Dateisystem-Dock und ist über den Dateinamen
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

## Einstellungen ohne Umweg

Alle Optionen liegen an zwei sichtbaren Orten — Code ist dafür nie nötig:

- **Projekt → Projekteinstellungen → Python Bridge** (`autostart`,
  `workspace_dir`, `python_executable`, `dependencies`, `hot_reload_mode`,
  `auto_generate_wrappers`, Web-Pakete).
- **Dock → `⋯` → Einstellungen …** mit denselben Feldern und dem Knopf
  **„Speichern & neu starten“**, damit Änderungen sofort greifen.

Zusätzlich liegt unter **Projekt → Werkzeuge** ein `Python Bridge`-Menü
(Dock anzeigen, Neue Datei, Einstellungen, Instanz starten/stoppen,
Cython kompilieren) — die Funktionen sind also nicht im Dock versteckt.

Wer keine UI will: `res://python_bridge/config.json` (Praezedenz
Defaults → Projekt-Einstellungen → `config.json` → `configure()`).

## Zusammenfassung des Workflows

```text
Plugin aktivieren            (Projekt-Einstellungen → Plugins)
   ↓
Dock „Python Bridge“ öffnen  (rechts oben)
   ↓
Neu → Neue Datei → Python schreiben → Speichern (echte .py-Datei)
   ↓
Run im Dock  oder  call_script aus GDScript (Live-Szene, F6)
   ↓
Generate wrapper → *.gd in wrappers/        (optional)
```

Mehr Kontext zur Architektur und zu den Grenzen findest du unter
[Architektur](/docs/architecture).
