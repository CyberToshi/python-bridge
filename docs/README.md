# Dokumentation — Python Bridge

**Addon-Version:** 0.5.0 · **Stand:** 28. Oktober 2026
**Verifiziert mit:** Godot 4.6- und 4.7-stable, Python 3.13

## Einstieg

➡️ **[ERSTE_SCHRITTE.md](ERSTE_SCHRITTE.md)** — Anleitung von Null:
Installation, beide Skript-Typen (temporär/persistent), Editor-Dock,
rückstandsfreies Löschen, Konfiguration (automatisch oder manuell),
Fehlerbehebung, Versionsklarheit.

Diese Seite ist die **verbindliche Referenz**. Alle anderen Dokumente sind
Ergänzungen dazu.

## Dokumente nach Status

### Aktuell (für 0.5.0 gepflegt)

| Dokument | Inhalt |
|---|---|
| [ERSTE_SCHRITTE.md](ERSTE_SCHRITTE.md) | Einstieg, Setup, Bedienung, Löschen |
| [API.md](API.md) | API-Referenz der `PythonBridge`-Facade |
| [CHANGELOG.md](CHANGELOG.md) | Versionshistorie |
| [PROJECT_STATUS.md](PROJECT_STATUS.md) | Kompakter Projektstand |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Statuswerte, Fehlerkategorien, Abhilfe |
| [EXPORT.md](EXPORT.md) | Export für Windows/Linux/Web |
| [WEB_RUNTIME.md](WEB_RUNTIME.md) | Pyodide im Browser, Grenzen |
| [DATA_PLANE.md](DATA_PLANE.md) | DataRefs, große Daten |
| [WORKERS.md](WORKERS.md) | Worker-Slots, Cancellation, Watchdog |
| [BOTTLENECKS.md](BOTTLENECKS.md) | Performance-Grenzen mit Messwerten |
| [PRAXIS.md](PRAXIS.md) | Durchgängiges Beispielprojekt |
| [HP_GDSPEC.md](HP_GDSPEC.md) | Optionales GDScript2All-Werkzeug (kein Transportpfad) |

### Historisch / Planung (nicht als Anleitung verwenden)

| Dokument | Warum |
|---|---|
| [INSTALLATION.md](INSTALLATION.md) | Stand v0.2.x — durch [ERSTE_SCHRITTE.md](ERSTE_SCHRITTE.md) ersetzt |
| [ARCHITEKTUR.md](ARCHITEKTUR.md) | Architektur v0.2.0 |
| [ARCHITEKTUR_V3.md](ARCHITEKTUR_V3.md) | Planungsdokument der „nächsten Generation“, teilweise umgesetzt |
| `PythonBridge_Dokumentation.pdf` / `.html`, `step_by_step_guide.html`, [HANDS_ON_CONNECT_GUIDE.md](HANDS_ON_CONNECT_GUIDE.md), [IPC_CONTROL_PROOF.md](IPC_CONTROL_PROOF.md) | Schnappschüsse älterer Stände; Zahlen und UI darin können veraltet sein |
| [Screenshot_Workflow.md](Screenshot_Workflow.md) | Interner Workflow für Website-Screenshots |

### Website

`docs-site/` ist die Docusaurus-Seite. Sie ist thematisch gepflegt, aber **nicht**
die Referenz — bei Widersprüchen gilt `ERSTE_SCHRITTE.md`.

## Version prüfen

```bash
grep '^version' addons/python_bridge/plugin.cfg    # installierte Version
```

Maßgeblich ist immer `plugin.cfg` — nicht das Datum einer PDF oder einer
Website-Seite.

## Tests

```bash
# GDScript (headless, inkl. Editor-Dock, Datei-Layer, Highlighter)
godot --headless --path . --script res://tests/gdscript/run_tests.gd

# Editor-Dock im echten Editor-Kontext (Dock, Tabs, Speichern, Löschen)
godot --headless --editor --path . --script res://tests/gdscript/verify_editor.gd

# Python-Seite
python3 -m unittest discover -s tests/python -p "test_*.py"
```
