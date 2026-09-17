---
sidebar_position: 4
title: Export-Prüfung
description: Plattformgerechte Prüfung der Python Bridge für Windows, Linux und Web.
---

# Export-Prüfung

```bash
python3 tools/export_check.py --project . --platform all
python3 tools/export_check.py --project . --platform web \
  --websocket-url wss://python.example/bridge
```

Das Tool prüft Bridge-Dateien, Autoload, Workspace, Python-Runtime und
Export-Presets. Mit `--json` ist es für CI geeignet. `--fix` legt nur fehlende
Workspace-Ordner und `.gdignore` an; es installiert nichts und verändert keine
Export-Einstellungen automatisch.

## Desktop

Windows und Linux können den Python-Prozess lokal starten. Die exportierte
Anwendung braucht dafür eine erreichbare Python-Runtime, die Bridge-Dateien
außerhalb des schreibgeschützten PCK und einen beschreibbaren Workspace. Für
Produktions-Deployments sollte die Umgebung vorbereitet werden, statt beim
ersten Start Pakete aus dem Internet zu installieren.

## Web

Python läuft im Browser über **Pyodide (WebAssembly) im Web Worker** — ohne
externen Dienst. Vor dem Export einmal das Bundle bauen:

```bash
python3 tools/build_web_bundle.py --project . --out build/web_bridge
python3 tools/export_check.py --project . --platform web
```

Der Checker prüft Worker, Workspace-Tar, Lockfile und Paket-Manifest.
NumPy/SciPy/Pandas kommen aus dem Pyodide-Paket-Repository (lokal oder CDN)
und sind funktional getestet. Ein externer Python-Dienst (`--websocket-url`)
bleibt optional verfügbar.
