# Python Bridge

**Python natürlich in Godot 4 integrieren** – ein Godot-Addon, das Python-Code
direkt in deinem Godot-Projekt ausführt. Python-Skripte laufen in einer
projektlokalen virtuellen Umgebung und werden per WebSocket mit GDScript
verbunden.

Zusätzlich kann dasselbe Addon Python-Aufgaben auf **andere PCs im eigenen LAN
verteilen** (Cluster-Modul): automatische Erkennung, verschlüsselte Verbindung
mit selbst erzeugtem Zertifikat, Datei-Transfer mit SHA-256-Prüfung und
Weiterlaufen nach einem Rechner-Ausfall. Der Client-Rechner braucht dafür keine
Terminal-Befehle und keine IP-Eingabe – nur Python und die mitgelieferte
Worker-App (`PythonBridge-Worker-*.zip`, startet per Doppelklick).

> **Hinweis zur Verschlüsselung:** die Worker-App startet verschlüsselt (`wss://`);
> Auto-Pair (Token im Discovery-Beacon) ist dort voreingestellt **an**. Details
> und die ehrlichen Grenzen: [Cluster-Sicherheit](https://cybertoshi.github.io/python-bridge/docs/cluster-sicherheit).

Aktuelle Version: siehe [`versions/VERSION`](versions/VERSION) · Pakete und
Änderungen: [`versions/`](versions/)

## Inhalt dieses Repos

| Pfad | Inhalt |
| --- | --- |
| [`addons/python_bridge/`](addons/python_bridge/) | Das Godot-Addon (Plugin), inkl. Cluster-Modul (`cluster/`, `orchestrator/`) |
| [`versions/`](versions/) | Fertige Pakete (Plugin- und Worker-ZIP), Release-Notizen, Prüfsummen |
| [`docs-site/`](docs-site/) | Docusaurus-Quelle der Dokumentations-Website |
| [`docs/`](docs/) | Ausführliche Repository-Guides (manueller Workflow, Screenshots, Cluster-Plan) |
| `.github/workflows/deploy-docs.yml` | Baut die Docs und veröffentlicht sie auf GitHub Pages |
| `.github/workflows/release-addon.yml` | Baut bei jedem `v*`-Tag die Addon-Zip und hängt sie an ein GitHub Release |

## Dokumentation

Die vollständige, strukturierte Dokumentation ist online unter
**<https://cybertoshi.github.io/python-bridge/>** verfügbar. Sie deckt
Installation, Konfiguration, Python-Seite, DataRefs, Architektur,
Fehlerbehebung und eine **API-Referenz für jede Funktion des Addons** ab.

Das **Cluster-Modul** (Aufgaben auf andere PCs verteilen) ist ab v0.4.0 Teil des
Addons:

- [Cluster – Überblick](https://cybertoshi.github.io/python-bridge/docs/cluster)
- [Cluster aufsetzen](https://cybertoshi.github.io/python-bridge/docs/cluster-setup)
- [Cluster-Sicherheit (Token & TLS)](https://cybertoshi.github.io/python-bridge/docs/cluster-sicherheit)

Zusätzlich liegen im Repository ausführliche Guides unter [`docs/`](docs/) –
z. B. der manuelle Copy-Paste-Workflow
[`docs/HANDS_ON_CONNECT_GUIDE.md`](docs/HANDS_ON_CONNECT_GUIDE.md).

Lokal bauen:

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

Nur für **Worker-Rechner** (Cluster) zusätzlich:

- Python 3 **inkl.** Tkinter – unter Linux oft ein eigenes Paket
  (`sudo apt install python3-tk` bzw. `sudo dnf install python3-tkinter`),
  sonst startet die Oberfläche der Worker-App nicht.
- Das Paket `websockets`; die App bietet dafür einen Knopf an, ein Terminal ist
  nicht nötig.

## Neue Addon-Version veröffentlichen

Ein Tag mit `v`-Präfix baut die Pakete automatisch über `versions/build_zips.sh`
und legt ein GitHub Release mit beiden ZIPs und `SHA256SUMS.txt` an:

```bash
git tag v0.4.0
git push origin v0.4.0
```

```text
versions/PythonBridge-Plugin-<version>.zip    Addon für den Hauptrechner
versions/PythonBridge-Worker-<version>.zip    Worker-App für die Clients
versions/SHA256SUMS.txt                       Prüfsummen
```

Dasselbe Skript kannst du lokal ausführen – es schreibt die ZIPs nach
`versions/`. Das Release ist danach unter
`https://github.com/CyberToshi/python-bridge/releases` verfügbar.
