# Python Bridge für Godot 4

## Installation

1. Diesen Ordner als `res://addons/python_bridge/` in dein Godot-Projekt kopieren.
2. In Godot unter **Projekt → Projekteinstellungen → Plugins** das Plugin
   **Python Bridge** aktivieren.
3. Python 3.8 oder neuer muss auf Windows/Linux verfügbar sein. Die Bridge
   legt beim ersten Start die projektbezogene venv an und installiert
   `websockets`.

Beispiel:

```gdscript
func _ready() -> void:
    var started := await PythonBridge.start_instance("default")
    if started.is_error():
        push_error(started.error_message())
        return
    PythonBridge.create_script("hello", "def greet(name):\n    return f'Hello {name}'\n")
    var result := await PythonBridge.call_script("hello", "greet", ["Godot"])
    print(result.value)
```

## Cython (Desktop, optional)

Rechenlastige Funktionen dürfen als `.pyx` (Cython) geschrieben werden: Im
Python-Editor-Dock den Toggle **„Als Cython-Modul kompilieren“** aktivieren
und ganz normal `call_script` verwenden — kompilieren (inkrementell,
nur veränderte Module), Import und Aufruf passieren automatisch. Als
Compiler wird der System-Compiler genutzt; fehlt er, installiert sich die
Bridge den Compiler selbst in die venv (pip-Paket `ziglang`) — es ist also
**kein Compiler-Setup auf dem Zielrechner nötig**. Web/Pyodide: `.pyx` ist
dort nicht verfügbar (kein C-Compiler im Browser); Details im Kapitel
„Cython-Module (Desktop)“ der Doku-Website.

## Plattformstatus

- **Windows/Linux:** lokaler Python-Prozess, venv, WebSocket und vollständige
  Bridge-Funktionen.
- **Web:** Pyodide (WebAssembly) im Web Worker mit virtuellem Dateisystem —
  implementiert und funktional getestet, ohne externen Python-Dienst. Vor dem
  Export einmal `tools/build_web_bundle.py` ausführen; siehe `WEB_RUNTIME.md`.

Die öffentliche Bridge-API und die Task-/Serializer-Schicht sind auf beiden
Wegen identisch.
