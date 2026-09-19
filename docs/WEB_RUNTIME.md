# Python im Browser: Pyodide-Web-Runtime

## Status: implementiert und getestet

Die Bridge unterstützt **beide** Wege produktiv:

```text
Desktop:  Godot → Python-Prozess → WebSocket → Bridge-Server
Web:      Godot → Web Worker → Pyodide (WASM) → browser_host (dieselbe Bridge)
```

Die Web-Integration wurde unter die bestehende API gesetzt — kein zweiter
API-Stack. TaskManager, Scheduler, Protocol v2, Serializer, Result-/Fehler-
Objekte, Context-Hashes, Introspection, Hot Reload und die Facade bleiben
unverändert. Nur der Transport wurde ausgetauscht.

## Architektur

```text
Godot Web
  │ JavaScriptBridge + Worker (postMessage)
  ▼
bridge_worker.js
  │  baut Pyodide, entpackt bridge_workspace.tar in MEMFS,
  │  lädt python_bridge (browser_host.py) + Pakete
  ▼
Pyodide (WASM)
  │
  ▼
python_bridge.browser_host
  │  Protocol v2 (identische Frames), Executor mit Contexts,
  │  DataRefs, Binary-Chunks, Introspection
  ▼
virtuelles Dateisystem (MEMFS)
  ├── python/          Bridge-Paket + Nutzer-Skripte
  ├── modules/         eigene Module
  ├── plugins/         Bridge-Plugins
  └── packages/        gebündelte pure-Python-Wheels
```

### GDScript-Seite (minimalinvasiv)

| Klasse | Rolle |
|---|---|
| `BridgeWebInstance` (core/bridge_instance_web.gd) | erbt die komplette State-Machine von `BridgeInstance` (PROVISIONING→READY, Health, Crash-Restart-Policy, Message-Routing, Shutdown); überschreibt nur den Start |
| `BridgeWebConnection` (core/bridge_web_connection.gd) | ersetzt `BridgeConnectionManager` (WebSocketPeer) durch die Worker-`postMessage`-Pipe; same State-Machine |
| `python_bridge.gd` | wählt auf Web-Exports automatisch `BridgeWebInstance` |

Konfiguration (alle Keys in `core/config.gd`, per `configure_instance()`
überschreibbar):

| Key | Default | Bedeutung |
|---|---|---|
| `web_transport` | `false` | Pyodide-Transport auch auf Desktop erzwingen (für Tests) |
| `web_worker_url` | `bridge_worker.js` | Pfad/URL des Workers neben dem Export |
| `web_pyodide_dir` | `""` | lokale Pyodide-Runtime (offline-first); leer = CDN |
| `web_cdn_url` | jsDelivr v0.26.4 | CDN-Fallback für Pyodide |
| `web_bundle_url` | `bridge_workspace.tar` | virtuelles Dateisystem (Workspace-Bundle) |
| `web_packages` | `numpy,scipy,pandas` | Pyodide-Pakete, die der Worker lädt (verbindliches Wissenschaftsprofil) |
| `web_tag` | `web` | Instanz-Tag |

## Build & Deployment (Static Hosting)

```bash
python3 tools/build_web_bundle.py --project . --out build/web_bridge \
  --packages numpy,scipy,pandas
python3 tools/export_check.py --project . --platform web
```

Der Builder erzeugt neben dem Godot-Web-Export:

| Datei | Zweck |
|---|---|
| `bridge_worker.js` | der Pyodide-Worker (aus dem Addon kopiert) |
| `bridge_workspace.tar` | Workspace für das virtuelle FS |
| `bridge_deps.json` | `__bridge_deps__`-Deklarationen der Skripte (Worker lädt sie vor der ersten Message) |
| `pyodide/` | optional: lokale Runtime (offline-first) |
| `bridge-lock.json` | aufgelöste Versionen (reproduzierbar) |

#### Dependencies im Python-Code (Web)

Skripte deklarieren ihre Pakete selbst — der Worker lädt sie beim Start
über das Pyodide-Paket-Repository, genau wie `web_packages`:

```python
__bridge_deps__ = ["numpy", "pandas>=2.0"]
```

Fehlt ein Paket im Bundle, meldet der Host vor der Ausführung einen
strukturierten `DEPENDENCY_ERROR` (mit Rebuild-Hinweis) — es gibt kein pip
im Browser und kein still schiefgehendes `import`.

Strategie: **lokal gebündelt zuerst, CDN als Fallback**. Ohne `--local-pyodide`
wird der jsDelivr-CDN benutzt; mit lokalem Pyodide läuft alles ohne Netz.
Pure-Python-Pakete können per `--local-packs` direkt in die Workspace-`packages/`
gebündelt werden. Native Wheels (NumPy/SciPy/Pandas) kommen aus dem
Pyodide-Paket-Repository (lokal oder CDN) — das ist die einzig technische
Möglichkeit, sie über Static Hosting zu verteilen.

Anforderungen an den Hoster: HTTPS (sicherer Kontext), korrekter
WASM-MIME-Type, erreichbare JS/WASM/Paket-Dateien, CORS nur bei Cross-Origin.
GitHub Pages, Cloudflare Pages oder jeder statische Webserver reichen.

## Wissenschafts-Stack: verbindlich getestet

NumPy, SciPy und Pandas werden **funktional** verifiziert
(`tools/test_web_runtime.mjs`, echte Pyodide-Runtime in Node):

- NumPy: `linalg.solve`, FFT, Matrixmultiplikation
- SciPy: `integrate.quad`, `optimize.minimize_scalar`
- Pandas: `groupby().sum()`, `merge()`

Zusätzlich verifiziert der Test: Worker-Start, vFS-Entpacken,
Modul-/Plugin-Loading über Tasks hinweg, DataRefs mit Binary-Frames
(2-MB-Array), Fehler-Rückgabe und Cancellation. Auf Desktop werden dieselben
Bibliotheken über die echte Server-Integration getestet
(`test_server_integration.py`).

## Python-Code bleibt plattformunabhängig

```python
def calculate(values):
    return sum(values)
```

Plattformunterschiede kapselt die Bridge (Kompatibilitätsschicht: Transport,
Dateisystem, Paket-Laden). Nutzer-Code sieht sie nicht. Nur wenn eine
Bibliothek technisch nicht portierbar ist (native Extension ohne WASM-Wheel),
entsteht eine klare Plattformmeldung statt eines stillen Fehlschlags.

## Bewusste Browser-Grenzen

- kein `OS.create_process()`, keine lokalen TCP-Sockets, kein venv/ensurepip
- keine beliebigen nativen CPython-Erweiterungen (nur WASM-Wheels)
- Python-Ausführung seriell (ein Worker-Slot); Queues, Timeouts, Batching,
  Cancellation und Health bleiben Godot-seitig vollständig erhalten
- Shared-Memory-Threads (Cross-Origin-Isolation) sind bewusst nicht Teil
  der ersten Version; große Werte laufen über Binary-Frames/DataRefs

## Externer WebSocket-Dienst (optional, unverändert)

Der Desktop-Server kann weiterhin als externer Dienst betrieben werden. Für
den Standard-Web-Workflow ist er **nicht** mehr notwendig.

## Quellen

- [Pyodide Quickstart](https://pyodide.org/en/stable/usage/quickstart.html)
- [Pyodide WASM-Einschränkungen](https://pyodide.org/en/stable/usage/wasm-constraints.html)
- [Pyodide Dateisystem](https://pyodide.org/en/stable/usage/file-system.html)
- [Pyodide Deployment](https://pyodide.org/en/stable/usage/downloading-and-deploying.html)
- [Godot Web-Export](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)
- [Godot JavaScriptBridge](https://docs.godotengine.org/en/stable/tutorials/platform/web/javascript_bridge.html)
