# Cluster V1 – Aufsetzen in 5 Minuten

Dieses Dokument beschreibt **die neue, einfache Variante**: Python-Aufgaben von
einem Hauptrechner auf andere PCs im **gleichen lokalen Netz** verteilen.

Neu gegenueber der alten Anleitung:

* **Keine IP-Adresse eintragen** – Rechner finden sich selbst (LAN-Discovery).
* **Keine Terminal-Befehle** – auf dem Client-Rechner wird nur ein Programm
  gestartet (Doppelklick).
* **Keine vorbereiteten Skript-Ordner** – der Manager schickt den Python-Code
  selbst mit. Der Client braucht keine `scripts/`-Sammlung.
* **Keine Router-Konfiguration, kein Docker, kein VPN** (fuer das eigene LAN).
* **Verschluesselt ab Werk** – der Worker spricht `wss://` mit einem Zertifikat,
  das er selbst erzeugt (Abschnitt 3b).

Es gibt genau zwei Rollen:

| Rolle | Rechner | Was laeuft dort |
|---|---|---|
| **Manager** | der Hauptrechner | Godot mit dem Projekt, Node `ClusterPanel` (dunkle Oberflaeche) |
| **Worker** | jeder weitere PC | die Worker-App `worker_app.py` (Doppelklick) |

---

## 1. Hauptrechner einrichten

### Variante A – fertige Oberflaeche starten (schnellster Test)

Szene `res://addons/python_bridge/cluster/cluster_main.tscn` oeffnen und
**F6** (Szene starten) druecken. Alternativ auf der Kommandozeile:

```bash
godot --path . res://addons/python_bridge/cluster/cluster_main.tscn
```

Das Fenster zeigt sofort: Worker-Liste, Aufgaben, Protokoll. Der Manager startet
die Discovery automatisch.

### Variante B – in eine eigene Szene einbauen

1. Node `Control` (oder `Panel`) in deine Szene legen.
2. Als Skript `res://addons/python_bridge/cluster/cluster_panel.gd` zuweisen.
3. Fertig. Das Panel erzeugt sich seinen `ClusterManager` selbst.

Wenn du die Logik **ohne** Oberflaeche brauchst (z. B. in einem Spiel):

```gdscript
var cluster := ClusterManager.new()
add_child(cluster)

var task_id := cluster.submit_script("mein_job", {
    "command": "run",
    "input": {"werte": [1, 2, 3]},
    "source": "result = sum(input['werte'])",
})
```

`ClusterManager` ist eine ganz normale Node – sie laesst sich beliebig in den
Szenenbaum haengen und nutzt das vorhandene Orchestrator-Fundament
(Server-/Task-Manager, Router, Dispatcher, Transport).

Pruefen: Der Punkt oben links muss von „suche Rechner im Netz …“ auf
„bereit“ wechseln, sobald ein Worker da ist.

---

## 2. Client-Rechner einrichten

Auf dem anderen PC wird **nicht** Godot und **nicht** das ganze Projekt
gebraucht. Es genuegt dieser Ordner:

```text
python_bridge/
└── orchestrator/
    └── worker/
        ├── worker_app.py            <- die App (Doppelklick)
        ├── orchestrator_worker.py   <- der eigentliche Worker (wird von der App gestartet)
        ├── Worker-Windows.bat       <- Starter unter Windows
        └── start_worker_linux.sh    <- Starter unter Linux
```

Quelle im Projekt:
`addons/python_bridge/orchestrator/worker/` (diesen Ordner kopieren).

### Schritt 1 – Python installieren (einmalig)

* **Windows:** Python 3.8+ von python.org, im Setup
  „**Add python.exe to PATH**“ ankreuzen.
* **Linux:** meist schon vorhanden. Zusaetzlich fuer die Oberflaeche:

  ```bash
  sudo apt install python3-tk        # Debian/Ubuntu
  sudo dnf install python3-tkinter    # Fedora
  ```

### Schritt 2 – App starten

* **Windows:** Doppelklick auf `Worker-Windows.bat`
  (oder Rechtsklick → *Oeffnen mit* → Python).
* **Linux:** `./start_worker_linux.sh`
  (einmalig `chmod +x start_worker_linux.sh`).

Es oeffnet sich die dunkle Worker-App. Beim ersten Start passiert automatisch:

* ein **Token** wird erzeugt und in `worker_config.json` neben der App gespeichert,
* Name des Rechners und Ports werden vorgeschlagen,
* „Automatisch im Netz sichtbar“ und „Automatische Kopplung“ sind aktiv.

### Schritt 3 – „Worker starten“ druecken

Wenn das Paket `websockets` fehlt, zeigt die App das an und bietet den Knopf
**„websockets installieren“** an. Danach `Worker starten`.

Im Log der App steht dann:

```text
[orchestrator-worker] Discovery aktiv: MEIN-PC @ 192.168.1.42:8765 (UDP 8766, Auto-Pair: an)
[orchestrator-worker] 'MEIN-PC' lauscht auf ws://0.0.0.0:8765
```

**Das ist alles.** Fenster offen lassen – der Worker laeuft im Hintergrund.

Nach wenigen Sekunden erscheint der Rechner im Manager:

```text
● MEIN-PC     READY
  ws://192.168.1.42:8765
  CPU 12 %   RAM 34 %   Latenz 3 ms   Queue 0/4
```

---

## 3. Aufgaben starten

Im Manager-Fenster:

1. **Datei** oder **Projektordner** waehlen (z. B. ein Skript aus
   `python_bridge/scripts/` oder einen ganzen Projektordner),
2. Ausfuehrungsart waehlen:
   * `run` – der Code liest `input` und setzt `result`
   * `call` – eine Funktion im Skript wird mit Argumenten aufgerufen
3. bei `call`: Funktionsname + Argumente als JSON (`["Hallo"]`),
   bei `run`: die Eingabe als JSON (`{"werte": [1,2,3]}`),
4. optional **Eingabedateien** ueber den Knopf **Dateien** waehlen (siehe
   Abschnitt 3a) – die Anzeige daneben nennt Anzahl und Groesse,
5. **Aufgabe starten**.

Der Quelltext wird **zum Worker uebertragen** und dort in einem **eigenen
temporaeren Arbeitsverzeichnis** ausgefuehrt, das danach wieder verschwindet.
Der Client-Rechner braucht dafuer keine vorbereiteten Dateien.

**Cython und Projekt-Builds:** Enthaelt der Projektordner eine `.pyx`-Datei oder
`requirements.txt`, kuemmert sich der Worker vollstaendig allein darum -
Umgebung anlegen, Pakete installieren, kompilieren, zwischenspeichern. Der
Manager muss dafuer nichts wissen und nichts einstellen. Details:
[CYTHON_AND_BUILD.md](CYTHON_AND_BUILD.md); Eingabedateien: Abschnitt 3a;
Sicherheit und Grenzen: [SAFETY.md](SAFETY.md).

Die Tabelle zeigt den Verlauf: Status, **Fortschritt** (z. B. `build 50 %`),
Rechner, Versuch, **Build** (`neu gebaut` / `Cache`) und Ergebnis. Faehrt die
Maus ueber die Ergebniszelle, erscheint bei Fehlern der Loesungshinweis des
Workers. Das Protokoll unten zeigt jede Einzelheit.

---

## 3a. Grosse Eingabedateien mitschicken

Eine Aufgabe kann **Dateien** brauchen (Modell, Messreihe, Konfiguration). Dafuer
gibt es den Datei-Transfer - und der regelt alles selbst:

```text
Datei waehlen  ->  Hash bilden  ->  nur bei Bedarf uebertragen  ->  pruefen
               ->  Aufgabe startet erst, wenn die Dateien sicher da sind
```

**Bedienung (kein Zusatzwissen noetig):**

1. Im Manager Datei/Projekt waehlen - wie bisher.
2. Aufgabe starten. Ist die Datei noch nicht auf dem Zielrechner, uebertraegt
der Manager sie in Stuecken und zeigt in der Aufgabenliste den Fortschritt
(`Datei: model.dat   80 %`, danach `empfangen`).
3. Erst wenn die Pruefsumme stimmt, geht der Auftrag an den Worker. Solange
steht die Aufgabe auf **WAITING_FOR_DATA** - das ist kein Fehler, sondern die
Gewaehr, dass kein Lauf mit halben Daten startet.

**Im Python-Programm** liegen die Dateien im Arbeitsverzeichnis und sind
zusaetzlich benannt:

```python
name = input['_files'][0]      # z. B. "model.dat"
data = open(name, 'rb').read()
```

**Gute Nachricht fuer dauerhafte Nutzung:** Eine Datei wird ueber ihren
**Inhalt** erkannt (SHA-256). Denselben Inhalt schickt der Manager **kein
zweites Mal** - auch nicht an einen anderen Rechner, der ihn schon hat.

**Grenzen** (bewusst, damit der Client-Rechner geschuetzt bleibt; einstellbar in
der Worker-App unter „Groesste Eingabedatei“ und „Datei-Cache gesamt“):

| Wert | Standard | Wo einstellen |
|---|---|---|
| Groesse pro Datei | 512 MB | Worker-App oder `--max-file-mb` |
| Datei-Cache insgesamt | 4 GB | Worker-App oder `--max-cache-mb` |
| freier Platz wird reserviert | 512 MB | Code-Konstante `min_free_bytes` |

Wird eine Grenze ueberschritten, steht im Manager ein **konkreter Klartext**
(z. B. „Datei ist zu gross (640.0 MB, Limit 512.0 MB) für den Transfer“) - es
gibt kein stilles Scheitern.

Hintergruende, Schutzmassnahmen und die vollstaendige Liste der geprueften
Risiken: [SAFETY.md](SAFETY.md).

Ueber die drei Schalter **Metriken / Aufgaben / Protokoll** laesst sich die
Ansicht auf das reduzieren, was gerade interessiert.

---

## 3b. Verschluesselte Verbindung (TLS)

Der Worker ist ab Version 0.4.0 **standardmaessig verschluesselt**: er erzeugt
beim ersten Start selbst ein Zertifikat und lauscht auf `wss://`. Niemand muss
`openssl`, Zertifikatsdateien oder Zusatzpakete besorgen - es geht auch auf
einem nackten Windows ohne Git.

### Was passiert beim ersten Start

In der Worker-App steht unter *Einstellungen*:

```text
[x] Verschluesselt (TLS) - Zertifikat wird automatisch erzeugt
Die Verbindung ist verschluesselt (wss://). ...
[ Fingerabdruck anzeigen ]
```

Der Knopf **Fingerabdruck anzeigen** zeigt den SHA-256-Wert des Zertifikats:

```text
Zertifikat : .../tls/worker-cert.pem
SHA-256    : 87:D0:2D:CE:7F:F2:4D:E3:...
```

Derselbe Wert erscheint auch in der Worker-Karte des Managers. **Stimmen beide
ueberein, ist es derselbe Rechner.** Das ist der einzige Vergleich, den ein
Benutzer machen muss.

### Zwei Wege, dem Zertifikat zu vertrauen

Ein selbstsigniertes Zertifikat kann keine oeffentliche Stelle bestaetigen.
Der Manager bietet deshalb bewusst nur zwei ehrliche Moeglichkeiten:

| Weg | Bedienung | Was geprueft wird |
|---|---|---|
| **Selbstsigniert erlauben** | Haekchen oben im Panel: *Selbstsignierte Zertifikate erlauben* | Die Verbindung ist **verschluesselt**, die Identitaet aber **nicht** geprueft. Schutz gegen Mitlesen, nicht gegen einen aktiven Angreifer im Netz. |
| **Zertifikat anheften** | An der Worker-Karte den Knopf **Zertifikat** druecken und die Datei `worker-cert.pem` waehlen | **Echte** Pruefung: Signatur, Gueltigkeit und Passung. Die Anzeige wechselt auf *TLS, Zertifikat angeheftet und geprueft*. |

Die Datei `worker-cert.pem` liegt auf dem Client-Rechner im TLS-Ordner des
Workers (die Worker-App zeigt den vollen Pfad beim Knopf
*Fingerabdruck anzeigen*) - einmal auf den Hauptrechner kopieren genuegt, der
Manager merkt sich den Pfad.

### Was der Manager anzeigt

```text
TLS, Zertifikat angeheftet und geprueft         (gruen)  -> beste Variante
TLS, verschluesselt (Zertifikat nicht geprueft) (gelb)  -> Freigabe aktiv
Ohne Verschluesselung (ws://)                   (grau)  -> Klartext
```

Scheitert der Handshake, gibt es **keinen stillen Rueckfall** auf Klartext:
Im Protokoll steht dann zum Beispiel

```text
TLS-Problem bei Worker_1: TLS-Handshake mit Worker_1 fehlgeschlagen. Bei einem
selbstsignierten Zertifikat: in den Cluster-Einstellungen "Selbstsignierte
Zertifikate erlauben" einschalten oder das Zertifikat des Workers
(worker-cert.pem) als Vertrauensdatei hinterlegen.
```

### Ausnahmen

* **Ohne TLS** (altes Verhalten): in der Worker-App das Haekchen *Verschluesselt
  (TLS)* entfernen. Dann laeuft alles wieder ueber `ws://`.
* **Eigenes Zertifikat aus der eigenen PKI**: Worker mit `--tls-cert` und
  `--tls-key` starten (zwei PEM-Dateien) statt `--tls-self-signed`; im Manager
die passende CA/Kette als Vertrauensdatei anheften.
* **Umstellung auf verschluesselt**: Die Adresse wechselt von `ws://` auf
  `wss://`. Im Manager aendert sich nichts - die Discovery meldet das Schema
mit, und gespeicherte Worker werden automatisch richtig verbunden.

Was TLS hier leistet und was nicht, steht ausfuehrlich in [SAFETY.md](SAFETY.md).

---

## 4. Optional: eigenstaendiges Programm bauen

Wenn auf den Clients **gar kein Python** installiert werden soll, laesst sich die
App in eine eigenstaendige Datei packen:

```bash
cd addons/python_bridge/orchestrator/worker
python -m pip install pyinstaller
pyinstaller --noconfirm worker.spec
```

Ergebnis: `dist/Worker.exe` (Windows) bzw. `dist/Worker` (Linux).
Der Build muss **auf dem jeweiligen Zielsystem** erfolgen.

---

## 5. Netzwerk & Firewall

| Richtung | Protokoll | Port | Wofuer |
|---|---|---|---|
| Client → Netz | UDP (Broadcast) | **8766** | Discovery („ich bin da“) |
| Manager → Client | TCP | **8765** | Aufgaben, Ergebnisse |

Auf dem **Client-Rechner** muessen eingehend erlaubt sein:

* UDP 8766 (damit der Manager ihn findet)
* TCP 8765 (damit Aufgaben ankommen)

Windows fragt beim ersten Start normalerweise selbst nach – „Private
Netzwerke“ erlauben. Bei getrennten Netzen/AP-Isolation findet kein Broadcast
statt; dann die Adresse im Manager manuell eintragen (Feld
`ws://<ip>:8765` + Token aus der Worker-App).

Ports aendern: in der Worker-App (Port/Discovery) und im Manager
(`discovery_port`).

---

## 6. Sicherheit

* Der Worker **startet nicht ohne Token**. Das Token ist ein gemeinsames
  Geheimnis zwischen Manager und Client.
* **Verschluesselung ist Standard** (siehe Abschnitt 3b): ab 0.4.0 spricht der
  Worker `wss://` mit einem selbst erzeugten Zertifikat. Damit gehen Token,
  Code und Ergebnisse nicht mehr im Klartext durch das Netz.
* Fuer **echte** Vertrauenspruefung das Zertifikat im Manager anheften
  (Knopf **Zertifikat** an der Worker-Karte). Ohne Anheften schuetzt TLS gegen
  Mitlesen, aber nicht gegen einen aktiven Angreifer im selben Netz.
* **Automatische Kopplung** („Auto-Pair“) ist bequem: das Token steht dann im
  Discovery-Beacon, damit der Manager ohne Eingabe verbinden kann. Das ist fuer
  ein **vertrautes eigenes LAN** gedacht. Mit TLS ist das Token unterwegs
  verschluesselt; im Zweifel trotzdem abschalten und das Token einmalig
  eintragen (Knopf **Token** an der Worker-Karte).
* Fuer fremde Netze (Messe, Hotel-WLAN, Gaeste): „Automatische Kopplung“
  **abschalten** und zusaetzlich einen VPN-Tunnel benutzen.
* Der Worker fuehrt Python-Code aus – auf Clients nur Worker verbinden lassen,
  denen du die Rechenzeit auch geben willst.

---

## 7. Fehlersuche

| Symptom | Ursache / Loesung |
|---|---|
| Kein Rechner erscheint | Client-App laeuft nicht, oder Firewall blockt UDP 8766. Kurz mit `nc -lup 8766` bzw. in der App pruefen, ob „Discovery aktiv“ im Log steht. |
| Cython-Aufgabe schlaegt fehl | In der Worker-App **„Umgebung prüfen“** druecken: sie zeigt in Klartext, ob Python, pip, venv und ein C-Compiler vorhanden sind. Fehlt der Compiler, steht der Installationsweg gleich darunter. |
| Build wird jedes Mal neu gebaut | Der Projektordner aendert sich bei jedem Start (z. B. Zeitstempel im Code) - dann greift der Cache absichtlich nicht. |
| „Projekt zu gross“ | Auftraege sind auf 3 MB begrenzt. Grosse Eingabedaten gehoeren in `input` bzw. folgen spaeter mit dem Datei-Transfer. |
| Rechner erscheint, bleibt aber grau/rot | TCP 8765 geblockt, falsches Token, oder „Auto-Pair“ aus. Token im Manager nachtragen. |
| „websockets installieren“ | Paket fehlt auf dem Client. Knopf in der App benutzen (braucht Internet). |
| App startet nicht unter Linux | `python3-tk` fehlt (siehe Schritt 1). |
| Nur Gastnetz/WLAN mit Isolation | Broadcast kommt nicht durch – Adresse manuell im Manager eintragen. |
| Worker verschwindet nach kurzer Zeit | App geschlossen oder Rechner im Standby. Einfach neu starten; der Manager verbindet selbst wieder. |
| Aufgabe bleibt `QUEUED` | Kein Worker verbunden oder alle im Capacity Gate gesperrt (CPU/RAM/Queue). Metriken im Panel ansehen. |
| Aufgabe `FAILED` | Fehlermeldung steht in der Aufgaben-Tabelle; oft ein Python-Fehler im Skript selbst. |
| Worker wird gefunden, verbindet aber nicht, im Protokoll steht „TLS-Handshake … fehlgeschlagen“ | Der verschluesselte Worker hat ein selbstsigniertes Zertifikat. Haekchen **Selbstsignierte Zertifikate erlauben** im Panel einschalten - oder besser das Zertifikat an der Worker-Karte ueber **Zertifikat** anheften. |
| Karte zeigt „TLS, verschluesselt (Zertifikat nicht geprueft)“ | Bewusste Freigabe ohne Identitaetspruefung. Fuer echte Pruefung `worker-cert.pem` anheften. |
| Fingerabdruecke stimmen nicht ueberein | Es ist ein **anderer** Rechner (oder das Zertifikat wurde neu erzeugt). Zertifikat im Manager neu anheften. Hinweis: Wird `worker-cert.pem` auf dem Client geloescht, entsteht beim naechsten Start ein neues. |
| Worker startet nicht mehr, Meldung „TLS nicht einsatzbereit“ | Bei `--tls-cert/--tls-key` fehlt eine der beiden Dateien. Entweder beide angeben oder in der App auf das automatische Zertifikat umstellen. |
| Nach dem Update verbindet der alte Manager nicht mehr | Der Worker laeuft jetzt verschluesselt (`wss://`). Entweder im Manager die TLS-Freigabe einschalten oder in der Worker-App das TLS-Haekchen entfernen. |

---

## 8. Grenzen von V1 (bewusst)

* **Discovery nur im eigenen LAN** (UDP-Broadcast). Kein Internet, kein VPN,
  kein Docker-Swarm.
* **Keine Router-Konfiguration, kein Portforwarding** – V1 ist fuer dasselbe
  Netz gedacht.
* **TLS ohne Identitaetspruefung, wenn nur die Freigabe aktiv ist.** Fuer echte
  Pruefung das Zertifikat anheften (Abschnitt 3b); gegen einen aktiven Angreifer
  im selben Netz hilft sonst nur ein VPN.
* **Keine Worker-Isolation/Sandbox** – der Code laeuft mit den Rechten des
  Worker-Prozesses.
* **Keine Prioritaets-/Fairness-Garantien** ueber Rechner hinweg – der Router
  waehlt nach Verfuegbarkeit, Auslastung und Datenlage.

---

## 9. Kurzfassung

```text
Hauptrechner                          Client-Rechner
────────────                          ──────────────
Godot + ClusterPanel starten          Worker-Windows.bat /
(Discovery laeuft)                    start_worker_linux.sh  ->  "Worker starten"
                                      (TLS-Zertifikat entsteht beim 1. Start)

        \________________ Discovery (UDP) ________________/
                             |
                   Auftrag + Code (TCP/WebSocket)
                             |
                        Ergebnis zurueck
```

Sobald beide Seiten laufen, braucht niemand mehr eine IP, einen Port oder einen
Terminalbefehl einzutragen.
