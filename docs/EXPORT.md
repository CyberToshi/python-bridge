# Export und Plattformen

Die Bridge unterstützt drei Ziele:

| Plattform | Transport | Vorbereitung |
|---|---|---|
| Windows | Python-Prozess + lokaler WebSocket | automatische venv/Runtime |
| Linux | Python-Prozess + lokaler WebSocket | automatische venv/Runtime |
| Web | Pyodide (WASM) im Web Worker | Workspace-Bundle bauen |

## Prüfung ausführen

Im Repository-Root:

```bash
python3 tools/export_check.py --project . --platform all
python3 tools/export_check.py --project . --platform windows
python3 tools/export_check.py --project . --platform linux
python3 tools/export_check.py --project . --platform web
```

Für CI ist JSON verfügbar:

```bash
python3 tools/export_check.py --project . --platform all --json
```

`--fix` erstellt fehlende, sichere Quell-Workspace-Ordner
(`python_bridge/scripts`, `tmp`, `config` und `venv/.gdignore`) und baut bei
`--platform web` auf Wunsch das Web-Bundle. Es installiert keine Pakete,
ändert keine Export-Presets und startet keine Prozesse.

## Windows und Linux

Der Checker erwartet:

- `project.godot`, das Addon und den Python-Server vollständig,
- einen gültigen Python-Interpreter auf dem Build-/Zielsystem (Version wird
  geprüft),
- ein vorhandenes Godot-Export-Preset,
- einen beschreibbaren Workspace, vorzugsweise unter `user://python_bridge`,
- die Bridge-Python-Dateien außerhalb des schreibgeschützten PCK bzw. an einem
  Pfad, den die exportierte Anwendung lesen kann,
- auf Linux: Ausführungsrechte des Python-Interpreters.

Die automatische venv-Einrichtung bleibt erhalten (Windows: inklusive
`python_embedded`-Erkennung und DLL-/Pfad-Prüfung). Für reproduzierbare
Produktions-Exporte ist eine vorbereitete Runtime oft zuverlässiger als eine
Paketinstallation beim ersten Start. Fehler werden als strukturierte
`DEPENDENCY_ERROR`, `PROCESS_ERROR` oder `CONNECTION_ERROR` gemeldet.

## Web (Pyodide, ohne externen Server)

Auf Web-Exports läuft Python über **Pyodide im Web Worker** — direkt im
Browser, auf normalem Static Hosting. Ein externer Python-Dienst ist **nicht**
mehr erforderlich (kann aber optional weiterhin genutzt werden).

Vorbereitung vor dem Export:

```bash
python3 tools/build_web_bundle.py --project . --out build/web_bridge \
  --packages numpy,scipy,pandas
python3 tools/export_check.py --project . --platform web
```

Der Checker prüft: gebautes Bundle (`bridge_worker.js`,
`bridge_workspace.tar`, `bridge-lock.json`), Paket-Manifest, Worker-URL und —
wenn konfiguriert — lokale Pyodide-Runtime bzw. CDN-Erreichbarkeit. Das Bundle
wird **neben** den Godot-Web-Export gelegt; der Worker lädt es per
`web_worker_url`/`web_bundle_url` (Defaults reichen in der Regel).

NumPy/SciPy/Pandas werden über das Pyodide-Paket-Repository geladen (lokale
Kopie oder CDN) und sind funktional getestet. Details zur Architektur, zum
virtuellen Dateisystem und zu Browser-Grenzen:
[WEB_RUNTIME.md](WEB_RUNTIME.md).

### Optionaler externer Dienst

Der Desktop-Server kann alternativ als externer WebSocket-Dienst betrieben
werden (`--websocket-url wss://host/bridge`). Er muss dann:

1. Python mit der Bridge-Serverlogik ausführen,
2. über `ws://`/`wss://` erreichbar sein,
3. das gleiche Protokoll und die gleiche Serialisierung sprechen,
4. Authentifizierung, CORS-/Origin-Regeln und Lebenszyklus selbst verwalten.

## Interpretation

- **OK**: die konkrete Voraussetzung wurde gefunden.
- **WARN**: der Export kann möglich sein, braucht aber eine manuelle Godot-
  oder Deployment-Konfiguration.
- **ERROR**: der angegebene Zielweg ist mit der aktuellen Konfiguration nicht
  lauffähig.
- **INFO**: Plattformgrenze oder Deployment-Hinweis.
