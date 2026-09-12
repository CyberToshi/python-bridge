# Projekte, Cython und automatische Builds

Der Worker fuehrt **jede** Python-Aufgabe selbst vorbereitet aus. Der Benutzer
muss dafuer niemals `pip`, `cython`, `setup.py` oder einen Compiler aufrufen -
das ist die zentrale Zusage der V1 (Plug & Play).

```text
Datei/Projekt waehlen  ->  Start  ->  fertig
```

Alles dazwischen macht der Worker:

```text
.py / Projektdateien
        │
        ├─ braucht nichts?          -> direkt ausfuehren
        ├─ requirements.txt?        -> isolierte Umgebung + automatisch installieren
        └─ .pyx / setup.py?         -> Cython + Compiler bereitstellen, kompilieren,
                                       Ergebnis ausfuehren, Build zwischenspeichern
```

## Was automatisch erkannt wird

Beim Start (und bei jeder Aufgabe) erkennt der Worker:

| Was | Wie | Konsequenz |
|---|---|---|
| Python-Version | `sys.version_info` | Teil des Build-Fingerabdrucks |
| Betriebssystem / Architektur | `sys.platform`, `platform.machine()` | Teil des Build-Fingerabdrucks |
| pip / venv verfügbar | Import-Test | sonst klarer Hinweis statt Absturz |
| C-Compiler | `cc`, `gcc`, `clang`, `cl`, `tcc` im PATH + `sysconfig` | noetig nur fuer Builds |
| Paketbedarf | `requirements.txt` im Projekt | wird automatisch installiert |
| Build-Noetigkeit | `.pyx`/`.pxd` oder `setup.py`/`pyproject.toml` | loest den Build aus |

Nachsehen kann man das jederzeit ohne Terminal:

* in der **Worker-App**: Knopf **„Umgebung prüfen“**
* auf der Kommandozeile: `python orchestrator_worker.py --diagnose`

## Wo alles landet (nichts wird am System geaendert)

```text
<cache>/                     Standard: ~/.cache/python_bridge_worker (Linux)
├── envs/<key>/              isolierte venv + Cython/setuptools
└── projects/<key>/          Projektdateien + kompilierte Artefakte
```

* `<cache>` ist per `--cache-dir` bzw. `PYTHON_BRIDGE_WORKER_CACHE` umstellbar.
* Es wird **keine** System-Python-Installation veraendert und **kein**
  Administratorrecht vorausgesetzt.
* Arbeiten finden im Cache statt; **jeder Task laeuft zusaetzlich in einem
  eigenen temporaeren Arbeitsverzeichnis**, das danach geloescht wird.
* Der Cache wird beim Start automatisch aufgeraeumt (Standard: max. 64
  Projekte, aelter als 14 Tage fliegen raus).

## Build-Cache

Ein Projekt wird nur dann neu gebaut, wenn sich etwas Relevantes aendert. In den
Fingerabdruck (`key`) gehen ein:

* Inhalt und Namen aller Projektdateien (also auch jede Aenderung an `.pyx`),
* die Requirements,
* Python-Version, Implementierung, Plattform, Architektur,
* die Version der Buildlogik (`BUILD_SCHEMA`).

Gleicher Fingerabdruck → kein zweiter Compiler-Lauf:

```text
Task starten -> vorhandener Build -> sofort ausfuehren
Aenderung     -> neuer Fingerabdruck -> automatisch neu bauen
```

Sichtbar ist das im Manager in der Spalte **Build** (`neu gebaut` / `Cache`)
sowie im Ereignisprotokoll.

## Cython konkret

Fuer ein Projekt mit `fast.pyx` passiert Folgendes, ohne dass jemand etwas
eintragen muss:

1. `.pyx` erkannt → Build wird geplant.
2. Umgebung: venv anlegen (falls noetig) und `cython`, `setuptools`, `wheel`
   installieren.
3. Compiler pruefen.
4. Wenn das Projekt ein eigenes `setup.py` hat, wird es benutzt; sonst erzeugt
   der Worker ein minimales Build-Skript mit `cythonize(...)`.
5. `python setup.py build_ext --inplace` im Projektordner.
6. Pruefen, ob wirklich eine Erweiterung entstanden ist (sonst klarer Fehler).
7. Einstiegsdatei ausfuehren - `import fast` findet die kompilierte Erweiterung.
8. Cache-Marker setzen.

Unterstuetzte Ausfuehrungsarten (wie bei der bestehenden Bridge):

* **run**: Einstiegsdatei wird als `__main__` gestartet, `input` ist vorbelegt,
  eine globale Variable `result` wird zurueckgemeldet.
* **call**: Einstiegsdatei wird als Modul geladen, die genannte Funktion wird mit
  `args`/`kwargs` aufgerufen, der Rueckgabewert wird zurueckgemeldet.

## Wenn etwas fehlt

Der Worker schickt zu jedem Fehler **Kurzbeschreibung + Loesungshinweis** mit
(im Manager als Tooltip an der Aufgabe und im Protokoll):

| Situation | Meldung / Hinweis |
|---|---|
| Kein C-Compiler | „Kein C-Compiler gefunden…“ - Windows: Microsoft C++ Build Tools, Linux: `build-essential`/`gcc`. Danach Aufgabe einfach erneut starten. |
| Paket fehlt (`ModuleNotFoundError`) | „…in eine requirements.txt schreiben - der Worker installiert es beim naechsten Start automatisch.“ |
| Build schlaegt fehl | Compiler-Ausgabe steckt im Feld `stderr` der Aufgabe. |
| Kein Netz fuer pip | Klarer Hinweis auf Internet/Proxy; die Pakete landen im Worker-Cache, nicht im System. |
| Kein venv-Modul | Hinweis auf `python3-venv` bzw. Python-Installation reparieren; bis dahin nutzt der Worker sein eigenes Python. |

## Grenzen (bewusst)

* **Kein Compiler-Auto-Install.** Ein C-Compiler laesst sich ohne Adminrechte
  nicht zuverlaessig installieren; darum gibt es hier einen klaren Hinweis
  statt eines halben Versuchs.
* **Keine Wheel-Build-Isolation fuer fremde Projekte** - es wird `setup.py`
  bzw. ein erzeugtes Build-Skript verwendet.
* **Kein Datei-Transfer fuer grosse Eingabedaten.** Uebertragen wird der
  Quelltext (Limit 3 MB pro Auftrag); grosse Daten folgen mit der
  File-Registry/Chunk-Uebertragung.

## Tests

```bash
# Kompletter Worker-Weg inkl. echtem Cython-Build, Cache, Rebuild, Fehler:
python_bridge/venv/bin/python tests/orchestrator/test_worker_project.py

# Nur mit frischem Cache (erzwingt echte Builds, dauert laenger):
python_bridge/venv/bin/python tests/orchestrator/test_worker_project.py --fresh

# Ueber Manager+Worker (Discovery, Fortschritt, Build-Infos):
bash tests/orchestrator/run_cluster_e2e.sh
```
