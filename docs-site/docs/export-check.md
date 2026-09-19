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

## Export in einem Befehl

Die drei Export-Scripts im Addon verketten alles: Vorraussetzungen prüfen →
Export-Check → (nur Web:) Bundle bauen → Godot headless exportieren. Sie
finden Godot selbst (natives Binary **oder** Flatpak) und brechen mit einer
verständlichen Meldung ab, wenn etwas fehlt:

```bash
# Web (mit lokalem Testserver danach):
./addons/python_bridge/tools/export_web.sh --serve

# Linux-Desktop:
./addons/python_bridge/tools/export_linux.sh

# Windows (Cross-Compile von Linux oder nativ auf Windows):
./addons/python_bridge/tools/export_windows.sh
```

| Script | Output | Optionen |
|---|---|---|
| `export_web.sh` | `build/web/` | `--serve` (Testserver auf `http://localhost:8000`), `--debug` (Konsole/Fehler im Browser sichtbar) |
| `export_linux.sh` | `build/linux/` | `PRESET_NAME`, `BIN_NAME` per Umgebungsvariable |
| `export_windows.sh` | `build/windows/` | `PRESET_NAME`, `BIN_NAME` per Umgebungsvariable |

:::tip Web lokal testen
`export_web.sh --serve` startet nach dem Export automatisch einen
HTTP-Server. Die F12-Konsole im Browser zeigt den Fortschritt:
Pyodide-Load → Workspace-Entpacken → `bridge host ready`. Erst wenn diese
Meldung kommt, akzeptiert die Bridge Tasks.
:::

Hinweise zu den Plattformen:

- **Web**: Der Build braucht das Web-Export-Template und ein Preset namens
  `Web`. Für GitHub Pages ohne 'Thread Support' exportieren (die Scripts
  nutzen Release-Export, das passt). `--debug` ist zum Entwickeln praktisch:
  Godot-Fehler landen sichtbar in der Browser-Konsole.
- **Linux**: Die Binary liegt unter `build/linux/`; der erste Start
  provisioniert die venv (Log zeigt `[PROV]`).
- **Windows**: Von Linux aus Cross-Compile direkt möglich; Wine wird nur für
  Icon-/Version-Infos in der `.exe` gebraucht (fehlendes Wine wird
  hingewiesen, nicht blockiert). Auf echter Windows-Hardware läuft das
  gleiche Script mit der dortigen Godot-Installation. Erster Start dauert
  2–5 Minuten (venv + Pakete, Windows Defender scannt jede neue `.exe`).

:::note Entwicklung vs. Export
In der **Entwicklung** musst du nichts von alledem — F5 im Editor startet
die Bridge mit Auto-Provisioning. Die Scripts sind ausschließlich für den
Export/Deployment-Weg, und der Web-Export ist der einzige, der einen
zusätzlichen Build-Schritt (Bundle) braucht.
:::
