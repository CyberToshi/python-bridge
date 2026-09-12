# Repository-Dokumentation

Dieser Ordner enthält die **repository-nahen** Dokumente, die bewusst
getrennt von der Docusaurus-Website (`docs-site/`) liegen. Die Website ist
die primäre, durchsuchbare Anleitung; hier stehen ausführliche Workflows,
die als Markdown im Repository mitgeliefert werden.

| Dokument | Inhalt |
|---|---|
| [`HANDS_ON_CONNECT_GUIDE.md`](HANDS_ON_CONNECT_GUIDE.md) | Der **ausführliche manuelle Workflow**: welcher Node bekommt welches Skript, vollständiger GDScript- und Python-Code, Datenfluss Schritt für Schritt. |
| [`Screenshot_Workflow.md`](Screenshot_Workflow.md) | Wie die 8 animierten GUI-Screenshots der Editor-Doku mit Flameshot aufgenommen und in `docs-site/static/img/ui/` abgelegt werden. |
| [`CLUSTER_INTEGRATION_PLAN.md`](CLUSTER_INTEGRATION_PLAN.md) | Ursprünglicher Planungstext zum verteilten Worker-Cluster – **umgesetzt in v0.4.0**; oben verlinkt die aktuelle Dokumentation. |

## Cluster (verteilt rechnen)

Die Verteilung auf andere PCs ist umgesetzt. Einstiegspunkte:

| Quelle | Inhalt |
|---|---|
| [`docs-site/docs/cluster.md`](../docs-site/docs/cluster.md) | Überblick und Architektur |
| [`docs-site/docs/cluster-setup.md`](../docs-site/docs/cluster-setup.md) | Aufsetzen inkl. Firewall und Fehlersuche |
| [`docs-site/docs/cluster-sicherheit.md`](../docs-site/docs/cluster-sicherheit.md) | Token und TLS (Standard), Vertrauensarten |
| [`addons/python_bridge/orchestrator/CLUSTER_V1_SETUP.md`](../addons/python_bridge/orchestrator/CLUSTER_V1_SETUP.md) | Ausführliche Aufsetz-Anleitung |
| [`addons/python_bridge/orchestrator/SAFETY.md`](../addons/python_bridge/orchestrator/SAFETY.md) | Sicherheitsprüfung und Grenzen |
| [`addons/python_bridge/orchestrator/CYTHON_AND_BUILD.md`](../addons/python_bridge/orchestrator/CYTHON_AND_BUILD.md) | Builds, Umgebungen, Cache |

Der Client-Rechner braucht nur die Worker-App aus
`addons/python_bridge/orchestrator/worker/` (oder das fertige
`PythonBridge-Worker-*.zip` aus [`versions/`](../versions/)) – kein Terminal,
keine IP-Eingabe, kein Docker.

## Online-Dokumentation

Die vollständige, strukturierte Dokumentation (Installation, Konfiguration,
Python-Seite, DataRefs, **API-Referenz für jede Funktion**, Architektur,
Fehlerbehebung) findest du unter:

**<https://cybertoshi.github.io/python-bridge/>**

Lokal bauen:

```bash
cd docs-site
npm install
npm run start     # Entwicklungsserver
npm run build     # statisches Ergebnis in docs-site/build/
```

## Runtime-Addon

Das eigentliche Godot-Addon liegt unter
[`addons/python_bridge/`](../addons/python_bridge/). Releases enthalten die
fertige Zip (`python_bridge_addon.zip`) mit `addons/python_bridge/` an der
Wurzel, sodass beim Entpacken alles am richtigen Ort landet.
