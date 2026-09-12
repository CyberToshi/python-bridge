# Versionen & fertige Pakete

Hier liegen die **fertig gepackten** Auslieferungen. Zum Weitergeben: einfach die
passende ZIP verschicken – auf beiden Seiten sind **keine** Terminal-Befehle und
**keine** Zusatzinstallation nötig (Python-Abhängigkeiten bringt die
Worker-App bei Bedarf selbst mit einem Klick nach).

## Welches Paket brauche ich?

| Ich bin … | Paket | Auspacken nach |
|---|---|---|
| Hauptrechner (steuert alles) | `PythonBridge-Plugin-<version>.zip` | in das eigene Godot-Projekt (`res://`) |
| Client-Rechner (rechnet mit) | `PythonBridge-Worker-<version>.zip` | irgendein Ordner, z. B. `Dokumente\PythonBridge-Worker` |

## Inhalt

### `PythonBridge-Plugin-*.zip` – der Manager

Enthält das komplette Godot-Addon inkl. **Cluster-Manager**, Discovery,
Datei-Transfer und Orchestrator-Kern.

1. ZIP in das Godot-Projekt entpacken (Ergebnis: `res://addons/python_bridge/...`).
2. In Godot: **Projekt → Projekteinstellungen → Plugins → „Python Bridge“ aktivieren**.
3. Szene `addons/python_bridge/cluster/cluster_main.tscn` starten (oder
   `cluster_panel.gd` auf ein `Control` legen).

Enthalten **nicht**: Beispielskripte, Tests, `venv`, `.godot`, Projektdateien –
das Paket ist bewusst schlank und nur das Addon.

### `PythonBridge-Worker-*.zip` – der Client

Enthält die **Worker-Anwendung** (dunkle Oberfläche, Doppelklick-Start), den
Worker-Dienst, die Umgebungs-/Build-Verwaltung (`python_build.py`), den
Datei-Empfang (`file_store.py`), die **TLS-Zertifikatserzeugung
(`tls_cert.py`)** und die Anleitung.

1. ZIP in einen Ordner der Wahl entpacken.
2. `Worker-Windows.bat` (Windows) bzw. `./start_worker_linux.sh` (Linux) starten.
3. Im Fenster auf **Worker starten** klicken – der Rechner meldet sich von
   allein im Netz. Fertig.

Der Rechner läuft dabei **verschlüsselt** (`wss://`, Zertifikat wird beim ersten
Start automatisch erzeugt). Auf dem Hauptrechner einmal das Häkchen
**Selbstsignierte Zertifikate erlauben** setzen – oder das Zertifikat anheften,
wenn die Identität geprüft werden soll. Beides steht in
`CLUSTER_V1_SETUP.md`, Abschnitt 3b.

Auf dem Hauptrechner erscheint der Client dann automatisch im Cluster-Fenster.
Details, Firewall und Fehlersuche: siehe `LIESMICH.txt` im ZIP sowie
`addons/python_bridge/orchestrator/CLUSTER_V1_SETUP.md`.

## Vollständigkeit prüfen

Alle Pakete sind reproduzierbar aus dem Projektstand gebaut; die Prüfsummen
stehen in `SHA256SUMS.txt`:

```bash
sha256sum -c versions/SHA256SUMS.txt
```

## Versionen

| Version | Inhalt (Kurzform) | Notizen |
|---|---|---|
| **0.4.0** | **TLS ab Werk** (wss, selbst erzeugtes Zertifikat, Anheften), Datei-Transfer in der Oberfläche, zwei echte Fehler behoben | [RELEASE_NOTES_0.4.0.md](RELEASE_NOTES_0.4.0.md) |
| 0.3.0 | Datei-Transfer (Registry, Chunks, SHA-256, `WAITING_FOR_DATA`), Worker-Oberfläche mit Fortschrittsbalken, Sicherheits-/Stabilitätsprüfung. **Enthält den Fehler, dass „Aufgabe starten“ keine Aufgabe erzeugte** | [RELEASE_NOTES_0.3.0.md](RELEASE_NOTES_0.3.0.md) |
| 0.2.0 | Cluster V1: LAN-Discovery, Worker-App, Code-/Projekt-Übertragung, Cython-Build | – |

Die aktuelle Version steht in `VERSION`. **Immer die höchste Version verwenden** –
ältere Pakete bleiben nur zur Nachvollziehbarkeit liegen.
