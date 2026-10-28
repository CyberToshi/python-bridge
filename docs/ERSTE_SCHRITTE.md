# Python Bridge für Godot 4 — von Null auf

**Addon-Version:** 0.5.0
**Stand:** 28. Oktober 2026
**Verifiziert mit:** Godot 4.6- und 4.7-stable (Windows 11), Python 3.13.17.
**Verbindlich:** Diese Seite ist die Einstiegs-Anleitung. Wenn ein anderes
Dokument abweicht, gilt diese Seite (Begründung: [Versionsklarheit](#12-versionsklarheit)).

Nach dieser Anleitung läuft in **15 Minuten** ein Python-Aufruf aus GDScript,
ohne dass du Python-Pakete global installieren oder einen Server starten musst.

---

## Inhalt

1. [Was die Bridge ist — und was nicht](#1-was-die-bridge-ist--und-was-nicht)
2. [Voraussetzungen](#2-voraussetzungen)
3. [Installation in 5 Schritten](#3-installation-in-5-schritten)
4. [Skript-Typ 1: temporärer Code (ohne Datei)](#4-skript-typ-1-temporärer-code-ohne-datei)
5. [Skript-Typ 2: persistente Python-Dateien](#5-skript-typ-2-persistente-python-dateien)
6. [Das Editor-Dock](#6-das-editor-dock)
7. [Dateien löschen — rückstandsfrei](#7-dateien-löschen--rückstandsfrei)
8. [Projektstruktur und Git](#8-projektstruktur-und-git)
9. [Konfiguration](#9-konfiguration)
10. [Export und Browser (Kurzfassung)](#10-export-und-browser-kurzfassung)
11. [Fehlerbehebung](#11-fehlerbehebung)
12. [Versionsklarheit](#12-versionsklarheit)

---

## 1. Was die Bridge ist — und was nicht

Die Bridge startet einen **lokalen Python-Prozess** und verbindet ihn per
WebSocket mit Godot. Godot bleibt der Host (Frames, Szenen, UI), Python bleibt
echter Python (Module, numpy, pandas, …). Es gibt **keine** Python-Syntax in
GDScript und **kein** Godot-API in Python — nur Funktionsaufrufe zwischen beiden
Seiten.

Zwei Arten von Python-Code werden unterstützt. Das ist die wichtigste
Unterscheidung dieses Addons:

| | **Temporär (Skript-Typ 1)** | **Persistent (Skript-Typ 2)** |
|---|---|---|
| Wo der Code liegt | String in GDScript bzw. ungespeicherter Tab im Dock | echte Datei `res://python_bridge/scripts/<id>.py` |
| Aufruf | `PythonBridge.execute(code)` | `execute_script` / `call_script` / `define_script` |
| Lebensdauer | ein Aufruf, danach weg | bleibt auf der Festplatte, versionierbar |
| Kontext | frischer Kontext pro Aufruf (`temp-1`, `temp-2`, …) | fester Kontext pro Datei, Modul-State bleibt |
| Gedacht für | Ausprobieren, Einzeiler, Debug-Snippets, Editor-Scratch-Tabs | alles, was im Projekt bleiben soll |

Beides läuft über dieselbe Instanz, dieselbe Fehlerbehandlung und dieselbe
Rückgabe (`PythonBridgeResult`).

> **Architektur-Invariante:** Python wartet nie auf einen Godot-Frame, und
> Godot wartet nie auf Python. Ein Python-Call ist immer ein Task, den Godot
> awaiten kann (oder auch nicht).

---

## 2. Voraussetzungen

| Komponente | Anforderung | Anmerkung |
|---|---|---|
| **Godot** | 4.2 oder neuer | Dieses Release ist mit **Godot 4.7-stable** verifiziert. Ab Godot 4.5 hat das Editor-Dock einen Schließen-Button am Tab; auf 4.2–4.4 schließt `Strg+W`. |
| **Python** | 3.8 oder neuer | Getestet mit 3.13. **Kein** globales `pip install` nötig. |
| **Betriebssystem** | Windows, Linux, macOS | Desktop-Transport = lokaler Prozess. Browser = Pyodide (siehe §10). |
| **Rechte** | normale Benutzerrechte | Es wird nichts systemweit installiert. |

Die Bridge legt beim ersten Start eine **eigene venv** unter
`res://python_bridge/venv/` an und installiert dort `websockets>=11`
(und später bei Bedarf Build-Pakete für Cython). Dein System-Python bleibt
unangetastet.

Prüfen, ob Python gefunden wird:

```bash
python --version      # Windows
python3 --version     # Linux/macOS
```

Wird Python nicht gefunden, setzt du den Pfad später explizit (§9).

---

## 3. Installation in 5 Schritten

### Schritt 1 — Addon ins Projekt kopieren

Der Ordner **`addons/python_bridge/`** muss im **Projektwurzelverzeichnis**
liegen, also unter `res://addons/python_bridge/`:

```
mein_projekt/
├── project.godot
└── addons/
    └── python_bridge/
        ├── plugin.cfg
        ├── plugin.gd
        ├── core/
        ├── editor/
        └── python/
```

Quellen: Release-ZIP (`python_bridge_addon.zip`) entpacken **oder** das Repo
klonen und `addons/python_bridge/` kopieren. Es darf **nicht** zusätzlich ein
zweiter `addons`-Ordner entstehen (z. B. `addons/python_bridge/addons/...`) —
das ist der häufigste Installationsfehler.

### Schritt 2 — Projekt einmal in Godot öffnen

Godot scannt das Dateisystem und findet das Addon. Erst danach erscheint es in
den Projekt-Einstellungen.

### Schritt 3 — Plugin aktivieren

**Projekt → Projekt-Einstellungen … → Reiter „Plugins“ → Python Bridge →
Haken bei „Aktivieren“.**

Dabei passiert automatisch zwei Dinge:

1. Der Autoload **`PythonBridge`** wird registriert
   (`res://addons/python_bridge/core/python_bridge.gd`).
2. Das Dock **„Python Bridge“** erscheint in der rechten Dock-Leiste
   (`DOCK_SLOT_RIGHT_UL`, neben dem FileSystem-Dock).

Manuell (falls du den Autoload lieber selbst verwaltest):
**Projekt-Einstellungen → Autoload** → Pfad
`res://addons/python_bridge/core/python_bridge.gd`, Name `PythonBridge`,
Haken bei „Globaler Zugriff“/„Aktiviert“. Das Plugin entfernt einen selbst
angelegten Autoload beim Deaktivieren **nicht**.

### Schritt 4 — Ersten Aufruf starten

Autoload-Skript `main.gd` an einen Node hängen und ausführen (F5):

```gdscript
extends Node

func _ready() -> void:
    # Erster Start: venv einrichten + Python-Prozess starten.
    var started := await PythonBridge.start_instance("default")
    if not started.is_ok():
        push_error("Python-Start fehlgeschlagen: " + started.error_message())
        return

    var r := await PythonBridge.execute("result = input['a'] + input['b']", {"a": 40, "b": 2})
    print(r.value)   # 42
```

Der **erste** `start_instance()` dauert 1–3 Minuten (venv + `websockets`).
Danach startet die Instanz in unter einer Sekunde. Der Aufruf blockiert den
Godot-Main-Thread nicht — er ist ein `await`.

### Schritt 5 — Erfolg prüfen

- Im Output erscheint `42`.
- Im Dock „Python Bridge“ steht rechts oben **`Python: ready`**.
- Unter `res://python_bridge/` existieren `venv/`, `scripts/`, `tmp/`, `bridge/`.

Wenn einer der Punkte fehlt: [Fehlerbehebung](#11-fehlerbehebung).

---

## 4. Skript-Typ 1: temporärer Code (ohne Datei)

Für Wegwerf-Code gibt es `PythonBridge.execute()`. Der Code wird als String
übergeben und **nirgendwo gespeichert**:

```gdscript
# Konvention: Variable `input` hinein, Ergebnis in `result` zurück.
var r := await PythonBridge.execute(
    """
import math
result = [math.sqrt(input['n'] + i) for i in range(3)]
""",
    {"n": 10}
)
print(r.value)          # [3.16..., 3.31..., 3.46...]
```

Eigenschaften:

- **Kein Kontext-Gedächtnis:** jeder `execute()`-Aufruf bekommt einen frischen
  Kontext. Variablen aus dem vorherigen Aufruf existieren nicht mehr.
- **Kein Dateisystem-Eintrag:** nichts in `scripts/`, nichts in Git.
- **Identische Infrastruktur:** Timeout, Fehlerobjekt, `stdout`/`stderr` in
  `result.meta` wie bei persistenten Skripten.

Im Editor-Dock entspricht das dem **temporären Tab** (§6): Code tippen, `Strg+Enter` —
der Buffer wird direkt ausgeführt, ohne gespeichert zu werden. Erst `Strg+S`
macht daraus eine Datei (Skript-Typ 2).

**Wann welcher Typ?** Solange du nicht willst, dass der Code im Projekt bleibt:
temporär. Sobald du ihn wiederverwenden, versionieren oder per `call_script`
als Funktion aufrufen willst: persistent.

---

## 5. Skript-Typ 2: persistente Python-Dateien

### 5.1 Datei anlegen

```gdscript
PythonBridge.create_script(
    "rechner",
    """
def calc(a, b):
    return a * b
""")
```

Die Datei liegt anschließend unter
`res://python_bridge/scripts/rechner.py` (Rückgabe: `{"path": ...}`).

Regeln für **neue** Ids (gilt für Anlegen/Umbenennen im Dock und in der API):

- Buchstaben, Ziffern und `_`; erstes Zeichen Buchstabe oder `_`
- keine Pfadanteile (`/`, `\`, `..`), keine Endung im Namen
- max. 64 Zeichen
- Prüfung vorab: `PythonBridge.validate_script_id("mein_modul")` → `""` = ok

Bestehende Dateien mit anderen Namen (z. B. `alt-test.py`) bleiben lesbar und
löschbar; die Regel gilt nur für neues Material.

### 5.2 Datei ausführen (Skript-Stil)

```gdscript
# `input` hinein, `result` zurück — wie execute(), aber dauerhaft.
var r := await PythonBridge.execute_script("rechner", {"x": 3})
```

### 5.3 Funktion aufrufen (der Normalfall)

```gdscript
var r := await PythonBridge.call_script("rechner", "calc", [6, 7])
if r.is_ok():
    print(r.value)        # 42
else:
    print(r.status, r.error_message())
```

`call_script` ruft eine benannte Funktion auf. Der Kontext bleibt bestehen:
Modul-State (Caches, geladene Modelle, Zähler) überlebt zwischen Aufrufen. Die
Datei wird nur neu ausgeführt, wenn sich ihr Inhalt geändert hat
(Source-Hash-Vergleich).

### 5.4 Kontext vorab definieren

```gdscript
await PythonBridge.define_script("rechner")   # lädt/definiert ohne Aufruf
```

Nützlich, um Ladezeit vor dem ersten echten Call zu legen.

### 5.5 Optionale Argumente

Alle vier Aufrufe akzeptieren optional `instance` (Standard `"default"`) und
bei `execute*`/`define_script` zusätzlich `timeout_sec`:

```gdscript
var r := await PythonBridge.call_script("rechner", "calc", [1, 2], {}, "worker", 10.0)
```

### 5.6 Was ist mit `.pyx` (Cython)?

`.pyx`-Dateien sind eine **optionale** Beschleunigung für Desktop-Builds. Sie
werden kompiliert und dann wie ein Modul **importiert** — deshalb:

- `execute_script`/`define_script` funktionieren für `.pyx` **nicht** (klare
  Fehlermeldung statt kryptischem SyntaxError).
- Aufruf über `call_script(...)` oder den generierten GDScript-Wrapper.
- Web-Export: nicht unterstützt (Pyodide hat keinen C-Compiler).
- Ein Skript existiert **nie** gleichzeitig als `.py` und `.pyx` — das Dock
  entfernt beim Umschalten die jeweils andere Datei.

Für den Einstieg ist Cython nicht nötig. Siehe `docs/` und den
`⋯`-Menüpunkt „Cython kompilieren“ im Dock.

**Compiler-Voraussetzung (einmalig):** Der Build braucht einen C-Compiler.
Die Bridge probiert die üblichen Wege selbst durch:

| Plattform | Wird probiert | Wenn nichts da ist |
|---|---|---|
| Windows | MSVC (Visual Studio Build Tools) → MinGW-w64 (`gcc` im PATH) | klare Meldung mit Installations-Hinweis |
| Linux/macOS | `gcc`/`cc`/`clang` → `ziglang` (wird bei Bedarf nachinstalliert) | klare Meldung |

`Cython` und `setuptools` installiert das Build-Tool selbst in die Bridge-venv.
Nach jedem Speichern einer `.pyx` erkennt der nächste `call_script` die
Änderung (Hash-Vergleich) und baut inkrementell nach — ohne manuellen Schritt.

---

## 6. Das Editor-Dock

Godots eigener Skript-Editor kann nur GDScript/C#. Für Python gibt es das Dock
**„Python Bridge“** (rechts oben). Es ist bewusst schlank gehalten.

```
┌──────────────────────────────────────────────────────────────────────┐
│  +   💾   ▶      rechner.py · gespeichert        Python: ready   ⋯   │  Toolbar
├────────────┬─────────────────────────────────────────────────────────┤
│ Filtern …  │  rechner.py × │ Scratch 1 │                             │  Tabs
│ rechner    ├─────────────────────────────────────────────────────────┤
│ utils      │   1  def calc(a, b):                                    │
│ math_ops   │   2      return a * b                                   │
│            │                                                         │
├────────────┴─────────────────────────────────────────────────────────┤
│ log: ok: 42                                                          │
└──────────────────────────────────────────────────────────────────────┘
```

### 6.1 Tabs

- **Ein Tab pro Datei**, jeder mit eigener Undo-Historie und eigenem
  Python-Highlighting.
- **`●` vor dem Namen** = ungespeicherte Änderungen (verschwindet wieder, wenn
  du zum gespeicherten Stand zurück-undoest).
- **Schließen:** `×` am aktiven Tab, Mittelklick auf den Tab oder `Strg+W`.
  Bei ungespeicherten Änderungen fragt das Dock:
  *Speichern & schließen* / *Verwerfen* / *Abbrechen*.
- **Tabs verschieben:** per Drag & Drop.
- **Externe Änderungen** (VS Code o. Ä.) werden automatisch neu geladen —
  **außer** der Tab hat ungespeicherte Änderungen; dann erscheint nur ein
  Hinweis im Log und dein Text bleibt unangetastet.

### 6.2 Zwei Tab-Arten

| Tab | Angelegt über | Speichern (`Strg+S`) | Ausführen (`Strg+Enter`) |
|---|---|---|---|
| **Datei** (`rechner.py`) | `+ → Neue Datei …` oder Klick in der Liste | schreibt die Datei sofort | speichert zuerst, dann `execute_script` |
| **Temporär** (`Scratch 1`) | `+ → Temporäres Skript` | fragt nach Dateinamen → wird zur Datei | führt den Buffer ohne Speichern aus (`execute`) |

Ein temporärer Tab existiert **nur im Speicher**: schließt du den Editor ohne
zu speichern, ist er weg. Genau dafür ist er gedacht.

### 6.3 Toolbar

| Element | Funktion |
|---|---|
| **`+`** | Menü: „Neue Datei …“ / „Temporäres Skript“ |
| **💾 Speichern** | aktiven Tab speichern (bei Scratch: „Speichern unter …“) |
| **▶ Ausführen** | aktiven Tab ausführen; startet bei Bedarf automatisch die Python-Instanz |
| **Status** | aktuelle Datei + Änderungszustand (bzw. letzte Aktion) |
| **`Python: …`** | Instanz-Status (`ready`, `nicht gestartet`, `starting`, …) |
| **`⋯`** | Wrapper generieren · Hot Reload · *Als Cython-Modul speichern (.pyx)* · Cython kompilieren · **Umbenennen …** · **Löschen …** · Log leeren · **Einstellungen …** |

### 6.4 Skriptliste (links)

- **Klick** öffnet die Datei im Tab.
- **`Filtern …`** filtert nach Namen.
- **Rechtsklick** → *Öffnen* / *Umbenennen …* / *Löschen …*
- `.pyx`-Dateien sind mit `·pyx` markiert.
- Die Liste aktualisiert sich automatisch (nach jeder Aktion und im
  Hintergrund), ein manueller Refresh ist nicht nötig.

### 6.5 Kurzbefehle

Die Shortcuts gelten **nur, wenn der Fokus im Dock liegt** — `Strg+S` im
GDScript-Editor bleibt also Godots eigenes Speichern. `F5`/`F6` bleiben
dem Godot-Projekt vorbehalten; das Dock nutzt `Strg+Enter` zum Ausführen.

| Shortcut | Aktion |
|---|---|
| `Strg+N` | Neue Datei (Dialog) |
| `Strg+S` | Speichern (Scratch: „Speichern unter …“) |
| `Strg+W` | Aktiven Tab schließen |
| `Strg+Enter` | Aktiven Tab ausführen |

### 6.6 GDScript-Wrapper erzeugen

`⋯ → GDScript-Wrapper generieren` liest die Funktionen des Skripts
(Introspection) und schreibt `res://python_bridge/wrappers/<id>_wrapper.gd`:

```gdscript
var w := PyBridgeRechner.new()
var r := await w.calc(6, 7)      # -> PythonBridgeResult
```

Die Datei trägt einen Marker-Header. Manuell geschriebene Dateien werden
**nie** überschrieben — nur generierte.

### 6.7 Hot Reload

`⋯ → Hot Reload` definiert den Kontext der Instanz neu, ohne den Prozess zu
starten. Ob Änderungen automatisch übernommen werden, steuert
`hot_reload_mode` (§9). Nach dem Speichern über das Dock ist der
Skript-Cache ohnehin invalidiert.

Bei `.pyx` gibt es keinen Source-Reload (rohes Cython ist nicht ausführbar):
Hot Reload verwirft hier das kompilierte Modul, der nächste `call_script`
baut bei geänderter Quelle neu und importiert frisch.

### 6.8 Einstellungen aus dem Dock

`⋯ → Einstellungen …` öffnet dieselben Felder wie
*Projekt → Projekteinstellungen → Python Bridge* (§9.1).

- **Speichern** schreibt nach `project.godot` und liest die Konfiguration neu.
- **Speichern & neu starten** macht das zusätzlich und startet die
  Python-Instanz neu — der einzige Weg, wie geänderte Einstellungen sofort
  wirken.

### 6.9 Weg ohne Dock: das Werkzeuge-Menü

Damit die Funktionen nicht im Dock-Tab versteckt sind, liegt unter
**Projekt → Werkzeuge** (bzw. *Tools*) zusätzlich:

| Menüpunkt | Wirkung |
|---|---|
| `Python Bridge: Dock anzeigen` | holt das Dock nach vorn |
| `Python Bridge: Neue Datei …` | gleicher Dialog wie `+ → Neue Datei …` |
| `Python Bridge: Einstellungen …` | öffnet den Einstellungs-Dialog |
| `Python Bridge: Instanz starten` | startet die Default-Instanz (inkl. venv-Setup) |
| `Python Bridge: Instanz stoppen` | beendet den Python-Prozess sauber |
| `Python Bridge: Cython kompilieren` | inkrementeller `.pyx`-Build |

---

## 7. Dateien löschen — rückstandsfrei

Ein Python-Skript hinterlässt mehr als eine Datei. Deshalb entfernt Löschen
**alle** zugehörigen Artefakte — und nichts anderes:

| Artefakt | Warum es existiert |
|---|---|
| `scripts/<id>.py` bzw. `<id>.pyx` | die Quelle |
| `scripts/<id>.py.uid` | Godot-UID-Sidecar (falls angelegt) |
| `scripts/<id>.c` | Cython-Zwischenstand |
| `scripts/<id>.*.pyd`, `<id>.*.so` | kompiliertes Cython-Modul |
| `scripts/__pycache__/<id>.*.pyc`, `scripts/<id>.pyc` | Bytecode-Cache |
| `scripts/cython_build_tmp/**/<id>.*` | Compiler-Zwischendateien |
| `.cython_state.json` → Eintrag `<id>` | Build-Hash des Moduls |
| `wrappers/<id>_wrapper.gd` (+ `.uid`) | generierter GDScript-Wrapper |

Leere Hilfsordner (`__pycache__`, `cython_build_tmp`) werden mit entfernt.
**Nicht** angetastet werden: andere Skripte, `venv/`, `config/dependencies.txt`.

### Im Dock

Rechtsklick in der Liste → **Löschen …** (oder `⋯ → Löschen …`). Der Dialog
listet auf, was entfernt wird; ungespeicherte Änderungen im offenen Tab werden
ausdrücklich gewarnt. Löschen ist **endgültig** (kein Papierkorb).

### Aus GDScript

```gdscript
var res := PythonBridge.delete_script("rechner")
if res.is_ok():
    var report: Dictionary = res.value
    print(report["removed"])        # Array der gelöschten Pfade
    print(report["existed"])        # false, wenn es die Datei gar nicht gab
else:
    push_error(res.error_message())
```

Rückgabe (`res.value`):

| Feld | Bedeutung |
|---|---|
| `ok` | `true`, wenn nichts übrig blieb |
| `existed` | `false`, wenn es die Datei nicht (mehr) gab — **kein** Fehler |
| `removed` | Array der tatsächlich gelöschten Pfade |
| `failed` | Array `{path, error}` für Dateien, die nicht löschbar waren (z. B. gesperrt) |
| `cython_state_cleared` | ob ein Build-Hash-Eintrag entfernt wurde |

Nützlich für Aufräum-Skripte und Tests:

```gdscript
for entry in PythonBridge.list_scripts():
    print(entry["id"], entry["ext"])
```

---

## 8. Projektstruktur und Git

```
res://python_bridge/            (Standard-Workspace, konfigurierbar)
├── scripts/                    deine Python-Dateien + Build-Artefakte
├── wrappers/                   generierte GDScript-Wrapper
├── config/
│   └── dependencies.txt        deklarierte Pakete (eine Zeile pro Paket)
├── venv/                       automatisch provisioniert (nicht versionieren!)
├── tmp/                        Laufzeit-Temporärdateien
└── bridge/                     Kopie der Python-Runtime im Workspace
```

`.gitignore`-Empfehlung (entspricht dem Repo-Standard):

```gitignore
python_bridge/venv/
python_bridge/tmp/
python_bridge/bridge/
python_bridge/__pycache__/
*.pyc
```

`scripts/` bewusst **nicht** ignorieren, wenn die Python-Dateien zum Projekt
gehören — sie sind Quellcode. Nur Build-Ausgaben (`*.c`, `*.so`, `*.pyd`,
`__pycache__/`) sollten draußen bleiben.

Im **Export** ist `res://` schreibgeschützt; die Bridge legt den Workspace
dann automatisch unter `user://python_bridge` an und seedet ihn aus dem PCK.
Deshalb immer `PythonBridge.workspace_dir()` verwenden statt Pfade
hartzukodieren.

---

## 9. Konfiguration — automatisch oder manuell

**Du musst nichts einstellen.** Ohne jede Konfiguration sucht die Bridge ein
Python › 3.8, legt im Workspace eine eigene `venv/` an, installiert dort
`websockets` plus deine deklarierten Pakete und startet den Prozess. Wer
nichts anfasst, bekommt immer diesen Automatik-Pfad.

Wenn du eingreifen **willst**, gibt es vier gleichwertige Wege. Alle landen in
derselben Konfiguration (siehe „Praezedenz“ unten):

### 9.1 Manuell im Editor (empfohlen, kein Code)

1. **Projekt → Projekteinstellungen → Python Bridge.** Dort liegen alle
   Einstellungen als normale Projekt-Einstellungen; sie werden in
   `project.godot` gespeichert und sind damit versionierbar.
2. **Oder im Dock:** `⋯ → Einstellungen …` — gleiche Felder, ohne durch das
   Projektfenster zu navigieren. Mit **„Speichern & neu starten“** werden Werte
   geschrieben *und* die Python-Instanz neu gestartet, damit sie sofort gelten.

| Einstellung | Default | Wirkung |
|---|---|---|
| `python_bridge/general/autostart` | `false` | Python automatisch starten (Editor und Spiel) |
| `python_bridge/general/workspace_dir` | `res://python_bridge` | Ort für `scripts/`, `venv/`, `config/` |
| `python_bridge/general/python_executable` | `""` | leer = automatische Suche; sonst absoluter Pfad zum Interpreter |
| `python_bridge/general/dependencies` | `""` | Komma-getrennte Pakete, z. B. `numpy,scipy>=1.10` |
| `python_bridge/general/hot_reload_mode` | `reload_context` | `none` / `reload_context` / `restart_instance` |
| `python_bridge/general/auto_generate_wrappers` | `false` | GDScript-Wrapper automatisch erzeugen |
| `python_bridge/web/packages` | `numpy,scipy,pandas` | Pyodide-Pakete für den Web-Export |

Nur der Interpreter ist ein `Datei`-Feld, `workspace_dir` ein `Ordner`-Feld,
`hot_reload_mode` eine Auswahlliste — es gibt nichts zu vertippen.

> Hinweis: Beim ersten Editor-Start schreibt das Addon diese Schlüssel mit
> ihren Defaults in deine Projekt-Einstellungen. Das ist reine Sichtbarkeit:
> die Werte sind danach in der UI editierbar statt unsichtbar.

### 9.2 Manuell per Datei (`config.json`)

Für Teams, CI oder wenn die Einstellungen **nicht** in `project.godot` stehen
sollen: `res://python_bridge/config.json` (im Export entsprechend unter
`user://python_bridge/config.json`).

```json
{
  "python_executable": "C:/Python313/python.exe",
  "dependencies": ["numpy", "pandas>=2.0"],
  "hot_reload_mode": "reload_context",
  "workers_per_instance": 2
}
```

Jeder Schlüssel aus `PythonBridgeConfig.defaults()` ist erlaubt; unbekannte
Schlüssel bleiben erhalten (vorwärtskompatibel). Fehlt die Datei oder ist sie
kein JSON-Objekt, wird sie ignoriert (mit Warnung) — sie ist optional.

### 9.3 Manuell per Code

```gdscript
func _ready() -> void:
    PythonBridge.configure({
        "python_executable": "C:/Python313/python.exe",
        "dependencies": ["numpy", "pandas>=2.0"],
        "hot_reload_mode": "reload_context",
    })
    await PythonBridge.start_instance()
```

`configure()` **ersetzt** die gesamte Konfiguration (kein Merge über mehrere
Aufrufe). Wer nur die Projekt-Einstellungen neu einlesen will, ruft
`PythonBridge.reload_config()` — das liest die Kette unten neu und lässt einen
bereits laufenden Prozess unangetastet.

### 9.4 Praezedenz (was gewinnt)

```
Defaults  <  Projekt-Einstellungen  <  config.json  <  configure() aus Code
```

Die ersten drei Stufen liest die Bridge beim Start (`_enter_tree`).
Einstellungen wirken immer **beim nächsten Start der Instanz**; im Dock gibt
es dafür „Speichern & neu starten“.

### 9.5 Eigene venv oder System-Python?

- **Standard (automatisch):** eigene venv im Workspace. Nichts am System wird
  verändert, kein `sudo`, keine Versionskonflikte.
- **Mit System-Python:** `python_executable` auf den Interpreter setzen und
  dort `websockets` installieren:

  ```bash
  python -m pip install "websockets>=11"
  ```

  Die Bridge erkennt den Interpreter, überspringt die venv und prüft nur, ob
  `websockets` importierbar ist. Weitere Pakete aus `dependencies` installiert
  sie dann per `pip` in *dieses* Python.

Pakete lassen sich auf drei Wegen deklarieren (alle gleichwertig, sie werden
zusammengeführt):

1. **Im Python-Skript** (empfohlen, Single Source of Truth), auf Zeilenanfang:
   ```python
   __bridge_deps__ = ["numpy", "scipy>=1.11"]
   ```
2. **Aus GDScript:** `PythonBridge.register_dependencies(["numpy"])`
3. **Datei:** `res://python_bridge/config/dependencies.txt`

Fehlt ein Paket beim ersten `call_script`, installiert die Bridge es nach bzw.
startet die Instanz einmalig neu.

Vollständige Liste aller Tunables: `addons/python_bridge/core/config.gd`
(`defaults()`).

---

## 10. Export und Browser (Kurzfassung)

- **Windows/Linux/macOS:** Export funktioniert, sofern Python auf dem
  Zielsystem vorhanden ist. Vor dem Export prüfen:

  ```bash
  python3 tools/export_check.py --project . --platform all
  ```

- **Web:** Python läuft über Pyodide (WebAssembly) in einem Web Worker mit
  virtuellem Dateisystem — ohne externen Server, auf normalem Static Hosting.
  Bundle bauen:

  ```bash
  python3 tools/build_web_bundle.py --project . --out build/web_bridge
  python3 tools/export_check.py --project . --platform web
  ```

  Grenzen: kein `OS.create_process`, nur WASM-Wheels, serielle Ausführung,
  kein Cython. Details: `docs/EXPORT.md`, `docs/WEB_RUNTIME.md`.

- Die **Editor-Dock-Oberfläche gibt es nur im Editor**, nicht im laufenden
  Spiel. Im Spiel steuerst du alles über die Autoload-API.

---

## 11. Fehlerbehebung

| Symptom | Ursache | Lösung |
|---|---|---|
| Kein Dock „Python Bridge“ | Plugin nicht aktiviert / Addon im falschen Ordner | `res://addons/python_bridge/plugin.cfg` muss existieren; Projekt-Einstellungen → Plugins → aktivieren; Projekt neu öffnen |
| `PythonBridge` unbekannt | Autoload fehlt | Plugin aktivieren (registriert den Autoload) oder manuell unter Projekt-Einstellungen → Autoload eintragen |
| `python not found` / Start schlägt fehl | Python nicht im `PATH` | `python_executable` auf den absoluten Pfad setzen; unter Windows die Store-Alias-Falle prüfen (`python --version` in der Eingabeaufforderung) |
| Erster Start hängt bei „provisioning“ | `pip` braucht Netz / langsam | 1–3 Minuten sind normal; Log im Dock ansehen; `provision_pip_timeout_ms` erhöhen |
| `Script not found: <id>` | Datei liegt nicht in `scripts/` oder `workspace_dir` wurde geändert | `PythonBridge.resolve_script_path(<id>)` prüfen; im Export ist `res://` schreibgeschützt → `workspace_dir()` verwenden |
| Änderung wird nicht übernommen | veralteter Registry-Cache / Instanz kennt alten Code | im Dock speichern (invalidiert den Cache) oder `await PythonBridge.hot_reload_script(<id>)` |
| Ausführen tut nichts | Instanz nicht bereit / `.pyx` | Status rechts oben prüfen; `.pyx` wird importiert, nicht ausgeführt (§5.6) |
| „Löschen unvollständig“ | Datei von anderem Prozess gesperrt | Editor/Programm schließen, das die Datei hält; Vorgang wiederholen — bereits Gelöschtes wird übersprungen |
| Cython-Build: „Kein C-Compiler verfügbar“ | Windows ohne Build Tools/MinGW, POSIX ohne gcc | Windows: *Visual Studio Build Tools* mit Workload „Desktop development with C++“ **oder** MinGW-w64 mit `gcc` im `PATH`; Linux/macOS: `gcc` installieren (oder `ziglang` zulassen) |
| `.pyx` ruft noch alten Code auf | kompilierte Seite neuer als erwartet | `⋯ → Cython kompilieren` erzwingt den Build; der nächste `call_script` importiert danach frisch |
| Web: im Spiel angelegtes Skript nicht importierbar | Datei fehlte im Pyodide-Workspace | ab v0.5.0 automatisch gespiegelt (`file_op`); Instanz einmal neu starten, dann greift der Puffer |

Statuswerte und Fehlerkategorien im Detail: `docs/TROUBLESHOOTING.md`.

---

## 12. Versionsklarheit

### 12.1 Was gilt in welcher Version

| Version | Kernänderung |
|---|---|
| **0.5.0** | **Web-Sync + Cython lauffähig**: `file_op`-Kanal spiegelt Skripte in den Pyodide-Workspace (mit Puffer, Umbenennen/Löschen wirken überall), das Dock meldet Speichern an die Bridge; Cython baut auf Windows (MSVC → MinGW) und POSIX (gcc → zig), erkennt geänderte `.pyx` per Hash, Modulnamen plattformfest (Windows-Calls repariert); Speichern als `.py` räumt Build-Reste ab. **Einstellungen**: Projekt → Projekteinstellungen → Python Bridge, `⋯ → Einstellungen …` mit „Speichern & neu starten“, Werkzeuge-Menü, optionale `config.json`. Siehe §9. |
| **0.4.0** | **Editor-Dock neu**: Tab-Container mit stabilen Tabs, korrigiertes Syntax-Highlighting (Farb-Reset, gecachter Mehrzeilen-Zustand), fehlerfreies Öffnen/Speichern mit klaren Fehlermeldungen, temporäre Scratch-Tabs, **rückstandsfreies Löschen** (`delete_script`), Umbenennen, Shortcuts. Doku neu als `ERSTE_SCHRITTE.md`. |
| 0.3.3 | `__bridge_deps__`-Erkennung überall (auch `.pyx`), Dependencies im Workspace-Scan |
| 0.3.2 | Cython-Sonderpfad, Export-Skripte, ZIP-Build |
| 0.3.1 | Stabilitäts- und Doku-Fixes |
| 0.3.0 | Web-Transport (Pyodide im Worker), Browser-Host, Web-Bundle-Builder |
| 0.2.1 | Godot-4.7-Kompilierbarkeit, erste lauffähige Headless-Suite |
| 0.2.0 | TaskManager, Scheduler, Batching, Backpressure, Health/Restart, Protokoll v2, Editor-Dock |
| 0.1.0 | Basis: Instanzen, WebSocket, venv, Serialisierung |

Maßgeblich ist `addons/python_bridge/plugin.cfg` (`version="0.5.0"`); die
Historie steht in `docs/CHANGELOG.md`.

### 12.2 Welches Dokument ist aktuell?

| Dokument | Status | Inhalt |
|---|---|---|
| **`docs/ERSTE_SCHRITTE.md`** (diese Seite) | **verbindlich** | Setup von Null, beide Skript-Typen, Dock, Löschen |
| `docs/API.md` | aktuell (0.5.0) | API-Referenz der Facade |
| `docs/CHANGELOG.md` | aktuell | Versionshistorie |
| `docs/TROUBLESHOOTING.md` | aktuell | Statuswerte, Fehlerkategorien |
| `docs/EXPORT.md`, `docs/WEB_RUNTIME.md` | aktuell | Export, Pyodide |
| `docs/DATA_PLANE.md`, `docs/WORKERS.md`, `docs/BOTTLENECKS.md` | aktuell | Deep Dives (DataRefs, Worker, Performance) |
| `docs/PROJECT_STATUS.md` | aktuell | Kompakter Projektstand |
| `docs/INSTALLATION.md` | **historisch** (v0.2.x) | durch diese Seite ersetzt |
| `docs/ARCHITEKTUR.md` | **historisch** (v0.2.0) | Architektur jener Version |
| `docs/ARCHITEKTUR_V3.md` | **Planungsdokument** | teilweise umgesetzt; keine Betriebsanleitung |
| `docs/PythonBridge_Dokumentation.pdf`/`.html`, `docs/step_by_step_guide.html`, `docs/HANDS_ON_CONNECT_GUIDE.md` | **Schnappschüsse älterer Versionen** | nicht verbindlich |
| `docs-site/` | Website | thematisch gepflegt, aber nicht die Referenz |

**Faustregel:** Bei Widersprüchen gilt diese Seite; bei API-Details
`docs/API.md`; bei „was ist neu“ `docs/CHANGELOG.md`.

---

## Weiterlesen

- API-Referenz: [`API.md`](API.md)
- Projektstand: [`PROJECT_STATUS.md`](PROJECT_STATUS.md)
- Export: [`EXPORT.md`](EXPORT.md) · Web: [`WEB_RUNTIME.md`](WEB_RUNTIME.md)
- Fehler: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)
- Beispiele: `example/hello/`, `example/web_demo/`
