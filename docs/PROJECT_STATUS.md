# Python Bridge — aktueller Projektstand

**Version:** 0.5.0 (maßgeblich ist `addons/python_bridge/plugin.cfg`) ·
**verifiziert mit:** Godot 4.6- und 4.7-stable, Python 3.13

Die Bridge verbindet Godot 4 mit einer oder mehreren lokalen Python-Instanzen.
Eine Instanz besteht aus einem Python-Prozess und einem WebSocket-Kanal. Die
Godot-Fassade verwaltet Lebenszyklus, Tasks, Fehler, Datenhandles und Editor-
Integration; Python bleibt normaler Python-Code.

## Erhaltene Kernfunktionen

- Python-Dateien aus dem Editor erstellen, bearbeiten, speichern, ausführen und
  rückstandsfrei löschen (Quelle, Bytecode, Cython-Artefakte, Wrapper)
- zwei Skript-Typen: temporär (`execute`, nur im Speicher) und persistent
  (`create_script`/`call_script`, echte Dateien)
- `run`, `call` und `define` mit Parametern, Rückgabewerten und Tracebacks
- Prozessverwaltung mit venv-Provisionierung, Health-Checks, Restart und Shutdown
- asynchrone WebSocket-Kommunikation und frame-synchrones Polling
- Prioritäten, Backpressure, Batching, Timeout, Retry und Cancellation
- IPC-/DataRef-Metadaten sowie binärer und dateibasierter Datentransport
- Introspection, Hot Reload, Wrapper-Generator und Python-Editor-Dock
- strukturierte Fehlerkategorien statt unbrauchbarer Sammelmeldungen

## Architektur

```text
Godot Autoload PythonBridge
  → TaskManager / Scheduler / Frame-Budgets
  → BridgeInstance (Prozess + WebSocket + Health)
  → Python asyncio server
  → Executor / Context / lokale Thread-Slots
  → strukturierte Antwort oder DataRef
```

Die normale Bridge- und IPC-Funktionalität ist lokal. Für Browser-Exports
läuft Python über Pyodide (WebAssembly) im Web Worker mit virtuellem
Dateisystem — ohne externen Dienst. Ein externer Python-Dienst per WebSocket
bleibt optional verfügbar.

## Export-Prüfung

`tools/export_check.py` prüft für Windows, Linux und Web die benötigten Dateien,
Python-Runtime, Workspace, Export-Presets und Plattformgrenzen. `--json` ist
für CI geeignet; `--fix` erstellt nur sichere Workspace-Ordner und niemals
Pakete oder Prozesse. Siehe [EXPORT.md](EXPORT.md).

## Tests

```bash
python3 -m unittest discover -s tests/python -p "test_*.py"
godot --headless --path . --script res://tests/gdscript/run_tests.gd
```

Die IPC-Tests prüfen Ownership, Zustandsübergänge, Shared-Memory-Backend und
den Metadaten-Kontrollkanal. Der Python-Server führt Nutzercode in lokalen
Threads aus; diese Threads sind kein separater Netzwerkdienst und bleiben Teil
der Prozessisolation.
