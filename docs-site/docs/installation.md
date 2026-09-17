---
sidebar_position: 2
title: Installation
description: Das Addon installieren, aktivieren und die erste Python-Instanz starten.
---

# Installation

Diese Anleitung führt dich vom leeren Godot-Projekt bis zur ersten laufenden
Python-Instanz. Am Ende kannst du das Hello-World aus
[Erste Schritte](./getting-started) ausführen.

## 1. Voraussetzungen prüfen

- Godot 4.2+ installiert (dieses Projekt wurde mit 4.7.2 verifiziert)
- Python 3.8+ installiert und grundsätzlich erreichbar. Prüfen:

```bash
python3 --version   # Linux/macOS
python --version    # Windows
```

Das Addon findet Python selbstständig (Konfiguration `python_executable`,
Umgebungsvariable `PYTHON_PATH`, dann `PATH`-Suche). Falls du Python nicht
im `PATH` hast, trägst du später in der [Konfiguration](./konfiguration)
einen absoluten Pfad ein.

## 2. Addon herunterladen und in das Projekt kopieren

Lade die aktuelle Addon-Zip-Datei von den
[GitHub-Releases](https://github.com/CyberToshi/python-bridge/releases/latest)
herunter:

- **Direktlink:**
  [`python_bridge_addon.zip`](https://github.com/CyberToshi/python-bridge/releases/latest/download/python_bridge_addon.zip)

Entpacke sie und kopiere den Ordner `addons/python_bridge/` **vollständig** in
den `addons/`-Ordner deines Godot-Projekts:

```text
dein_projekt/
├── addons/
│   └── python_bridge/     ← kompletter Addon-Ordner
├── project.godot
└── ...
```

Das Projekt in diesem Repository hat das Addon bereits unter `addons/`
liegen – dort ist dieser Schritt schon erledigt.

## 3. Plugin aktivieren

1. Öffne das Projekt im Godot-Editor.
2. Menü **Projekt → Projekt-Einstellungen**.
3. Wechsle zum Tab **Plugins**.
4. In der Liste erscheint **Python Bridge**.
5. Setze den Haken in der Spalte **Enable** (bzw. „Aktivieren“).

Beim Aktivieren registriert das Plugin automatisch:

- den **Autoload-Singleton `PythonBridge`**
  (`res://addons/python_bridge/core/python_bridge.gd`) – falls nicht schon
  im Projekt vorhanden,
- das Dock **„Python Bridge“** oben rechts im Editor,
- das optionale Dock **„HP GDScript“** (reines Compute-Werkzeug, siehe
  [Hochleistungspfade](./hochleistungspfade)).

Beides siehst du sofort in `project.godot`:

```ini
[autoload]
PythonBridge="*res://addons/python_bridge/core/python_bridge.gd"

[editor_plugins]
enabled=PackedStringArray("res://addons/python_bridge/plugin.cfg")
```

:::tip Erste Aktivierung
Manchmal muss Godot die Dateien einmal neu scannen. Falls das Dock nicht
erscheint: **Projekt → Neu laden** oder den Editor neu starten.
:::

## 4. Workspace verstehen

Beim ersten Start einer Instanz legt das Addon den **Workspace** an –
standardmäßig unter `res://python_bridge/`:

```text
python_bridge/
├── scripts/     ← deine Python-Dateien (normaler .py-Code)
├── wrappers/    ← generierte GDScript-Wrapper (automatisch erzeugt)
├── venv/        ← projektbezogene virtuelle Python-Umgebung (automatisch)
├── tmp/         ← Port-Dateien, Logs (z. B. pip.log), DataRef-Dateien
├── config/      ← kombinierte requirements-Datei
└── bridge/      ← interne Laufzeit-Kopie (nicht anfassen)
```

Du arbeitest praktisch nur mit `scripts/` (und optional `wrappers/`).
`venv/`, `tmp/` und `bridge/` werden automatisch verwaltet – **nicht**
händisch verändern.

## 5. Erste Instanz starten (Test)

Lege ein minimales Skript an – direkt im Editor über das Python-Dock
(**New script**, siehe [Editor-Bedienung](./editor-ui)) oder als Datei
`res://python_bridge/scripts/hello.py`:

```python
def say_hello(message: str) -> str:
    return f"Hello Godot! Python received: {message}"
```

Starte die Instanz dann mit einem winzigen GDScript (an einen beliebigen
Node in einer Szene angehängt):

```gdscript
func _ready() -> void:
    var started: PythonBridgeResult = await PythonBridge.start_instance("default")
    if started.is_error():
        push_error("Start fehlgeschlagen: " + started.error_message())
        return
    print("Instanz bereit: ", PythonBridge.instance_status("default"))
```

### Was beim ersten Start passiert (und warum es dauern kann)

1. **Python finden** – Suche wie oben beschrieben.
2. **venv anlegen** – falls `res://python_bridge/venv/` fehlt, wird sie
   erstellt (Timeout: 300 s).
3. **Pakete installieren** – `pip install websockets` (+ deine konfigurierten
   Zusatzpakete). Log: `res://python_bridge/tmp/pip.log`.
4. **Import-Prüfung** – das Addon prüft, ob alle Pakete wirklich importierbar
   sind; sonst strukturierter `DEPENDENCY_ERROR`.
5. **Server starten** – `run_server.py` wird als Unterprozess gestartet.
6. **Verbinden** – Godot liest die Port-Datei
   (`tmp/default.json`), öffnet den WebSocket und macht den Handshake.

**Erster Start: 1–3 Minuten sind normal.** Danach wird der Workspace
wiederverwendet und der Start dauert nur noch Sekundenbruchteile.

## 6. Erwartetes Ergebnis

Die Konsole zeigt `Instanz bereit: ready`. Fehlt Python oder schlägt ein
Schritt fehl, bekommst du eine strukturierte Fehlermeldung – die
Fehlerkategorien erklärt [Fehlerbehebung](./fehlerbehebung).

## 7. Aufräumen

`PythonBridge.shutdown()` bzw. `shutdown_now()` beendet alle Instanzen
kontrolliert. Beim Schließen des Editors/der Szene passiert das automatisch
(`_exit_tree`), sodass keine Python-Prozesse übrig bleiben.

## Nächster Schritt

→ [Erste Schritte: Hello World](./getting-started)
