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
2. Worker-Paket auf den Rechner kopieren: den Ordner
   `addons/python_bridge/orchestrator/worker/` (aus Addon-ZIP oder Repository)
   oder das fertige `PythonBridge-Worker-*.zip` aus `versions/` entpacken. Das
   Paket ist eigenständig – **Godot und das Addon sind auf dem Client nicht
   nötig.**
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

Die Tabelle zeigt danach: Name, Status, Fortschritt, Rechner, Versuch, Build und
Ergebnis.

* **Fortschritt:** die Stufe plus Prozent – `detect` (Projekt prüfen), `env`
  (Umgebung), `deps` (Abhängigkeiten), `build` (kompilieren), `run` (Programm
  starten). Vor dem Start steht dort „Daten werden uebertragen“; ohne
  Fortschrittsmeldung „wartet“.
* **Versuch:** `verbraucht/erlaubt`, z. B. `1/3` (ein Versuch, zwei Wiederholungen).
* **Build:** `neu gebaut` oder `Cache` (unverändertes Projekt wurde nicht neu
  kompiliert).
* **Ergebnis:** Fehlermeldung bzw. Rückgabe; Maus darüber zeigt den Hinweis aus
  der Zeile `Loesung:` des Workers.

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
* im Programm liegen sie im **Arbeitsverzeichnis** – und `input["_files"]`
  nennt ihre Namen, damit kein Skript raten muss, wie die Datei hier heißt:

```python
# "_files" = Liste der bereitgestellten Dateinamen im Arbeitsverzeichnis.
# Der Name auf dem Client kann anders sein als in deinem Projekt.
name = (input or {}).get("_files", ["daten.dat"])[0]
with open(name, "rb") as f:
    data = f.read()
```

Grenzen – und **welche** gerade greift, ist wichtig:

| Grenze | Wo festgelegt | Standard |
|---|---|---|
| Größe einer Eingabedatei | Manager (`MAX_FILE_BYTES`, fest) | 512 MB |
| Größe pro Datei auf dem Worker | Worker-App: **Groesste Eingabedatei (MB)** | 512 MB |
| Datei-Cache des Workers gesamt | Worker-App: **Datei-Cache gesamt (MB)** | 4096 MB |
| Dateien pro Aufgabe | Worker (fest) | 64 |
| Inline-`source` im Auftrag | Worker (fest) | 2 MB |
| `input`/`args`/`kwargs` | Worker (fest) | 1 MB |
| Ein Auftrag auf der Leitung | Manager `max_payload_bytes` | 3 MB |

Eine einzelne Datei über **512 MB geht nicht**, auch wenn der Worker-Wert höher
gesetzt wird – der Manager lehnt sie schon beim Registrieren ab und sagt das im
Protokoll. Der Worker prüft dieselbe Größe zusätzlich beim Empfangen. Wird eine
Grenze überschritten, steht ein konkreter Satz mit Größe und Limit im
Protokoll – kein stilles Scheitern.

Übertragen wird **eine Datei nach der anderen**; die Fortschrittsbalken laufen
deshalb nacheinander, nicht parallel.

## 5. Firewall

| Rechner | Richtung | Protokoll | Port | Wofür |
|---|---|---|---|---|
| Client (Worker) | **ausgehend** | UDP (Broadcast) | **8766** | „ich bin da“ (Beacon) |
| Client (Worker) | **eingehend** | TCP | **8765** | Aufgaben, Dateien, Ergebnisse |
| Hauptrechner (Manager) | **eingehend** | UDP | **8766** | Beacons der Rechner empfangen |
| Hauptrechner (Manager) | ausgehend | TCP | 8765 | zur Gegenstelle verbinden |

Der Worker bindet auf der UDP-Seite einen **freien Port** – dort ist *eingehend*
keine Regel nötig; entscheidend ist, dass sein **Broadcast nach draußen**
durchgeht. Auf dem Client-Rechner also **eingehend TCP 8765** erlauben (und
ausgehend UDP 8766). Windows fragt beim ersten Start selbst – „Private
Netzwerke“ genügt.

Wenn gar nichts passiert, obwohl TCP erlaubt ist: zuerst prüfen, ob der Router
den Broadcast blockiert (Gastnetz/AP-Isolation) – dann von Hand eintragen.

Klappt kein Broadcast (Gastnetz, AP-Isolation), trägt man den Rechner im
Cluster-Fenster einmal von Hand ein: `wss://<ip>:8765` plus Token aus der
Worker-App. Wichtig ist das Schema – die Adresse wird **wörtlich** genommen:
* `wss://` → verschlüsselt (Worker-App-Standard). Ein selbstsigniertes
  Zertifikat braucht zusätzlich die Freigabe oder das angeheftete Zertifikat.
* `ws://` → unverschlüsselt; passt nur zu einem Worker, der ohne TLS läuft,
  und ist mit einem TLS-Worker gar nicht möglich (der Handshake scheitert).

## 6. Fehlersuche

| Symptom | Ursache / Lösung |
|---|---|
| Kein Rechner erscheint | Client-App läuft nicht, oder die Firewall blockt UDP 8766. Im Worker-Log steht „Discovery aktiv“, sobald die Meldungen rausgehen („Discovery inaktiv“ nennt sonst den Grund). |
| Rechner erscheint, bleibt aber grau/rot | TCP 8765 geblockt, falsches Token, oder die automatische Kopplung ist abgeschaltet. Token an der Worker-Karte nachtragen (Knopf **Token**). |
| „TLS-Handshake … fehlgeschlagen“ | Absicht: der Worker läuft verschlüsselt mit eigenem Zertifikat. Häkchen **Selbstsignierte Zertifikate erlauben** setzen oder das Zertifikat anheften – [Cluster-Sicherheit](./cluster-sicherheit). |
| Aufgabe bleibt `QUEUED` | Kein Rechner verbunden oder alle im Capacity Gate gesperrt. Metriken im Panel ansehen. |
| Aufgabe steht auf „Daten werden übertragen“ | Die Eingabedatei ist noch unterwegs – das ist der normale Zustand, kein Fehler. |
| Cython-Aufgabe schlägt fehl | In der Worker-App **„Umgebung prüfen“** drücken: sie zeigt in Klartext, ob Python, pip, venv und ein C-Compiler vorhanden sind. |
| Aufgabe `FAILED` | Fehlermeldung in der Tabelle; Maus über die Ergebniszelle zeigt den Lösungshinweis des Workers. |
| Worker verschwindet | App geschlossen oder Standby. Einfach neu starten – der Manager verbindet selbst wieder. Nach 8 s ohne Beacon gilt der Rechner als verschwunden, nach 6 s ohne Heartbeat als `UNRESPONSIVE`. |
| Karte zeigt „Ohne Verschluesselung (ws://)“ | Der Worker läuft im Klartext – typisch, wenn er **von Hand** gestartet wurde (ohne `--tls-self-signed`). Über die App starten schaltet die Verschlüsselung ein. |
| „Datei ist zu gross …“ / „Datei-Cache des Workers ist voll …“ | Grenze überschritten | In der Worker-App *Einstellungen* die Werte erhöhen (oder den Cache des Workers leeren); die Meldung nennt Größe und Limit. |

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
