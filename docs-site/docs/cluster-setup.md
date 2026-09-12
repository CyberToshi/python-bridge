---
sidebar_position: 8
title: Cluster aufsetzen
description: Hauptrechner und Client-Rechner in 5 Minuten verbinden – ohne Terminal, ohne IP-Eingabe, ohne Router-Konfiguration.
---

# Cluster aufsetzen

Für den Aufbau gibt es genau zwei Schritte: **Hauptrechner starten**,
**Client-App starten**. Alles andere (Suchen, Verbinden, Code übertragen,
Ergebnisse zurückholen) erledigt das System selbst.

## 1. Hauptrechner einrichten

Das Addon reicht – es ist dieselbe Installation wie bei der lokalen Bridge
([Installation](./installation)). Zwei Wege zur Oberfläche:

### Variante A – fertige Oberfläche starten (schnellster Test)

Szene `addons/python_bridge/cluster/cluster_main.tscn` öffnen und **F6**
drücken. Es öffnet sich die dunkle Cluster-Oberfläche mit Protokoll und
Rechner-Karten.

### Variante B – in die eigene Szene einbauen

`cluster_panel.gd` auf ein `Control` legen (oder per Code):

```gdscript
extends Control

const ClusterPanel := preload("res://addons/python_bridge/cluster/cluster_panel.gd")

func _ready() -> void:
    var panel := ClusterPanel.new()
    panel.set_anchors_preset(Control.PRESET_FULL_RECT)
    add_child(panel)   # bringt seinen ClusterManager selbst mit
```

Fertige Signale des Managers:

```gdscript
panel.manager.worker_connected.connect(func(id: String) -> void: print("dabei: ", id))
panel.manager.task_finished.connect(func(id: String, ok: bool, value: Variant, err: String) -> void:
    print("fertig: ", id, " ok=", ok, " -> ", value))
```

## 2. Client-Rechner einrichten

Auf jedem mitrechnenden PC einmalig:

1. **Python installieren**, falls noch nicht vorhanden (unter Linux zusätzlich
   `python3-tk`, sonst startet die Oberfläche nicht). Das ist die einzige
   Voraussetzung – Compiler, Cython, Docker, Zusatzpakete sind **nicht** nötig.
2. Addon-Ordner aus dem Addon-ZIP bzw. dem Repository auf den Rechner kopieren
   (`addons/python_bridge/orchestrator/worker/`) – oder das fertige
   `PythonBridge-Worker-*.zip` entpacken.
3. Starten:
   * **Windows:** Doppelklick auf `Worker-Windows.bat`
   * **Linux:** `./start_worker_linux.sh`
4. Im Fenster auf **Worker starten** klicken.

Fertig. Der Rechner meldet sich automatisch im Netz und erscheint auf dem
Hauptrechner als Worker-Karte.

:::note Fehlt das Paket `websockets`?
Die Worker-App erkennt das selbst und bietet im Fenster den Knopf
**„websockets installieren“** an. Ein Klick, kurz warten – kein Terminal nötig.
:::

## 3. Aufgaben starten

Im Cluster-Fenster:

1. **Datei** oder **Projektordner** wählen (Rechtsklick-frei, zwei Knöpfe).
2. Optional **Eingabedateien** über den Knopf **Dateien** anhängen – die
   Anzeige daneben nennt Anzahl und Gesamtgröße.
3. Ausführungsart wählen:
   * `run` – der Code liest `input` und setzt `result`
   * `call` – eine Funktion im Skript wird mit Argumenten aufgerufen
4. Optional Ziel-Rechner wählen („Automatisch“ = der Router entscheidet).
5. **Aufgabe starten**.

Die Tabelle zeigt danach: Status, Fortschritt (`env`, `build`, `run` bzw.
„Daten werden übertragen“), Rechner, Versuch, Build (`neu gebaut` / `Cache`)
und Ergebnis.

### Der Ablauf im Hintergrund

```text
Task anlegen
      │
Router wählt Rechner  ──►  Dateien dort schon vorhanden?
      │                          ├─ ja  → kein Transfer
      │                          └─ nein→ Chunk-Transfer + SHA-256-Prüfung
      │                                    (Task steht auf WAITING_FOR_DATA)
      ▼
Auftrag + Python-Code per wss:// zum Worker
      │
Worker: Arbeitsverzeichnis anlegen · Umgebung/Build (bei Bedarf) · ausführen
      ▼
Status, Fortschritt und Ergebnis zurück → Task COMPLETED
```

## 4. Große Eingabedateien

Dateien sind kein Anhang der Nachricht, sondern Teil der Orchestrierung:

* erkannt über den **Inhalt** (`file_id = SHA-256`), nicht über den Pfad,
* übertragen in **256-KB-Stücken**, jedes Stück quittiert,
* **vor** dem Start der Aufgabe auf dem Zielrechner geprüft; erst dann wird
  der Auftrag verschickt,
* ist die Datei schon vorhanden (auch von einem früheren Lauf), findet **kein**
  Transfer statt,
* im Programm liegen die Dateien im Arbeitsverzeichnis und zusätzlich benannt:

```python
name = (input or {}).get("_files", ["daten.dat"])[0]
data = open(name, "rb").read()
```

Grenzen (in der Worker-App einstellbar): **Größe pro Datei** (Standard 512 MB)
und **Datei-Cache gesamt** (Standard 4 GB). Wird eine Grenze überschritten,
steht im Protokoll ein konkreter Satz – kein stilles Scheitern.

## 5. Firewall

| Richtung | Protokoll | Port | Wofür |
|---|---|---|---|
| Client → Netz | UDP (Broadcast) | **8766** | Discovery („ich bin da“) |
| Manager → Client | TCP | **8765** | Aufgaben, Dateien, Ergebnisse |

Auf dem **Client-Rechner** eingehend erlauben: UDP 8766 und TCP 8765. Windows
fragt beim ersten Start selbst – „Private Netzwerke“ genügt.

Klappt kein Broadcast (Gastnetz, AP-Isolation), trägt man den Rechner im
Cluster-Fenster einmal von Hand ein: `wss://<ip>:8765` plus Token aus der
Worker-App.

## 6. Fehlersuche

| Symptom | Ursache / Lösung |
|---|---|
| Kein Rechner erscheint | Client-App läuft nicht, oder die Firewall blockt UDP 8766. Im Worker-Fenster steht „Discovery aktiv“, wenn die Meldung rausgeht. |
| Rechner erscheint, bleibt aber grau/rot | TCP 8765 geblockt, falsches Token oder „Auto-Pair“ aus. Token an der Worker-Karte nachtragen. |
| „TLS-Handshake … fehlgeschlagen“ | Absicht: der Worker läuft verschlüsselt mit eigenem Zertifikat. Häkchen **Selbstsignierte Zertifikate erlauben** setzen oder das Zertifikat anheften – [Cluster-Sicherheit](./cluster-sicherheit). |
| Aufgabe bleibt `QUEUED` | Kein Rechner verbunden oder alle im Capacity Gate gesperrt. Metriken im Panel ansehen. |
| Aufgabe steht auf „Daten werden übertragen“ | Die Eingabedatei ist noch unterwegs – das ist der normale Zustand, kein Fehler. |
| Cython-Aufgabe schlägt fehl | In der Worker-App **„Umgebung prüfen“** drücken: sie zeigt in Klartext, ob Python, pip, venv und ein C-Compiler vorhanden sind. |
| Aufgabe `FAILED` | Fehlermeldung in der Tabelle; Maus über die Ergebniszelle zeigt den Lösungshinweis des Workers. |
| Worker verschwindet | App geschlossen oder Standby. Einfach neu starten – der Manager verbindet selbst wieder. |

## 7. Optional: eigenständiges Programm bauen

Wer auf den Clients **kein Python** installieren will, packt die App:

```bash
cd addons/python_bridge/orchestrator/worker
python -m pip install pyinstaller
pyinstaller --noconfirm worker.spec     # -> dist/Worker.exe bzw. dist/Worker
```

Der Build muss auf dem jeweiligen Zielsystem laufen (PyInstaller kann nicht
cross-compilieren). Die Datei `worker.spec` bindet alle benötigten Module des
Workers ein – wird eines nicht gefunden, bricht der Worker bewusst mit einer
klaren Meldung ab.

## 8. Grenzen dieser Ausbaustufe

* **Discovery nur im eigenen LAN** (UDP-Broadcast).
* **Keine Router-Konfiguration, kein Portforwarding, kein Docker, kein VPN** –
  dafür bewusst verschlüsselt (`wss://`) und mit Token-Pflicht.
* **Keine Sandbox** für übertragenen Code – auf Clients nur Worker verbinden
  lassen, denen du die Rechenzeit auch geben willst.
* **Ein Manager gleichzeitig** steuert einen Worker (klare Besitzverhältnisse).
