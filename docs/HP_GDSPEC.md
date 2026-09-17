# GDScript2All — optionales Compute-Werkzeug (kein Kommunikationsweg)

**Status:** Werkzeug-Spezifikation — GDScript2All ist **kein** Kommunikations- oder
Transportpfad der Bridge. Die Bridge hat genau zwei Kommunikationswege (siehe
`docs/PROJECT_STATUS.md`):

```text
Pfad 1  GDScript ──WebSocket──> Python          # implementiert & verifiziert
Pfad 2  GDScript ─[kleiner C++-Shim]─ Shared Memory ─> Python   # geplant, lokal, große Daten
```

GDScript2All ist ein **optionales CPU-Werkzeug für die Godot-Seite**: Es kann
ausgewählte GDScript-Bereiche nach C++ übersetzen, damit reine Godot-seitige
Berechnung schneller läuft. Es beschleunigt **Rechnen, nie Transport**. Wer
hofft, über „GDScript → C++ → WebSocket" die Python-Kommunikation zu
beschleunigen, sitzt einem Irrtum auf: Der WebSocket-/JSON-Engpass bleibt
identisch, zusätzlich entsteht Variant-Marshalling an der GDScript↔GDExtension-
Grenze. Deshalb ist dieses Dokument bewusst von jedem Transport-Thema entkoppelt.

---

## 1. Was GDScript2All ist (vorhandene Komponente)

Vorhanden unter `GdScript2All-8e0f207aa042d2642e7e003cef03add7f377b22e/`.
Eigener rekursiver Parser + Lexer (`libs/sly`) und Transpiler für mehrere
Zielsprachen. Für uns relevant:

- `converter/main.py` — CLI (Eingabe, Ausgabe, `-t Cpp`)
- `converter/src/Cpp.py`, `Parser.py`, `Tokenizer.py`, `godot_types.py`,
  `ClassData.py`, `UserTypesResolver.py` — C++-Transpiler
- UI: `script_converter_UI.gd` + `.tscn`

**Abgelehnt:** C#-Transpiler (`CSharp.py`), andere Zielsprachen, eigene
nachbauende Transpiler-Lösung.

## 2. Bekannte Grenze des Transpilers (beobachtet)

Der Parser ist **unvollständig für beliebiges GDScript**: u.a. `for`-Loops,
komplexe Ausdrücke und `print(...)` können PANIC-/Ast-Fehler erzeugen.
Das ist für ein optionales Werkzeug akzeptabel: Konvertierungsfehler sind ein
abfangbarer, meldbarer Zustand; im Fail-Fall bleibt der Entwickler bei
GDScript. Es gibt keine Garantie für fehlerfreie Konvertierung beliebigen
Codes.

## 3. Wo es im Addon lebt

Der HP-Dock ist als separates Mini-Plugin gebündelt und wird vom Haupt-Plugin
geladen (`addons/python_bridge/plugin.gd` → `editor/hp_gdscript/plugin_hp.gd`):

```text
addons/python_bridge/
  editor/hp_gdscript/    hp_panel.gd, plugin_hp.gd, plugin.cfg
  core/hp_gdscript/      hp_config.gd, hp_gdscript_core.gd
```

`plugin.cfg` (python_bridge_hp): „Optional GDScript → C++ → GDExtension using
the bundled GDScript2All converter."

**Ehrlicher Verifikationsstand:**
- Die HP-Dateien **kompilieren** in Godot 4.7.2 (0 Fehler) und der Dock ist im
  Editor registriert.
- Ein **End-to-End-Build ist nicht verifiziert**: Transpilen → C++-Scaffold →
  kompilieren mit `godot-cpp` (scons/cmake) → Extension in Godot laden. Das
  benötigt eine zur Godot-Version passende `godot-cpp`-Version sowie einen
  C++-Toolchain-Build und wurde bisher nicht durchlaufen.

## 4. Nutzerworkflow (Zielbild, optional)

1. Entwickler markiert einen GDScript-Teil als „für C++-Übersetzung".
2. Addon erzeugt `.hpp/.cpp` + GDExtension-Scaffold.
3. Addon triggert den Build; die Extension wird in Godot verfügbar.
4. Bei Konvertierungs- oder Build-Fehlern bleibt GDScript die Fallback-Logik.

Generierte Dateien müssen für erfahrene Nutzer manuell nachbearbeitbar bleiben.

## 5. Bewusst nicht Teil dieses Schrittes

- Vollständige C++-Generierung für beliebiges GDScript.
- Rückportierung von C++-Änderungen nach GDScript.
- C# oder andere Zielsprachen.
- Jede Nutzung als Transport-/Kommunikationspfad (siehe oben).
