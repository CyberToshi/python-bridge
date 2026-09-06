# Python Bridge

**Python natürlich in Godot 4 integrieren** – ein Godot-Addon, das Python-Code
direkt in deinem Godot-Projekt ausführt. Python-Skripte laufen in einer
projektlokalen virtuellen Umgebung und werden per WebSocket mit GDScript
verbunden.

## Inhalt dieses Repos

| Pfad | Inhalt |
| --- | --- |
| [`addons/python_bridge/`](addons/python_bridge/) | Das Godot-Addon (Plugin) |
| [`docs-site/`](docs-site/) | Docusaurus-Quelle der Dokumentations-Website |
| `.github/workflows/deploy-docs.yml` | Baut die Docs und veröffentlicht sie auf GitHub Pages |
| `.github/workflows/release-addon.yml` | Baut bei jedem `v*`-Tag die Addon-Zip und hängt sie an ein GitHub Release |

## Dokumentation

Die vollständige Dokumentation ist online unter
**<https://cybertoshi.github.io/python-bridge/>** verfügbar – lokal bauen mit:

```bash
cd docs-site
npm install
npm run build     # statisches Site-Ergebnis in docs-site/build/
npm run serve     # lokal ansehen: http://localhost:3000/python-bridge/
```

## Addon installieren

1. Lade die aktuelle Zip von den
   [Releases](https://github.com/CyberToshi/python-bridge/releases/latest)
   herunter (oder kopiere den Ordner `addons/python_bridge/` direkt).
2. Entpacke sie und kopiere `addons/python_bridge/` in den `addons/`-Ordner
   deines Godot-Projekts.
3. Aktiviere das Plugin unter **Projekt → Projekt-Einstellungen → Plugins**.

Detaillierte Schritte: [Installation](https://cybertoshi.github.io/python-bridge/docs/installation)

## Voraussetzungen

- Godot 4.2+ (verifiziert mit 4.7.2)
- Python 3.8+ (verifiziert mit 3.12/3.13)

## Neue Addon-Version veröffentlichen

Ein Tag mit `v`-Präfix baut automatisch `python_bridge_addon.zip` und legt
ein GitHub Release an:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Das Release ist danach unter
`https://github.com/CyberToshi/python-bridge/releases` verfügbar.
