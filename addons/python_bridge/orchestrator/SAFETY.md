# Sicherheit, Stabilität und Grenzen

Diese Datei ist das Ergebnis einer gezielten **Fehlersuche und Härtung** des
Worker-/Cluster-Systems: Datei-Transfer (Phasen 6–8), Transportverschlüsselung
(TLS) und der Oberfläche **und** des gesamten bestehenden Cluster-/Worker-Codes.

Zentrale Aussage vorweg:

> Das System führt **Python-Code auf anderen Rechnern** aus. Wer ein gültiges
> Token besitzt, darf das. Alle Schutzmaßnahmen setzen deshalb an drei Stellen
> an: **(1)** wer darf sich verbinden, **(2)** was darf übertragen werden,
> **(3)** was darf das auf dem Zielrechner anrichten.

Getestet wurde auf Linux; der Worker-Code ist plattformneutral (nur
Standardbibliothek, keine Annahmen über `/proc` außer für die Anzeige).

---

## 1. Bedrohungsmodell

| Annahme | Konsequenz |
|---|---|
| Das LAN ist **vertrauenswürdig**, aber nicht vertrauensselig | Token-Pflicht **und** TLS in der Worker-App (`wss://`, §3a) |
| Ein Mitleser sitzt eventuell im selben Netz | Verbindung, Code, Dateien und Ergebnisse laufen verschlüsselt; Identität wird nur bei angeheftetem Zertifikat geprüft. **Nicht** verschlüsselt ist der Discovery-Beacon – mit Auto-Pair steht dort das Token im Klartext (§3b) |
| Nachrichten aus dem Netz sind **feindlich** | Jede Eingabe wird validiert, bevor sie wirkt |
| Der Manager ist die **einzige** Steuerinstanz | Ein Controller gleichzeitig; weitere Verbindungen ersetzen die alte |
| Der Worker läuft mit **normalen Benutzerrechten** | Kein Dienst, kein Root, keine Systemänderung nötig |
| Aufgabencode ist **gewollt ausführbarer Code** | Kein Sandboxing (bewusste Entscheidung, §4) |

---

## 2. Kritische Funde und ihre Behebung

### 2.1 Ohne Token ausführbarer Code (behoben, frühere Runde)

Der Worker nahm vorher Aufgaben von **jedem** im LAN an — also Remote-Code-
Ausführung für jeden im selben Netz.

* Token ist **Pflicht**: `--token` oder `--token-file`; ohne gültiges Token
  startet der Worker nicht.
* Handshake `hello_auth` mit konstantzeitlichem Vergleich
  (`secrets.compare_digest`), maximal 3 Fehlversuche, Zeitfenster
  (`--auth-timeout-ms`), danach Trennung mit Code `4401`.
* Vor erfolgreicher Authentifizierung wird **jeder** andere Frame verworfen.

### 2.2 Pfad-Ausbruch (behoben)

`script`, `task_id` und jetzt auch Dateinamen kommen aus dem Netz.

* Script-Namen: `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`, kein `..`, keine
  Trenner, kein führender Punkt; die Datei muss direkt in `--scripts-dir`
  liegen.
* Datei-IDs: **ausschließlich** 64 Hex-Zeichen (SHA-256). Alles andere wird
  abgelehnt (`file_store._safe_id`).
* Transfer-IDs: `^[A-Za-z0-9._-]{1,64}$` und ausdrücklich **nicht** `.`/`..`.
* Anzeigenamen werden auf den Basisnamen reduziert und zusätzlich geprüft
  (`file_store._NAME_RE`); verbotene Namen werden durch `datei-<hash>` ersetzt.
* Es wird **nur** innerhalb des Worker-Arbeitsverzeichnisses geschrieben; alle
  Pfade werden aus geprüften Bestandteilen zusammengesetzt, nie aus rohen
  Netzangaben.
* Der Manager sendet **nie** absolute Pfade des Hauptrechners an einen Worker
  (§15) — nur logische IDs plus Anzeigename.

### 2.3 Doppelausführung und verlorene Aufgaben (behoben)

* Aufgabenzustand wird wieder aufgenommen: ACK-Timeout, Server-Ausfall und
  Task-Timeout führen zu **Retry oder FAILED**, nie zu stillschweigendem
  Verlust.
* Eine Versuchsnummer im Auftrag verhindert, dass ein ACK/Ergebnis eines alten
  Versuchs den neuen Versuch trifft (Dedup am Worker, §10).
* Der alte Worker wird bei jedem Wechsel aktiv zum Abbruch aufgefordert —
  sonst könnten alter und neuer Versuch parallel laufen.
* Der fehlerhafte Versuchszähler des Datei-Transfers wurde korrigiert: er wird
  beim Neustart mitgenommen, sonst hätte ein Hash-Fehler **endlos** neu
  gesendet (Schleife statt klarem Scheitern).

### 2.4 Platte, Speicher und Prozesslast (gehärtet)

| Risiko | Schutz |
|---|---|
| Eine riesige Datei füllt die Platte | `--max-file-mb` (Standard 512 MB) pro Datei, geprüft bei der Anmeldung |
| Viele Dateien füllen die Platte | `--max-cache-mb` (Standard 4 GB) inkl. **laufender** Empfänge; älteste Dateien werden beim Start entfernt |
| Kein Platz mehr für das System | Reserve `--min-free`-Schwelle (Standard 512 MB frei lassen); darunter wird abgelehnt |
| Halbe Dateien bleiben liegen | Empfang erst in `incoming/<id>.part`, Übernahme per `os.replace` **erst nach** Hash-Prüfung; Reste werden beim Start und bei Trennung gelöscht |
| Speicherverbrauch beim Transfer | Stücke sind 256 KB; die Datei wird nie komplett in den RAM geladen (auch die Hash-Berechnung läuft blockweise) |
| Riesen-Nachrichten | Frame-Limit 4 MB Serverseite; Controller bricht Aufträge über `max_payload_bytes` mit Klartext ab |
| Endlose Wiederholungen | Begrenzte Versuche mit Wartezeit; ACK-/Task-Timeouts sind konfigurierbar |
| Log-Wachstum | Ergebnisse und Ereignislisten sind größenbegrenzt (LRU) |

### 2.5 Oberfläche/Anzeige (gehärtet)

* Worker-Namen aus dem Netz werden auf druckbare, einzeilige Zeichen gekürzt,
  bevor sie in Labels oder Logs landen.
* Node-IDs werden für Godot-Node-Namen bereinigt (keine `/ : @ " % Leerzeichen`).
* Dateinamen in der Oberfläche und im Log stammen aus geprüften Werten.

### 2.6 Oberfläche konnte gar keine Aufgabe starten (behoben, Runde TLS/GUI)

**Fund:** Der Knopf **„Aufgabe starten“** war unbrauchbar. Die Oberfläche las die
Priorität über `OptionButton.get_item_metadata()`, die Werte lagen aber in
`add_item(text, id)` also in der **ID**. Ergebnis: `int(null)` – ein
Laufzeitfehler, der die Aufgabe stillschweigend nicht erzeugte. Aufgefallen ist
das erst durch einen neuen Test, der die Oberfläche ohne Fenster **durchläuft**
statt sie nur zu übersetzen.

**Behebung:** Priorität über `get_item_id()` lesen; zusätzlich prüft der Manager
jetzt jeden Prioritätswert (unbekannte oder fehlende Werte → `NORMAL`), damit
auch ein fehlerhafter Aufruf von außen keine Aufgabe verschluckt.

### 2.7 TLS standardmäßig an hätte die Diagnose zerstört (behoben, gleiche Runde)

**Fund:** Das Erzeugen des Zertifikats schreibt Statuszeilen. Bei
`--diagnose` landeten sie vor dem JSON auf **stdout**, wodurch der Bericht nicht
mehr auswertbar war (der Knopf „Umgebung prüfen“ hätte einen Fehler gezeigt).

**Behebung:** Statuszeilen der Zertifikatserzeugung gehen bei `--diagnose` und
`--tls-fingerprint` nach **stderr**; die App schneidet das JSON zusätzlich
robust heraus. Ein Test prüft, dass `--diagnose` reines JSON liefert.

### 2.8 Widersprüchliche TLS-Angaben im Beacon (gehärtet)

Meldet ein Beacon `"tls": true`, aber `"scheme": "ws"`, wird es als Klartext
behandelt. Eine falsche "Sicherheit"-Anzeige wäre schlimmer als keine.

---

## 3. Ablauf einer Datei (was wann geprüft wird)

```text
Manager                                   Worker
Datei wählen
 ├─ Größe prüfen (Limit, > 0)             ← vor dem Hashen!
 ├─ SHA-256 bilden (blockweise)
 └─ Registry: datei_id = SHA-256
Task anlegen (required_files = datei_id)
Router wählt Worker
 ├─ Datei dort schon vorhanden?  ────────►  file_begin  →  "have"   → kein Transfer
 └─ sonst:                                  file_begin  →  "accepted"
     file_chunk (256 KB) ───────────────►  schreiben in incoming/<id>.part
     … wiederholt, je Stück eine Quittung
     file_end ──────────────────────────►  SHA-256 prüfen
                                           ├─ ok      → os.replace → "verified"
                                           └─ Fehler  → löschen     → "hash_failed"
Task wartet (WAITING_FOR_DATA) bis alle Dateien "verified" sind,
erst danach geht der Auftrag an den Worker.
```

Der Worker erhält die Datei unter ihrem Anzeigenamen im Arbeitsverzeichnis der
Aufgabe und findet sie zusätzlich in `input['_files']` — ohne Pfade zu raten.

---

## 3a. Transportverschlüsselung (TLS) – was sie leistet und was nicht

Seit 0.4.0 startet die **Worker-App** den Worker **standardmäßig verschlüsselt**
(Häkchen „Verschluesselt (TLS) - Zertifikat wird automatisch erzeugt“,
voreingestellt). Er erzeugt beim ersten Start selbst ein RSA-2048-Zertifikat
(reine Standardbibliothek – kein `openssl`, kein `cryptography`, kein Terminal)
und lauscht auf `wss://`.

**Wichtig und oft übersehen:** wer den Worker **von Hand** startet
(`python orchestrator_worker.py --token …`), bekommt **kein** TLS – dafür ist
`--tls-self-signed` (oder `--tls-cert/--tls-key`) nötig. Die Beispiele in
`CLIENT_SETUP.md` und `WORKER_SETUP.md` sind genau dieser manuelle Weg und
tragen deshalb einen entsprechenden Hinweis.

**Der ehrliche Teil:** Godot reicht bei `WebSocketPeer` weder das empfangene
Zertifikat noch einen eigenen Prüfer durch. Eine "Fingerabdruck-Prüfung im
Client" ist damit **technisch nicht möglich**. Statt das zu behaupten, gibt es
genau zwei klar benannte Betriebsarten:

| Betriebsart | Umsetzung | Schützt gegen | Schützt **nicht** gegen |
|---|---|---|---|
| Selbstsigniert erlaubt (Freigabe im Panel) | `TLSOptions.client_unsafe()` | Mitlesen im Netz (Token, Code, Dateien, Ergebnisse) | Aktiven Angreifer im selben Netz (Man-in-the-Middle) |
| Zertifikat angeheftet (`worker-cert.pem` als Vertrauensdatei) | `TLSOptions.client(cert)` | Mitlesen **und** Identitätstäuschung: Signatur, Gültigkeit und Passung werden geprüft | Nichts Wesentliches innerhalb des LAN-Bedrohungsmodells |
| Eigenes Zertifikat der eigenen PKI (`--tls-cert/--tls-key`) | wie oben, mit echter Kette | zusätzlich echte Aussteller-Prüfung | – |

Wichtige Eigenschaften der Umsetzung:

* **Kein stiller Rückfall auf Klartext.** Schlägt der Handshake fehl, bleibt der
  Worker nicht verbunden und der Benutzer bekommt einen Satz mit Lösung.
  Ein `wss://` ohne passende Freigabe scheitert also **sichtbar**.
* **Kein schwächeres Protokoll.** TLS < 1.2 wird serverseitig abgelehnt
  (überprüft: TLS 1.0 wird nicht verhandelt).
* **Der private Schlüssel verlässt den Rechner nie.** Er liegt unter
  `<cache>/tls/worker-key.pem` mit Rechten `0600`, wird atomar ersetzt und ist
  nicht Teil des Beacon. Der Fingerabdruck (SHA-256) ist **kein** Geheimnis:
  er steht im Discovery-Beacon und in der Oberfläche zum Vergleich.
* **Zertifikat ist selbst seine eigene CA** (`CA:TRUE`), deshalb funktioniert
  das Anheften ohne Zusatzschritte. Gültigkeit 825 Tage; erneuert wird
  **sieben Tage vor Ablauf** (Zeitpunkt steht in `<cache>/tls/worker-cert.json`),
  der Fingerabdruck bleibt über die Laufzeit stabil.
* **Kein Downgrade durch Umkonfiguration.** Auch beim automatischen
  Wiederverbinden wird dieselbe Vertrauensart verwendet; eine kaputte
  Vertrauensdatei führt zur **Ablehnung**, nicht zu „verbinde trotzdem“.

**Was das für das Bedrohungsmodell bedeutet:** Für das eigene LAN ist damit die
wichtigste realistische Gefahr – Mitlesen (Passiv-Angriff, z. B. im WLAN) –
abgedeckt. Gegen einen **aktiven** Angreifer im selben Netz hilft nur die
angeheftete Datei oder ein VPN. Das ist bewusst so dokumentiert und nicht
weggeredet.

---

## 3b. Was TLS hier **nicht** abdeckt (Klartext-Stellen)

Diese Punkte sind bewusst so gebaut (Plug & Play), müssen aber bekannt sein:

| Stelle | Was im Klartext läuft | Einschätzung |
|---|---|---|
| **Discovery-Beacon** (UDP 8766, Broadcast an `255.255.255.255`) | Rechnername, Port, Queue-Kapazität, TLS-Zustand, Fingerabdruck – und **mit Auto-Pair auch das Token** | Auto-Pair ist in der Worker-App **voreingestellt an** (`"auto_pair": true`). Wer im selben Netz mitschneidet, erhält damit das Token und darf anschließend Aufgaben einreichen. TLS schützt nur die **WebSocket-Verbindung**, nicht den Beacon. Abschaltbar: Häkchen in der App (dann Token einmal im Manager eintragen) oder `--no-discover`/ohne `--auto-pair` auf der Kommandozeile. |
| **Token auf der Workerseite** | `worker_config.json` neben der App, Klartext JSON | Die Datei wird ohne besondere Rechte angelegt (Standard-umask, unter Linux typisch `644`). Auf Rechnern mit mehreren Konten `chmod 600 worker_config.json` setzen. |
| **Token auf der Managerseite** | `user://cluster_workers.json` (bzw. `state_path`), Klartext JSON | Enthält `{"tokens": …, "known": …}`. Gleiche Empfehlung: Datei schützen. |
| **HTTP-Header des Handshakes** | SNI/Host – also die IP, nicht den Inhalt | Unkritisch im LAN. |
| **Datei-Transfer** | läuft **innerhalb** der TLS-Verbindung | Kein separater Klartext-Pfad. |

**Empfehlung für Netze, denen du nicht traust:** VPN verwenden **und** Auto-Pair
abschalten. Im eigenen LAN mit eigenen Geräten ist der Beacon-Broadcast
gleichwertig mit „jeder im WLAN darf mitrechnen“ – das ist eine bewusste
Entscheidung, keine Lücke im Code.

---

## 4. Grenzen, die bewusst gelten

* **TLS schützt nicht automatisch die Identität des Gegenübers.** Ohne
  angeheftetes Zertifikat ist die Verbindung verschlüsselt, aber „wer spricht
  dort?“ bleibt offen – Details in §3a. Für fremde Netze **VPN** verwenden
  (z. B. WireGuard) oder einen SSH-Tunnel.
* **Kein Sandboxing.** Übertragener Python-Code läuft mit den Rechten des
  Worker-Benutzers. Deshalb:
  * Worker nie als Administrator/root starten,
  * nur vertrauenswürdige Personen erhalten das Token,
  * Token bei Verdacht neu erzeugen (Worker-App: „Neu erzeugen“).
* **Kein automatisches Installieren von Compilern.** Cython-Builds brauchen
  einen C-Compiler. Fehlt er, wird das **verständlich gemeldet** (inkl.
  Lösungshinweis) statt heimlich Administratorrechte zu verlangen.
* **Kein Signieren der Aufträge.** Die Authentifizierung gilt pro Verbindung;
  das Token ist das gemeinsame Geheimnis.
* **Ein Controller gleichzeitig.** Das ist Absicht (klare Besitzverhältnisse),
  kein Mangel.

---

## 5. Was der Worker nie tut

* Er schreibt nie außerhalb seines Arbeitsverzeichnisses (`--work-dir`).
* Er löscht keine Dateien außerhalb seines eigenen Caches.
* Er verändert keine Systemeinstellungen, Dienste oder Registry-Einträge.
* Er installiert nichts global: `requirements.txt` wird in einer **eigenen**
  virtuellen Umgebung unterhalb des Benutzer-Caches installiert.
* Er führt keinen Code aus, der nicht über eine **authentifizierte** Verbindung
  kam.
* Er beendet bereits laufende Aufgaben nicht, nur weil ein Server „belastet“
  wirkt (Kapazitätssperre gilt nur für **neue** Zuweisungen).

---

## 6. Empfohlene Aufstellung

1. Worker mit **eigem, unprivilegiertem Benutzerkonto** starten und die
   Token-Datei schützen: `chmod 600 worker_config.json` (bzw. die Datei aus
   `--token-file`).
2. TLS eingeschaltet lassen (in der App Standard) und im Manager **einmal** die
   Datei `worker-cert.pem` anheften – dann ist die Verbindung verschlüsselt
   **und** das Gegenüber geprüft (`§3a`).
3. **Auto-Pair abschalten** und das Token einmal im Manager eintragen; damit
   liegt es nicht mehr unverschlüsselt im Discovery-Broadcast (`§3b`).
4. Token wie ein Passwort behandeln: nicht per Chat/Mail, sondern abtippen oder
   über einen sicheren Kanal.
5. Arbeitsverzeichnis auf ein Verzeichnis mit ausreichend Platz legen
   (`--work-dir`) und `--max-file-mb`/`--max-cache-mb` an die Maschine anpassen;
   eine **einzelne** Eingabedatei bleibt auf 512 MB begrenzt (`MAX_FILE_BYTES`
   im Manager).
6. Firewall: nur den Worker-Port (Standard 8765/TCP) und den
   Discovery-Port (8766/UDP) im LAN erlauben.
7. Bei Verbindungen außerhalb des LAN zusätzlich VPN.

---

## 7. Verifikation (was tatsächlich geprüft wurde)

```text
[OrchestratorTests]   403 passed, 0 failed      (Godot, headless)
  inkl. Registry, Chunk-Transfer, Hash-Fehler, WAITING_FOR_DATA,
       TLS-Vertrauensarten, PEM-Fingerabdruck (OpenSSL-Vektor),
       Oberflächen-Prüfung ohne Fenster (TLS-Zeile, Transferbalken,
       Aufgabe über die Oberfläche starten), Einstiegsdatei im Projektordner
[worker-test]          45 passed, 0 failed      (echter Worker-Prozess)
[file-test]            21 passed, 0 failed      (Chunk-Transfer, Prüfsumme,
                                                 Abbruch, Größe, Pfad, Reuse)
[worker-ui]            34 passed, 0 failed      (Auswertung der Balken + TLS-Start,
                                                 ohne GUI)
[tls-test]             29 passed, 0 failed      (wss, Pinning, Fingerabdruck,
                                                 Beacon, TLS 1.0 abgelehnt,
                                                 kein Klartext-Rückfall)
[release-test]         21 passed, 0 failed      (Pakete vollständig? Zertifikat
                                                 erzeugt aus dem entpackten ZIP)
[e2e Transport]        ERFOLG                   (bestehender Pfad bleibt grün)
[cluster-e2e]          ERFOLG                   inkl. 280 KB-Datei: Transfer →
                                                 SHA-256-Vergleich im Programm →
                                                 kein zweiter Transfer
[cluster-tls-e2e]      ERFOLG                   Discovery → Handshake abgelehnt →
                                                 Freigabe → wss-Aufgaben und
                                                 420 KB-Transfer über TLS →
                                                 Zertifikat angeheftet ("geprüft")
```

Reproduzieren:

```bash
flatpak run org.godotengine.Godot --headless --path . \
    --script res://tests/orchestrator/run_orchestrator_tests.gd
python_bridge/venv/bin/python tests/orchestrator/test_worker_project.py
python_bridge/venv/bin/python tests/orchestrator/test_file_transfer.py
python_bridge/venv/bin/python tests/orchestrator/test_worker_ui.py
python_bridge/venv/bin/python tests/orchestrator/test_tls_worker.py
python_bridge/venv/bin/python tests/orchestrator/test_release_package.py
./tests/orchestrator/run_transport_e2e.sh
./tests/orchestrator/run_cluster_e2e.sh
./tests/orchestrator/run_cluster_offline_e2e.sh
./tests/orchestrator/run_cluster_tls_e2e.sh
```

---

## 8. Wenn etwas nicht klappt

| Symptom | Ursache / Abhilfe |
|---|---|
| „Datei ist zu gross“ | `--max-file-mb` auf dem Worker erhöhen oder Datei verkleinern |
| „Datei-Cache des Workers ist voll“ | `--max-cache-mb` erhöhen oder Worker-Cache leeren (`<work-dir>/filedata`) |
| „zu wenig Platz auf dem Worker-Rechner“ | Platz schaffen; Reserve ist absichtlich großzügig |
| „Pruefsumme stimmt nicht (SHA-256)“ | Netzwerk/Platte fehlerhaft; der Transfer wird begrenzt wiederholt und dann sauber abgebrochen |
| Aufgabe bleibt auf `WAITING_FOR_DATA` | Datei-Transfer läuft oder scheiterte; Log des Hauptrechners zeigt die Ursache |
| Worker fragt nach Token | `--auto-pair` ist aus: Token im Manager eintragen |
| Verbindung bricht sofort ab | Token falsch (Close-Code 4401) oder Firewall |
| „TLS-Handshake … fehlgeschlagen“ | Selbstsigniertes Zertifikat ohne Freigabe: Häkchen im Panel oder Zertifikat anheften |
| „TLS nicht einsatzbereit“ auf der Workerseite | `--tls-cert/--tls-key` unvollständig oder Datei nicht lesbar – der Worker startet dann **nicht** unverschlüsselt weiter |
| Karte zeigt „Zertifikat nicht geprüft“ | Freigabe statt Anheften aktiv: verschlüsselt, aber ohne Identitätsprüfung |
| Worker meldet „FEHLER: tls_cert.py fehlt“ | Unvollständig entpacktes Paket – ZIP komplett entpacken. `tests/orchestrator/test_release_package.py` prüft genau das. |
