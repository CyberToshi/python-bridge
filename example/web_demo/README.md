# Web-Demo — dieselbe Bridge auf Desktop und im Browser

Dieses Projekt zeigt den kompletten Web-Workflow: **dieselbe Szene und
derselbe Python-Code** laufen auf Windows/Linux (nativer Python-Prozess) und
im Browser (Pyodide/WebAssembly) — ohne eine einzige Plattform-Verzweigung
im Nutzer-Code.

## Struktur

```
web_demo/
├── project.godot              Desktop + Web konfiguriert
├── web_demo.tscn / .gd        Demo-Szene (startet Instanz, ruft Python auf)
└── python_bridge/             Workspace (wird automatisch provisioniert)
    ├── scripts/demo.py        über create_script/call_script erreichbar
    ├── modules/calculations.py  über `import modules.calculations`
    ├── plugins/example_plugin.py
    └── packages/requirements.txt  (pure-Python-Pakete, leer = keine)
```

## Ablauf Desktop (Test, dass alles funktioniert)

1. Projekt in Godot 4 öffnen (Addon ist bereits aktiviert).
2. Erster Start: venv wird automatisch provisioniert (1–3 Minuten).
3. Szene starten → Ausgabe:
   - `1) Hello Godot from Python!`
   - `2) summarize: {count: 5, sum: 15, mean: 3}`
   - `3) plugin: {name: example_plugin, version: 1.0}`

## Ablauf Web (Pyodide)

### 1. Web-Bundle bauen (einmalig vor jedem Export)

```bash
# aus dem Repository-Root (oder wo tools/ liegt):
python3 tools/build_web_bundle.py --project example/web_demo \
  --out example/web_demo/build/web_bridge \
  --packages numpy   # optional; scipy,pandas likewise
```

Ergebnis in `example/web_demo/build/web_bridge/`:
`bridge_worker.js`, `bridge_workspace.tar`, `bridge-lock.json` (+ optional
`pyodide/` bei `--local-pyodide`).

### 2. Export-Check

```bash
python3 tools/export_check.py --project example/web_demo --platform web
# oder mit automatischem Bundle-Build:
python3 tools/export_check.py --project example/web_demo --platform web --fix
```

### 3. Godot-Web-Export

In Godot: **Projekt → Exportieren → Web** (Presets sind im Projekt bereits
angelegt). Godot erzeugt `index.js`, `index.wasm`, `index.pck` etc. im
Export-Ordner.

### 4. Deployment (Static Hosting)

Die Godot-Exportdateien **und** den Inhalt von `build/web_bridge/` in
denselben Ordner legen (oder `build/web_bridge/` per Webserver auf dem
Pfad bereitstellen, der zu `web_worker_url`/`web_bundle_url` passt) und auf
einem statischen Host ausliefern (HTTPS, korrekter WASM-MIME-Type).

### 5. Testen

Browser öffnen → die Demo läuft mit Pyodide: gleiche Ausgabe wie auf
Desktop, nur der Transport unterscheidet sich.

## Konfiguration (project.godot)

| Key | Wert | Bedeutung |
|---|---|---|
| `web_worker_url` | `bridge_worker.js` | Worker liegt neben dem Export |
| `web_bundle_url` | `bridge_workspace.tar` | virtuelles Dateisystem |
| `web_packages` | `numpy` | Pyodide-Pakete beim Start laden |
| `web_cdn_url` | jsDelivr v0.26.4 | CDN-Fallback ohne lokales Bundle |

Alle Keys sind über `PythonBridge.configure_instance()` überschreibbar.

## Grenzen im Browser

- kein `OS.create_process`, kein venv, keine nativen Desktop-Wheels
  (`.so`/`.pyd`) — nur Pyodide-kompatible Pakete
- serielle Python-Ausführung (ein Worker); Queues/Timeouts/Cancel bleiben
  Godot-seitig vollständig erhalten

Details: `docs/WEB_RUNTIME.md` im Repository.
