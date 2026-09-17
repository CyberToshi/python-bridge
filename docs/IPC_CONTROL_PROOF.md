# IPC Control Proof

Dieses Dokument beschreibt den lokalen IPC-/DataRef-Kontrollpfad der Python
Bridge. Kleine Metadaten laufen über WebSocket; große Daten bleiben im lokalen
Datenpfad.

## Vorhandene Komponenten

- `addons/python_bridge/python/python_bridge/ipc_region.py`: IDs, Layouts,
  Ownership und Zustandsübergänge
- `addons/python_bridge/python/python_bridge/ipc_platform.py`: verfügbares
  lokales Shared-Memory-Backend
- `tests/python/test_ipc_region.py` und `test_ipc_end_to_end.py`: Koordination,
  Lesen/Schreiben, Release und Cleanup
- `tests/gdscript/test_ipc_api.gd`: Metadaten-Control-Nachrichten über die
  bestehende Bridge

## Was bewiesen ist

- Ownership bleibt explizit und nur der Owner darf freigeben.
- Zustände sind `created → filling → ready → in_use → finished`.
- Nur kompakte Deskriptoren werden als Control-Nachrichten übertragen.
- Lokale Shared-Memory-Handles werden geschlossen und bereinigt.
- Große Daten können über DataRef-/Datei-Transport materialisiert werden,
  ohne große JSON-Nachrichten im WebSocket.

## Grenzen

Der aktuelle Shared-Memory-Pfad ist lokal und benötigt einen nativen Godot-
Shim für direkten Zugriff aus GDScript. Ohne diesen Shim bleibt DataRef mit
Datei-Transport der portable Fallback. Im Web ist Shared Memory nicht
verfügbar; dort laufen große Werte über Binary-Frames/DataRefs durch den
Pyodide-Worker (funktional getestet), ein externer Dienst bleibt optional.
