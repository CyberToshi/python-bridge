---
sidebar_position: 13
title: Editor & HP-Werkzeuge
description: Referenz zum Python-Dock im Editor, dem Syntax-Highlighter und dem optionalen HP-GDScript-Werkzeug.
---

# Editor & HP-Werkzeuge

Diese Klassen laufen nur im **Editor** und sind nicht Teil der Laufzeit-API.
Die Bedienung des Docks steht in [Godot-Integration (Editor-UI)](./editor-ui).

## PythonBridgeEditorPanel

`editor/python_editor.gd` – das **Python-Dock**. Es ist bewusst
leichtgewichtig und spricht ausschließlich mit der `PythonBridge`-Facade,
nie mit Kern-Interna.

### Merkmale

- Skriptliste (`<workspace>/scripts/**`), automatisch aktualisierbar
- **Mehrdatei-Tab-Editor:** jeder Tab ein eigener `CodeEdit` mit eigener
  Undo-Historie und Python-Highlighting
- Dirty-Marker (`*`) an geänderten Tabs; Schließen fragt nach
- **Save / Run / Generate wrapper / Hot reload** wirken auf den **aktiven Tab**
- Statuszeile + Log-Ausgabe
- Hot-Reload-Watcher: ändert sich die aktive Datei auf der Platte
  (externer Editor) und ist nicht dirty, wird der Tab-Inhalt aktualisiert und
  `hot_reload_script()` gemäß Konfiguration ausgelöst

### Öffentliche Methoden

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `_init(bridge: Object = null)` | – | Baut die UI auf; `bridge` ist optional und wird lazy aufgelöst |
| `refresh_scripts()` | `void` | Liest die Skriptliste neu ein und aktualisiert den Status |
| `open_script(script_id)` | `String` | Öffnet ein Skript in einem Tab (reuse oder neu); `""` = nicht lesbar |
| `editor_poll()` | `void` | Pro Editor-Frame: Hot-Reload-Watcher + Status |

Konstante `HOT_RELOAD_POLL_MS` (`1000`) bestimmt das Prüfintervall des
Datei-Watchers.

## PythonBridgeSyntaxHighlighter

`editor/python_syntax_highlighter.gd` – `SyntaxHighlighter` für `CodeEdit`.
Hebt Keywords, Builtins, `self`/`cls`, Funktions-/Klassennamen, Decorators,
Zahlen (inkl. `0x…`/`0b…` und Exponent) sowie Strings inklusive
mehrzeiliger Docstrings hervor. Wird pro Tab-Editor instanziiert; keine
öffentliche API – reines Editor-Werkzeug.

## HP GDScript (optionales Compute-Werkzeug)

Der **HP-Pfad** ist ein reines **Compute-Werkzeug** (GDScript → C++ →
GDExtension) und **kein Kommunikationsweg** der Bridge. Er ist für die
normale Arbeit mit Python nicht nötig; sein End-to-End-Build ist nicht
verifiziert. Details und Einordnung: [Kommunikationspfade](./hochleistungspfade).

### PythonBridgeHPCfg

`core/hp_gdscript/hp_config.gd` – Konfiguration des HP-Pfads.

| Feld | Default | Bedeutung |
|---|---|---|
| `python_exe` | `"python3"` | Python zum Ausführen des GDScript2All-Konverters |
| `converter_main_py` | gebündelter Pfad | `main.py` des Konverters (relativ zum Projekt) |
| `workspace_dir` | `res://hp_gdscript` | Ziel für generierten C++-Code und Scaffolding |
| `extension_name` | `"hp_gdscript"` | Name der GDExtension-Bibliothek |
| `auto_build` | `true` | Nach der Generierung automatisch bauen |
| `build_timeout_sec` | `300` | Timeout für den Build |
| `godot_version` | `"4.3.1"` | godot-cpp-Zielversion |
| `godot_cpp_dir` | `""` | godot-cpp-Quellordner (leer = manuell bereitstellen) |
| `verbose_converter` | `true` | Ausführliche Konverter-Ausgabe im Panel |

### PythonBridgeHPCore

`core/hp_gdscript/hp_gdscript_core.gd` – orchestriert den HP-Pfad, enthält
aber **keinen eigenen Transpiler**: Es ruft den gebündelten
GDScript2All-Konverter auf und ergänzt das fehlende GDExtension-Scaffolding.

| Methode | Rückgabe | Bedeutung |
|---|---|---|
| `_init(cfg: PythonBridgeHPCfg = null)` | – | Ohne `cfg` werden die Defaults benutzt |
| `convert_and_scaffold(scripts: PackedStringArray)` | `Error` | Konvertiert GDScript → C++, erstellt das GDExtension-Gerüst und baut optional |
| `build()` | `Error` | Baut die GDExtension im Workspace (falls gerüstet) |
| `reveal_workspace()` | `void` | Öffnet den Workspace im Dateimanager |
| `last_error()` | `String` | Letzte Fehlermeldung |
| `last_log()` | `PackedStringArray` | Gesammelte Logzeilen |

### PythonBridgeHPPanel / PythonBridgeHPEditorPlugin

`editor/hp_gdscript/hp_panel.gd` und `editor/hp_gdscript/plugin_hp.gd` – das
Dock **„HP GDScript“** und sein Editor-Plugin. Sie werden vom Haupt-Plugin
optional geladen (siehe `plugin.gd`) und treiben `PythonBridgeHPCore` über
eine einfache UI. Keine stabile öffentliche API – als Werkzeug gedacht.

---

Verwandt: [Godot-Integration (Editor-UI)](./editor-ui) ·
[API-Überblick & Facade](./api) · [Kommunikationspfade](./hochleistungspfade)
