# Changelog

## v0.5.0 (current)

### Web und Cython tun jetzt wirklich, was die Doku verspricht

- **Web: Skripte kommen im Pyodide-Workspace an.** Neuer einseitiger
  `file_op`-Kanal (`addons/python_bridge/python/python_bridge/workspace_files.py`)
  spiegelt Schreib-/Loeschvorgaenge aus Godot in das MEMFS des Workers -
  vorher existierte ein zur Laufzeit angelegtes Skript dort nie (`import x`
  schlug fehl), und ein geloeschtes blieb importierbar. Pfade sind auf die
  Workspace-Ordner beschraenkt (`..`, absolute Pfade und fremde Ordner werden
  abgelehnt), Schreibvorgaenge sind atomar, `__pycache__` wird mit entfernt,
  und `sys.modules` wird fuer die betroffene Datei geleert.
- **Keine verlorenen Web-Schreibvorgaenge**: Ist noch keine Instanz bereit,
  werden Datei-Ops gepuffert (pro Pfad gewinnt die letzte Operation, FIFO fuer
  den Rest, harte Obergrenze) und beim Wechsel nach `ready` nachgezogen.
- **Der Editor meldet Speichervorgaenge an die Bridge**: neues
  `notify_script_saved()` (Cache, Web-Spiegelung, Cython-Modul-Invalidierung).
  Das Dock schreibt direkt ueber `script_store` - ohne diese Meldung hätte
  Python im Browser und bei Cython den alten Stand gesehen. Umbenennen
  invalidiert jetzt auch den alten Namen (`notify_script_deleted`).
- **Cython-Build auf Windows repariert.** `cython_build.py` probiert die
  Compiler-Wege jetzt in der Reihenfolge, in der sie funktionieren:
  Windows MSVC -> MinGW-w64 (`--compiler=mingw32`, falls `gcc` im PATH);
  POSIX System-CC -> `ziglang`. Vorher wurde auf Windows `ziglang`
  "angeboten", das setuptools dort aber ignoriert (MSVC-Treiber) - der Build
  scheiterte mit "Microsoft Visual C++ 14.0 or greater is required".
  Build-Zwischenstaende landen komplett in `cython_build_tmp` (kein `build/`
  mehr im Skriptordner) und werden nach Erfolg entfernt.
- **Cython-Aufrufe auf Windows repariert**: Der Modulname wurde nur an `/`
  getrennt, bei `cython:C:\...\mathx.pyx` blieb der ganze Pfad als
  "Modulname" uebrig -> jeder `call_script` endete in `ModuleNotFoundError`.
  Gemeinsame, plattformfeste Stem-Ableitung in `executor.py`.
- **Geaenderte `.pyx` wird erkannt**: `call_script` vergleicht den SHA-256 der
  Quelle mit dem letzten Build und baut inkrementell nach, statt still den
  alten kompilierten Stand auszufuehren. Hot Reload auf `.pyx` verwirft das
  Modul (`mode: cython_invalidate`) statt Cython-Quelltext zu exec-en.
- **Speichern als `.py` raeumt Cython-Reste ab**: `.c`, `.so`/`.pyd`,
  `cython_build_tmp`-Reste und der Build-Hash verschwinden (sonst blieb ein
  veraltetes Modul importierbar). Das Gegenstueck (`.py` <-> `.pyx`) wird erst
  **nach** erfolgreichem Schreiben entfernt - ein fehlgeschlagener Save kostet
  die bestehende Datei nicht mehr.
- **Sortieren von `.pyx`-Importen**: der Desktop-Server haengt `scripts/`
  jetzt auch dann an `sys.path`, wenn der Ordner erst zur Laufzeit entsteht.

### Einstellungen sind auffindbar (automatisch ODER manuell)

- **Projekt > Projekteinstellungen > Python Bridge** mit 7 Feldern
  (`autostart`, `workspace_dir`, `python_executable`, `dependencies`,
  `hot_reload_mode`, `auto_generate_wrappers`, `web_packages`), inklusive
  Datei-/Ordner-Picker und Auswahlliste. Registrierung und Lesepfad stammen aus
  derselben Quelle (`PythonBridgeConfig.project_setting_defs()`).
- **Dock: `...` -> Einstellungen ...** mit denselben Feldern und dem Knopf
  "Speichern & neu starten" - Aenderungen greifen sofort statt beim naechsten
  Projekstart.
- **Neues Werkzeuge-Menue** (`Projekt > Werkzeuge`): Dock anzeigen, Neue
  Datei, Einstellungen, Instanz starten/stoppen, Cython kompilieren. Vorher
  war alles nur ueber den Dock-Tab erreichbar.
- **Optionale `config.json`** im Workspace fuer Teams/CI. Praezedenz:
  Defaults -> Projekt-Einstellungen -> `config.json` -> `configure()`.
  `reload_config()` liest die Kette neu, ohne eine laufende Instanz zu beenden.
- **`python_executable` = System-Python** wird als dokumentierter Weg
  unterstuetzt (venv wird uebersprungen, `websockets` muss vorhanden sein).

### Tests

- Neu: `tests/python/test_workspace_files.py` (Pfad-Sicherheit, atomares
  Schreiben, Bytecode-/Modul-Cache), `file_op`-Tests im Browser-Host und im
  echten Desktop-Server, `tests/gdscript/test_bridge_sync.gd` (Puffer-Logik),
  `tests/gdscript/test_config_settings.gd` (Praezedenz, Typ-Coercion).
- `tests/live_cython_e2e.py` ist jetzt portabel (Windows/Linux/macOS): baut
  frisch, startet einen echten Server und prueft Call, Persistenz,
  Fehlerpfad und inkrementelles Skip - vorher mit Linux-Hardcodings
  unbrauchbar.
- Zahlen: 205 Python-Tests (28 skipped ohne optionale Pakete), 384
  GDScript-Assertions, 17 Editor-Verifikationen, 9 Live-Cython-Checks,
  23 Checks in echter Pyodide-Runtime.
- `tools/test_web_runtime.mjs` lief unter Windows gar nicht (Node verlangt
  `file://`-URLs für absolute Modulpfade) - behoben. Der Test prüft jetzt auch
  den `file_op`-Kanal in echter Pyodide-Runtime: schreiben → importierbar,
  löschen → nicht mehr importierbar, Pfad-Ausbruch abgelehnt, Worker lebt
  weiter.
- **Neu:** `PythonBridge.restart_instance()` (Stop abwarten, dann Start) -
  direktes `stop_instance()` + `start_instance()` scheitert am
  `stopping`-Zustand. Der Knopf „Speichern & neu starten“ nutzt ihn.

## v0.4.0

### Editor-Dock: Redesign, zuverlaessiges Speichern, rueckstandsfreies Loeschen

- **Stabile Tabs** ueber `TabContainer`: ein `CodeEdit` pro Tab (eigene
  Undo-Historie + Highlighter), `get_index()` statt paralleler Index-Listen,
  Drag & Drop, Close-Button am aktiven Tab, Mittelklick, `Strg+W`.
  Der Editor-Hot-Reload des Dock-Skripts stellt offene Tabs inklusive Text
  wieder her (`_capture_tabs`/`_restore_tabs`) - vorher gingen sie verloren.
- **Syntax-Highlighting korrigiert**: Jede Region setzt nach ihrem Ende
  explizit die Default-Farbe (vorher blieb der Rest der Zeile nach Strings,
  Zahlen und Kommentaren in der Token-Farbe), Spalte 0 ist immer explizit
  Default. Mehrzeilige Docstrings werden pro Zeile gecacht statt pro Aufruf
  neu gescannt (`invalidate()` bei Textaenderung). Zahlen (Basen, Exponent,
  `j`), Decorator-Dotted-Names und Aufrufnamen werden korrekt behandelt.
- **Oeffnen/Speichern fehlerfrei**: neue Dateischicht
  `editor/script_store.gd` (rein, ohne Bridge-Abhaengigkeit) unterscheidet
  leere Datei von Lesefehler, normalisiert CRLF/BOM und meldet Schreibfehler
  strukturiert. Ein Skript existiert nie gleichzeitig als `.py` und `.pyx`
  (Umschalten entfernt das Gegenstueck sichtbar).
- **Temporaere Skripte im Dock**: Scratch-Tabs leben nur im Speicher und
  laufen ueber `PythonBridge.execute()`; `Strg+S` macht daraus eine Datei.
- **Rueckstandsfreies Loeschen**: `PythonBridge.delete_script(id)` (Kern:
  `core/script_files.gd`) entfernt Quelle, `.py.uid`, `__pycache__`/`.pyc`,
  `.c`, `.so`/`.pyd`, `.o`/`.obj` unter `cython_build_tmp`, den Eintrag in
  `.cython_state.json` und den generierten Wrapper samt `.uid`; leere
  Hilfsordner werden mit entfernt. Rueckgabe: `{ok, existed, removed[],
  failed[], cython_state_cleared}`. Im Dock: Rechtsklick -> Loeschen (mit
  Bestaetigung, schliesst den offenen Tab).
- **Aufraeumen im Dock**: Umbenennen, Filter, automatische Listen-
  Aktualisierung, externe Aenderungen werden nur bei nicht-dirty Tabs
  nachgeladen, Shortcuts `Strg+N`/`Strg+S`/`Strg+W`/`Strg+Enter` (nur bei Fokus im
  Dock), Instanz startet beim Ausfuehren bei Bedarf automatisch.
- **Neue API**: `delete_script`, `list_scripts`, `validate_script_id`,
  `scripts_dir`, `wrapper_dir`.
- **Tests**: neue Headless-Suite `test_editor_files.gd` (Dateischicht,
  Artefakt-Loeschung, Umbenennen, Highlighter inkl. Farb-Reset und Docstring-
  Zustand); `verify_editor.gd` prueft jetzt das echte Dock (Scratch-Tab,
  Highlighter, Reload-Wiederherstellung, Speichern und Loeschen ueber das
  Dock). Stand: 273 Assertions gruen (vorher 193).
- **Doku**: neue verbindliche Anleitung `docs/ERSTE_SCHRITTE.md` (von Null,
  beide Skript-Typen, Loeschtabelle, Versionsklarheit) und `docs/README.md`
  als Index mit Status-/Autoritaets-Tabelle; README und API-Referenz auf
  0.4.0 gezogen.

## v0.3.3

### Fixed: __bridge_deps__-Kette

- **Deklarationen werden jetzt überall erkannt**: Der GDScript-Regex
  verankerte `^__bridge_deps__` nur an der allerersten Datei-Zeile —
  Deklarationen nach Kommentaren/Imports (Praxis-Normalfall) wurden
  ignoriert. Jetzt zeilenankerbasierend wie die AST-Extraktion der
  Python-Seite.
- **Cython-Scripts vererben ihre Dependencies**: `.pyx`-Tasks tragen keine
  Source, deshalb bekam der Server-Auto-Install ihre Deklarationen nie.
  Deklarationen laufen jetzt via `task.meta["deps"]` mit → fehlende Pakete
  (z. B. numpy) werden vor dem ersten Cython-Call automatisch installiert.
- **`.pyx` im Workspace-Dep-Scan**: Der Provisioner las bei der Sammlung
  der Skript-Dependencies nur `*.py` — `.pyx`-Deklarationen zählen jetzt
  auch.

Verifiziert: frischer Aufruf-Pfad mit `hello_cython.pyx` (numpy-Deklaration
nach Kommentarzeilen) — venv erhielt numpy automatisch, `smear`-Call
lieferte korrekt, Suite 180/180 OK.

## v0.3.2

### Belastungsprobe (Echtspiel-Verifikation)

- Realer Test in einem frischen Godot-Projekt ("Belastungsprobe"): Cython
  vs. pure Python (**51x Speedup** bei identischer Mandelbrot-Berechnung),
  numpy-Wellengrid live in eine 3D-Punktwolke (10 Hz), pandas-GroupBy
  (100k Zeilen, ~360 ms) und 10 s Dauerlast mit parallelen Calls
  (**775 Calls/10 s, 0 Fehler**).
- Aus der Probe resultierende Fixes: `compile_cython` akzeptiert beide
  Godot-await-Signalformen (Argument direkt vs. Array), parallele Caller
  warten auf den laufenden Build statt Fehler, `res://`-Pfade werden vor
  Prozessstart globalisiert (Host-Prozesse verstehen kein res://).

### Cython-Sonderpfad (Desktop)

- **.pyx-Skripte als First-Class-Buerger**: Toggle im Editor-Dock ("Als
  Cython-Modul kompilieren"), Speichern als `.pyx`, automatischer
  inkrementeller Build vor dem ersten `call_script` (Hash-basiert,
  unveranderte Module werden uebersprungen). Kompilierte Module werden
  importiert und verhalten sich im Kontext wie .py-Skripte.
- **Compiler unabhaengig vom System**: System-CC bevorzugt; ohne gcc/MSVC
  automatischer Fallback auf das pip-Paket `ziglang` (kompletter C-Compiler
  als Wheel). Fehlende Build-Komponenten installiert das Tool selbst in die
  venv (Self-Provisioning). Beweis: Build+Import funktionieren in einer venv
  ohne jeglichen System-Compiler.
- **Stabilitaet**: Build laeuft als eigener Kurzprozess ueber die venv
  (asynchron, Report-Datei atomar) - Server/Executor/Protokoll unangetastet,
  ein fehlgeschlagener Build kann die Instanz nicht destabilisieren. Web:
  bewusst nicht unterstuetzt (kein C-Compiler in Pyodide); Export-Check
  warnt bei .pyx im Projekt.
- Neue Tests (`test_cython.py`, 7) - Suite jetzt 180 Tests; Doku-Seite
  "Cython-Module (Desktop)" auf der Website.

### Export-Scripts + ZIP-Build

- **Export in einem Befehl**: `export_web.sh` (`--serve`/`--debug`),
  `export_linux.sh` und `export_windows.sh` im Addon unter
  `tools/` - verketten Vorraussetzungs-Check, Export-Check, (Web-)Bundle und
  headlessen Godot-Export; finden Godot nativ oder per Flatpak selbst.
  Windows-Script warnt fehlendes Wine ab (nur fuer Icon-Patching noetig).
- **Reproduzierbarer ZIP-Build**: `tools/build_plugin_zip.sh` packt das
  Release-ZIP (Addon + Docs, ohne Tests/Caches) mit ausfuehrbaren Scripts.
### Ergebnis-Budget & geordnetes Shutdown (Hardening-Runde)

- **Result-Budget vor dem Encoding (2.7)**: Ergebnisse, die
  `max_result_bytes` ueberschreiten, werden jetzt VOR der Serialisierung
  abgelehnt (billige Groessen-Schaetzung, ndarray exakt via `nbytes`;
  zyklus- und rekursions-sicher). Bisher wurde erst komplett kodiert
  (2-3x Speicherkopien) und dann abgelehnt - im Browser (WASM-Heap) der
  typische OOM-Moment. Antwort ist jetzt ein sofortiger strukturierter
  `SERIALIZATION_ERROR` (`ResultTooLargeError`), single und pro Batch-Item;
  der nachgelagerte Frame-Check bleibt als Backstop.
- **Geordnete Shutdown-Antworten (4.2)**: Beim Shutdown wartende Queue-Jobs
  bekommen jetzt eine strukturierte `task_error` (`CONNECTION_ERROR`),
  bevor die Verbindung geschlossen wird - statt still verworfen zu werden
  (frueher: Timeout-Raten auf Godot-Seite). In-flight-Jobs sind technisch
  nicht wartbar (Threads sind nicht killbar); dokumentierte Grenze.
- **Exit-Codes propagieren (4.3)**: Server-Fehler (z. B. fehlendes
  `websockets`) enden mit Log + Exit 1 statt stummem Exit 0; geordnete
  Beendigung bleibt Exit 0. Godots Restart-Policy kann damit defekte
  Server von sauberen Stops unterscheiden.
- **Lifecycle-Logging auf fd 2**: `execute_job` redirectet sys.stdout UND
  sys.stderr prozessweit, solange ein Task laeuft - Shutdown-/Fatal-Logs
  verschwanden bisher unsichtbar im Task-Puffer. `_server_log` schreibt
  jetzt direkt auf Datei-Deskriptor 2 (nur die Python-Objekte, nie die
  FDs werden getauscht) - Beweis via strace im Live-E2E.
- Neuer Live-E2E-Test (`tests/live_e2e_hardening.py`): echte Server-
  Prozesse, 11 Szenarien (Budget-Latenz, Drain-Reihenfolge, Exit-Codes).

### Robustheit & Korrektheit (Review-Runde)

- **`read_region`/`write_region`**: Warfen zuvor `AttributeError` (das
  Backend-Modul hatte keine `read`/`write`-Methoden). Nutzen jetzt ein
  modulweites Backend-Singleton mit korrekter Handle-Verwaltung
  (funktional getestet: create → write → read Roundtrip).
- **Wrapper-Generator / Introspektion**: Defaults bei
  positional-only-Parametern (`def f(a, b, /, c=1)`) wurden falsch
  zugeordnet (`a`/`b` erbten die Defaults von `c`/`d`). Korrekt:
  posonly+pos bilden EINE Sequenz, Defaults binden von hinten.
- **Kooperative Cancellation**: `cancel_requested()` konsumiert das
  Cancel-Flag nicht mehr — Muster wie `if cancel_requested(): checkpoint()`
  oder `while not cancel_requested(): ...` bleiben jetzt zuverlässig.
  Aufgeräumt wird am Job-Start (`consume_cancelled`).
- **Port-Datei atomar**: Die `tmp/<tag>.json` (Port+PID) wird per
  `os.replace` geschrieben — kein halbfertiges JSON mehr beim parallelen
  STARTING-Poll.
- **`run_server.py --tmpdir=x`**: Beide CLI-Formen (`--tmpdir x` und
  `--tmpdir=x`) werden unterstützt; zuvor brach die `=`-Form den
  Workspace-Import-Pfad.
- **Shared Memory auf allen Plattformen**: `multiprocessing.shared_memory`
  funktioniert auf Windows (CreateFileMapping) und macOS (POSIX shm) —
  die frühere Linux-Beschränkung wurde entfernt (dokumentiert).
- **Serializer**: `datetime`/`date`/`time`, `Decimal`, `UUID`,
  `pathlib.Path` und `enum.Enum` bekommen eigene Tags (`dt`, `dec`,
  `uuid`, `path`, `enum`) statt des repr-String-Fallbacks; auf Godot-Seite
  strukturiert dekodiert (Strings bzw. Enum-Wert).
- **`_CappedWriter`**: `write()` gibt die tatsächlich übernommenen Zeichen
  zurück (verhindert verfälschte `print()`-Rückgabewerte).
- **Web-Worker-Fehlerpfade**: Nach einem Startup-Fehler wird der Worker
  wieder startbar (Retry möglich); Bridge-Messages vor `ready` bekommen
  eine strukturierte `task_error`-Antwort statt Funkstille (kein
  Task-Timeout mehr beim Warten auf einen noch nicht bereiten Host).

### Desktop-Export (v0.3.1-Fixes, hier dokumentiert)

- Workspace liegt im Export unter `user://python_bridge/` — PCK-Inhalte
  werden beim ersten Start dorthin seediert, OS-Prozesse können aus dem
  PCK nicht lesen.
- Korrektes Feature-Tag (`template` statt `export`) für die
  Export-Erkennung; Web-Transport erkennt seinen Zustand über
  `OS.has_feature("web")` statt über die Client-Existenz.
- Web-Connect-Timeout 120 s (Pyodide-Kaltstart vom CDN), Desktop bleibt
  bei 20 s.

## v0.3.1

### Abhängigkeiten direkt im Python-Code deklarieren

- **`__bridge_deps__ = ["numpy", "pandas>=2.0"]`** in der ersten Zeile eines
  Workspace-Skripts ist die Single Source of Truth für dessen Pakete —
  der Python-Code selbst sagt der Bridge, was er braucht.
- **Desktop**: Der Provisioner liest alle Deklarationen automatisch mit
  (`combined_requirements`: Skripte + `configure("dependencies")` +
  `config/dependencies.txt`) und installiert sie im venv-Lauf. Fehlt beim
  ersten Call ein neu deklariertes Paket, installiert der Server es direkt
  in die laufende venv (ein pip-Lauf, strukturierte Fehler bei Misserfolg).
  Alternativ startet `call_script` die Instanz einmal neu (Auto-Restart,
  einmal pro Skript-Version).
- **Web**: `build_web_bundle.py` schreibt `bridge_deps.json`; der Pyodide-
  Worker lädt deklarierte Pakete vor der ersten Message (gleicher Mechanismus
  wie `web_packages`) und registriert sie am Host. Fehlende Pakete erzeugen
  auf Web einen klaren DEPENDENCY_ERROR mit Rebuild-Hinweis — nie pip, nie
  stille Fehlverhalten.
- **Executor-Gate**: Deklarierte, aber nicht importierbare Pakete führen zu
  einem strukturierten `DEPENDENCY_ERROR` BEVOR Nutzercode läuft (statt
  NameError/ImportError mitten im Aufruf). Bereits geladene/verifizierte
  Pakete (Provisioner-HELLO-Kappe `installed_dependencies`) werden ohne
  erneute Probe akzeptiert.
- **Neue API**: `PythonBridge.register_dependencies(["numpy", ...])` schreibt
  `config/dependencies.txt` (idempotent, dedupliziert) für die nächste
  Instanz-Startphase.
- **Tools im Addon**: `export_check.py` und `build_web_bundle.py` liegen
  jetzt auch unter `addons/python_bridge/tools/` — der Beispiel-/Export-
  Workflow braucht kein Repository-Checkout mehr.
- **Fix**: Der Provisioner-Verify prüft jetzt ALLE kombinierten Requirements
  (vorher nur `configure()`-Liste); der Fast-Path re-prüft neue Deklarationen,
  statt eine veraltete venv still zu akzeptieren.
- **Tests**: 20 neue Tests (Extraktion, Executor-Gate, Auto-Install,
  Batch-Fehlerform, Web-Verhalten ohne pip); 156/156 grün, Web-Runtime
  20/20 PASS mit echtem Bundle.

## v0.3.0

### Web-Transport (Pyodide)

- **Pyodide im Web Worker**: Python läuft im Browser über WebAssembly —
  `bridge_worker.js` baut Pyodide, entpackt das Workspace-Bundle in das
  virtuelle Dateisystem (MEMFS) und dispatcht Protocol-v2-Frames an
  `browser_host.py`.
- **`BridgeWebInstance`/`BridgeWebConnection`**: erben die komplette
  `BridgeInstance`-State-Machine (PROVISIONING→READY, Health, Crash-Restart,
  Message-Routing, Shutdown); nur der Transport wird ausgetauscht. Auf
  Web-Exports wird der Web-Transport automatisch gewählt (`web_transport`-
  Config erzwingt ihn auch auf Desktop für Tests).
- **`browser_host.py`**: Web-Gegenstück zu `server.py` — dieselbe Protocol-v2-/
  Executor-/DataRef-/Introspection-Schicht ohne asyncio/WebSockets.
- **Workspace-Bundle-Builder** (`tools/build_web_bundle.py`): baut Worker +
  Workspace-Tar + Lockfile, optional lokale Pyodide-Runtime und gebündelte
  pure-Python-Wheels (lokal-first, CDN-Fallback) für Static Hosting.
- **Funktionaler Wissenschafts-Stack-Nachweis** (`tools/test_web_runtime.mjs`):
  echte Pyodide-Runtime in Node — NumPy (linalg/FFT/Matmul), SciPy
  (Integration/Optimierung), Pandas (GroupBy/Merge), vFS, Module/Plugins,
  DataRefs mit 2-MB-Binary-Frames, Fehler und Cancellation: 20/20 PASS.
- **Server.py toleriert fehlendes `websockets`** und `__init__.py` lädt `server`
  lazy — der Web-Import zieht keine Desktop-Abhängigkeiten.

### Export-Check & Tests

- **Export-Check ausgebaut**: Windows/Linux mit Runtime-, Versions- und
  Permissions-Prüfung; Web mit Bundle-Prüfung und `--fix`-Integration
  (`build_web_bundle`).
- **18 neue Web-Host-Tests** (`test_browser_host.py`) und **6 neue
  Server-Integrationstests** (Crash per `os._exit`, Disconnect-Grace,
  Multi-Task-Integrität, funktionaler NumPy/SciPy/Pandas-Desktop-Check):
  Python-Suite 136/136 grün.

### Cluster entfernt

- Sämtliche Cluster-/Orchestrator-/Worker-Node-Komponenten sind aus dem
  Repository entfernt; nur kleine Docstring-/Namens-Reste wurden bereinigt.
  Desktop- und Web-Funktionalität sind davon unberührt.

## Unreleased

### Phase 4 — Datei-basierte grosse Daten (Commit `5aa94f9`)

- **File-backed DataRefs**: Der Python-`DataStore` schreibt grosse Handles
  als Datei ins Instanz-Tmpdir (`res://python_bridge/tmp/data/`,
  Dateinamen pro Instanz-Tag, sha256-Summe im Deskriptor) statt sie im
  Prozess-Speicher zu halten.
- **Kein WebSocket-Transfer mehr fuer grosse Daten**: `data_get` mit
  `want="file"` liefert nur Pfad/Größe/Hash; Godot liest die Datei mit
  dem neuen `PythonBridgeDataFile` chunkweise per `FileAccess`
  (frame-budgetiert ueber `file_read_bytes_per_frame`, sha256-Verifikation,
  transparenter Fallback auf Binary-Chunk-Transport ohne Tmpdir).
- **Cleanup**: Release/Verbindungsende loeschen die Datei; Orphan-Cleanup
  je Instanz-Tag beim naechsten Serverstart.
- **Encoding in den Worker-Thread verschoben**: Result-Encoding (inkl.
  File-Write/Hash) laeuft im Job-Thread, nicht im asyncio-Loop.
- **Tests**: Python 83 (inkl. File-Transport-Integration, Release-loescht-
  Datei, Connection-Cleanup, Fallback), GDScript 60 (inkl. `DataFile`
  Chunk-Reader + sha256-Verifikation + Facade-File-Branch).

### Dokumentation & Editor-UX

- **Dock-Tab umbenannt**: Der Tab hieß zuvor „PythonBridgePanel“ (interner
  Node-Name) und war dadurch schwer zu finden — er zeigt jetzt
  **„Python Bridge“**.
- **Installations-Doku ausgebaut** (`docs/INSTALLATION.md`): vollständige
  Klick-für-Klick-Anleitung von der Plugin-Aktivierung über das Auffinden
  des Docks (mit ASCII-Diagramm) bis zur ersten Python-Datei — auch für
  Godot-Neulinge nachvollziehbar.
- **Praxis-Doku ergänzt** (`docs/PRAXIS.md`): Button-Übersicht des Docks
  und Workflow-Checkliste mit allen Editor-Schritten.
- **Bottlenecks dokumentiert** (`docs/BOTTLENECKS.md` + Kapitel 11 in der
  PDF): alle konkreten Engpässe der Bridge — Serienquote pro Instanz,
  verklemmte Worker, pro-Aufruf-Quelltext-Neusendung/-neuhash, HauptThread-
  Dekodierung ohne Byte-Budget, numerische Arrays per JSON, eigenständiges
  Kapitel mit A/B/C/D-Kategorien, Größenordnungen und Dateinamen.

### Phase 2 — Data Plane (Commits `f625c7b` … `2c5fbc5`)

- **Binärer Numerik-Transport**: grosse Godot-`Packed*Array`
  (f32/f64/i32/i64) wandern als Little-Endian-Binary-Chunks mit
  `nbytes`-Descriptor statt als JSON-Zahlenliste; kleine bleiben inline.
  Python dekodiert Chunks (mit NumPy als ndarray) und versteht die Legacy-
  Listenform.
- **Dtype-/nbytes-Validierung** auf beiden Decodern: Descriptor-Mismatch
  wird erkannt (leeres Typed Array / raw-Fallback statt stiller Garbage).
- **DataRef-Handles**: numpy-Ergebnisse >= `data_ref_threshold_bytes`
  (Default 16 MiB) bleiben im Python-Prozess (per-Connection-`DataStore`,
  Cleanup bei Verbindungsende); Godot erhält `PythonBridgeDataRef` mit
  `materialize_data`/`release_data`/`describe_data`. Protokoll:
  `data_get`/`data_result`/`data_release`/`data_ack`. Stale-Handles
  (Release/Instanz-Ende) liefern strukturierte Fehler.
- **Frame-Budget**: `max_decode_bytes_per_frame` (Default 16 MiB) — rohe
  Pakete werden gepuffert und nur bis zum Budget pro Frame dekodiert
  (kein Main-Thread-Stall durch grosse Antworten).
- **Neue Doku** `docs/DATA_PLANE.md`; `docs/ARCHITEKTUR_V3.md`-Status auf
  „Phasen 0–2 umgesetzt“ aktualisiert.

### Phase 3 — Worker & Recovery (Commits `623a23b`, `f6cfb1e`)

- **Mehrere Worker-Slots pro Instanz**: `workers_per_instance` (Python) +
  `max_inflight_per_instance` (Godot) — Tasks verschiedener Contexts
  laufen parallel, gleiche Contexts strikt seriell (Context-Locks in
  sortierter Reihenfolge, deadlock-frei; Godot-Scheduler dispatched busy
  Contexts nicht doppelt via `running_contexts()`).
- **Runaway-Isolation**: Ein per Timeout abgebrochener Task belegt nur
  seinen Slot; unabhaengige Contexts laufen weiter.
- **Kooperative Cancellation**: `__bridge__.cancel_requested()` /
  `__bridge__.checkpoint()` im Python-Code; strukturierter Abbruch
  (`status=cancelled`).
- **Watchdog / Kill-on-Runaway**: laeuft ein Job nach `runaway_grace_ms`
  weiter, beendet sich der Prozess selbst (kein Zombie); Godot restartet
  ueber die bestehende Restart-Policy.
- **Neue Doku** `docs/WORKERS.md`; V3-Status auf „Phasen 0–3 umgesetzt“.

**Tests:** GDScript-Suite 55 Tests / 179 Assertions (3 busy-Context-Tests),
Python-Suite 74 Tests (9 Worker-/Cancel-Unit-Tests, 4 Worker-
Integrationstests inkl. Kill-on-Runaway).

## v0.2.1

### Neu: Demo-Szene & Dokumentations-PDF

- **Demo-Szene** `example/demo_scene.tscn`: Nodes mit angehängten Skripten
  (`example/demo/`), die alle Kernfunktionen der Bridge zeigen:
  `DemoBasic` (call/execute/define_script), `DemoTasks` (Task-API,
  Priorität, Timeout, Cancel), `DemoBatch` (Batching), `DemoErrors`
  (strukturierte Fehler), `DemoMulti` (zwei Python-Instanzen parallel).
  UI-Panel mit Buttons; Beispielskripte in `example/scripts/`
  (`demo_skript.py`, `crash_skript.py` für den Crash-Restart-Test).
- **Dokumentations-PDF** `docs/PythonBridge_Dokumentation.pdf` (16 Seiten,
  im Stil der Original-PDF): Architektur, API-Referenz, Task Manager,
  Batching, Datentransport, Python-Seite, Editor-Integration, Demo-Szene,
  Lifecycle, Fehlerbehandlung, Troubleshooting.

Stabilitäts-Fix für Godot 4.7.x (und neuer): Das Addon kompiliert jetzt
fehlerfrei, wenn es als Autoload/Editor-Plugin geladen wird. Der Editor-
Parser (Autoload-Pfad) akzeptiert einige Konstrukte nicht, die der normale
Editor-Scan toleriert - das führte zu einem Kaskadenfehler, bei dem fast
jedes Skript mit „Could not resolve class … parser error“ scheiterte.

### Behobene Ursachen

- **Mehrzeilige `match`-Pattern-Listen** (Pattern über mehrere Zeilen vor
  dem Doppelpunkt) wurden im Autoload-Parsing abgelehnt
  („Expected expression for match pattern“). Alle Pattern-Listen stehen
  jetzt auf einer Zeile (`config.gd`, `error_handler.gd`, `scheduler.gd`,
  `bridge_instance.gd`).
- **Mehrzeilige Funktionssignaturen** (Parameter über mehrere Zeilen)
  wurden im Autoload-Parsing abgelehnt („Expected parameter name“). Alle
  Signaturen stehen jetzt auf einer Zeile (`error_handler.gd`, `protocol.gd`,
  `task.gd`, `type_mapper.gd`, `scheduler.gd`, `python_bridge.gd`,
  `wrapper_generator.gd`).
- **Nicht-literalische Konstanten**: `const DEFAULTS := { … }` mit
  `PackedStringArray()`/Arithmetik wurde als „isn't a constant expression“
  abgelehnt. `PythonBridgeConfig.DEFAULTS` ist jetzt die Funktion
  `PythonBridgeConfig.defaults()` (Runtime-Aufbau); weitere Konstanten sind
  explizit typisiert.
- **`class_name` als Parameter-/Variablenname** ist im Autoload-Kontext
  reserviert („Expected parameter name“ / „Expected variable name after
  var“). In `type_mapper.gd` (`register`) und `wrapper_generator.gd`
  umbenannt (`custom_class` / `cls_name`).
- **Autoload-Zugriff auf externe Klassen zur Parse-Zeit**: `_settings`
  wurde in `python_bridge.gd` mit `PythonBridgeConfig.DEFAULTS`
  initialisiert; jetzt lazy in `_init()`. Default-Parameter
  `PythonBridgeConfig.DEFAULT_INSTANCE` in `wrapper_generator.gd`
  ersetzt durch Runtime-Auflösung.
- **`python_editor.gd`**: `Engine.get_main_loop().root` funktioniert nicht
  (MainLoop hat kein `root`) - jetzt `is SceneTree`-Check.
- **`wrapper_generator.gd`**: `_class_name_for()` erzeugt jetzt gültige
  PascalCase-Identifiers (Separatoren wie `-`/`_` werden als
  Wortgrenzen behandelt: `mein_skript` -> `PyBridgeMeinSkript`).
- **`protocol.gd`**: `build_frame()` akzeptiert optional extern
  gesammelte Chunks und re-encodiert bereits getaggte Werte nicht mehr
  (Binary-Frame-Roundtrip funktionierte nicht für vor-encodierte Daten).
- **`task_manager.gd`**: Retry-Delay nutzt konsistent den übergebenen
  `now_ms` statt Wall-Clock (`Time.get_ticks_msec`) - Timeout/Retry-
  Logik ist damit deterministisch und testbar.

### Tests

- GDScript-Headless-Suite läuft jetzt erstmals real: **34 Tests / 99
  Assertions grün** (`godot --headless --script
  res://tests/gdscript/run_tests.gd`). Fixes im Runner (RefCounted-free,
  Typannotationen), in `test_serializer_protocol.gd` (Variant-Warnungen)
  und `test_task_layer.gd` (Batch-/Retry-Erwartungen).
- Optionaler E2E-Test `tests/gdscript/e2e_live.gd` (Autoload -> echter
  Python-Subprozess -> Task): erfordert natives Godot (Flatpak-Sandbox
  entzieht Subprozessen den venv-Zugriff).
- Python-Suite weiterhin **33/33 grün**.

## v0.2.0

Grundlegender Ausbau der v0.1.0-Bridge auf den vollen Funktionsumfang des
Master-Prompts. Protokoll v2.

### Neue Komponenten (Godot)

- `core/config.gd` — zentrale Konfiguration (Version-Floors Godot 4.2+ /
  Python 3.8+, alle Tunables) mit Typ-Koerzion.
- `core/error_handler.gd` — Fehler-Taxonomie mit 9 Kategorien und Mapping
  auf die Legacy-Status.
- `core/type_mapper.gd` — explizite `$pb`-Tag-Tabelle + Registry für
  benutzerdefinierte Typen (Serializer delegiert automatisch).
- `core/task.gd` — Task-Zustandsmaschine (QUEUED/RUNNING/COMPLETED/FAILED/
  CANCELLED/TIMEOUT), Prioritaet, Timeout, Batchable-Flag.
- `core/task_manager.gd` — Priority-Queue (stabil), Backpressure
  (max_queued_tasks, max_payload_bytes), Cancel, Retry-Policy, Batch-Fenster
  (max_batch_size/max_batch_delay_ms, Preemption, Reihenfolge), Auto-/Explicit-
  Instanz-Zuordnung.
- `core/scheduler.gd` — Frame-Sync: max_dispatch_per_frame,
  max_inflight_per_instance, bounded Inbox mit max_results_per_frame,
  Backlog-Throttling, Timeout-Check mit best-effort CANCEL, Crash-Hook.
- `core/process_manager.gd` — nicht-blockierender Prozess-Start, Running-/
  Exit-Code-Check, Force-Kill (ersetzt `process_thread.gd`).
- `core/connection_manager.gd` — WebSocket-Wrapper mit Ping/Pong-Timing
  (ersetzt `ws_client.gd`).
- `core/health_monitor.gd` — Ping-Kadenz, Missed-Pong-Zaehler, Health-State.

### Geaenderte Komponenten

- `core/bridge_instance.gd` — komplette Ueberarbeitung: Crash-Erkennung
  (WS-Close + Subprozess-Ende), Exponential-Backoff-Restart mit
  Stable-Uptime-Reset, Graceful Shutdown (shutdown_ack/Timeout/Force-Kill),
  Zombie-Praevention, leitet Task-Ergebnisse an den Scheduler weiter.
- `core/provisioner.gd` — Dependency-Verifikation per Import-Check nach pip.
- `core/python_bridge.gd` — Facade besitzt jetzt TaskManager/Scheduler;
  neue Task-API (submit_task/cancel_task/get_task), Hot-Reload-Trigger,
  Introspection (AST), shutdown()/shutdown_now().
- `core/protocol.gd` — Protokoll v2 mit explizitem Nachrichten-Set und
  Batch-Item-Kodierung.
- `core/serializer.gd` — delegiert unbekannte Tags an die TypeMapper-Registry.
- `core/result.gd` — strukturierte Fehler mit `code`, `task_id`,
  `instance_id`; `cancelled()`-Helper.

### Neue Komponenten (Python)

- `introspection.py` — AST-basierte Funktions-Signatur-Analyse (fuehrt nie
  Code aus) als Basis der Wrapper-Generierung.
- `server.py` (v2) — Routing fuer task/batch/cancel/reload/introspect/
  shutdown; Nutzer-Code laeuft in genau einem Worker-Thread pro Instanz
  (Event-Loop bleibt reaktionsfaehig), Timeout via asyncio.wait_for,
  Watchdog beendet den Prozess nach Shutdown/Verbindungsabbruch.
- `executor.py` — define/run/call mit Source-Hash pro Kontext (call
  re-definiert nur bei Aenderung), reload_context, stdout/stderr-Capture.
- `protocol.py` — v2-Nachrichtentypen, Batch-Item-Dekodierung.
- `__init__.py` — Version 0.2.0.

### Editor

- `editor/python_editor.gd` — Dock-Panel (Dateiliste, CodeEdit, Save/Run/
  Wrapper/Hot-Reload, Log, mtime-Watcher).
- `editor/python_syntax_highlighter.gd` — Python-Highlighting.
- `editor/wrapper_generator.gd` — deterministische GDScript-Generierung,
  Marker-sicheres Ueberschreiben, class_name-Kollisions-Check.
- `plugin.gd` — registriert Autoload + Dock.

### Entfernt

- `core/pending_request.gd`, `core/process_thread.gd`, `core/ws_client.gd`
  (durch Task/ProcessManager/ConnectionManager ersetzt).

### Tests

- Python-`unittest`-Suite (33 Tests, gruen): Protocol, Serializer,
  Executor, Introspection, Server-Integration (echter Subprozess + WS).
- GDScript-Headless-Testrunner (`godot --headless --script
  res://tests/gdscript/run_tests.gd`): Core-Units, Serializer/Protocol,
  Task-Layer, Wrapper-Generator.

## v0.1.0 (Baseline)

Importierte Ausgangsbasis aus `python_bridge_addon.zip`: BridgeInstance,
BridgeProvisioner, BridgeWsClient, BridgeProcess, PythonProtocol (v1),
PythonBridgeSerializer, Python-Server (hello/execute/ping/shutdown),
Editor-Plugin mit Autoload-Registrierung, Dokumentations-PDF.