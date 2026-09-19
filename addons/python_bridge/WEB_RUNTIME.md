# Python Bridge Web-Export (Pyodide)

Die Bridge bringt seit dieser Version einen echten **Web-Transport** mit:
Python läuft über **Pyodide (WebAssembly)** in einem Web Worker — direkt im
Browser, ohne externen Python-Server, betriebsfähig auf normalem Static
Hosting.

```text
Godot Web
  │  JavaScriptBridge + Worker (postMessage)
  ▼
bridge_worker.js
  │
  ▼
Pyodide (WASM)
  │
  ▼
python_bridge.browser_host  ← dasselbe Protokoll v2, derselbe Executor
  │
  ▼
virtuelles Dateisystem (workspace-bundle: python/, modules/, plugins/)
```

## Was automatisch passiert

- Auf Web-Exports wählt die Bridge automatisch den Pyodide-Transport
  (`BridgeWebInstance`). Desktop (Windows/Linux) bleibt unverändert.
- Dieselbe öffentliche API wie auf Desktop:

```gdscript
await PythonBridge.start_instance("default")
PythonBridge.create_script("hello", "def greet(n):\n    return 'Hi ' + n")
var r := await PythonBridge.call_script("hello", "greet", ["Godot"])
print(r.value)   # "Hi Godot"
```

## Vorbereitung (ein Schritt)

Vor dem Web-Export das Workspace-Bundle bauen und daneben legen:

```bash
python3 tools/build_web_bundle.py --project . --out build/web_bridge
python3 tools/export_check.py --project . --platform web
```

Der Bundle-Builder erzeugt:

| Datei | Zweck |
|---|---|
| `bridge_worker.js` | der Pyodide-Worker (aus dem Addon) |
| `bridge_workspace.tar` | virtuelles Dateisystem (Python-Dateien, Module, Plugins) |
| `pyodide/` | optional: lokale Pyodide-Runtime (offline-first; sonst CDN-Fallback) |
| `bridge-lock.json` | aufgelöste Versionen für reproduzierbares Hosting |

NumPy/SciPy/Pandas werden als **verbindlich unterstützte** Pyodide-Pakete
funktional getestet (`tools/test_web_runtime.mjs`) — nicht nur per
`import numpy`, sondern mit echten Berechnungen (Lösung linearer Systeme,
FFT, Matrixmultiplikation, numerische Integration/Optimierung, GroupBy/Merge).

## Plattform-Matrix

| Plattform | Transport | Status |
|---|---|---|
| Windows/Linux | Python-Prozess + lokaler WebSocket | implementiert |
| Web | Pyodide im Web Worker + virtuelles FS | implementiert, funktional getestet |

## Dependencies im Python-Code

Jedes Skript deklariert selbst, was es braucht (erste Zeile):

```python
__bridge_deps__ = ["numpy", "pandas>=2.0"]
```

- **Desktop:** Provisioner installiert die deklarierten Pakete automatisch
  in die venv; fehlt ein Paket später, installiert der Server nach bzw.
  startet die Instanz einmal neu. Fehlt es dauerhaft, kommt ein klarer
  `DEPENDENCY_ERROR` statt eines NameError mitten im Aufruf.
- **Web:** `build_web_bundle.py` schreibt die Deklarationen in
  `bridge_deps.json`; der Worker lädt sie vor der ersten Message über das
  Pyodide-Paket-Repository (wie `web_packages` auch).
- Alternativ/additiv: `PythonBridge.register_dependencies(["numpy"])` aus
  GDScript oder `python_bridge/config/dependencies.txt`.

## Bewusste Grenzen (Browser)

- kein `OS.create_process()`, keine lokalen TCP-Sockets, kein venv
- nur Pyodide-kompatible Pakete (pure Python oder WASM-Wheels); native
  Desktop-Wheels (`.so`/`.pyd`) funktionieren nicht — die Bridge meldet das
  als klare Plattformmeldung
- Python-Ausführung ist zunächst seriell (ein Worker); Queues, Timeouts,
  Batching und Cancellation bleiben Godot-seitig vollständig erhalten

Details: `docs/WEB_RUNTIME.md` im Repository.
