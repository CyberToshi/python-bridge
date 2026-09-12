# Release 0.4.0 – TLS, Datei-Transfer in der Oberfläche, zwei echte Fehler behoben

**Datum:** 12.09.2026 · **Vorherige Version:** 0.3.0

---

## Kurzfassung

| Was | Für wen |
|---|---|
| **Verschlüsselte Verbindungen (TLS/wss) – ab Werk** | Alle, die den Cluster im WLAN oder in einem geteilten Netz betreiben |
| **Eingabedateien und Transfer-Fortschritt in der Oberfläche** | Alle, die große Eingaben nutzen (vorher nur über Code erreichbar) |
| **„Aufgabe starten“ funktionierte nicht** | Alle – der Knopf erzeugte keine Aufgabe |
| **„Umgebung prüfen“ wäre mit TLS kaputtgegangen** | Alle mit dem neuen Standard |

---

## 1. TLS (Transportverschlüsselung)

Der Worker ist jetzt **standardmäßig verschlüsselt** und erzeugt sein Zertifikat
beim ersten Start **selbst**: reine Standardbibliothek, kein `openssl`, kein
`cryptography`, kein Terminal – funktioniert auch auf einem nackten Windows.

* **Discovery meldet es mit:** der Beacon enthält `tls: true`, `scheme: wss` und
  den SHA-256-Fingerabdruck. Der Manager verbindet automatisch verschlüsselt.
* **Kein stiller Rückfall auf Klartext:** Ohne passende Vertrauensart scheitert
  der Handshake **sichtbar** und mit konkreter Anleitung im Protokoll.
* **Zwei ehrliche Vertrauensarten** (mehr gibt die Engine nicht her, siehe
  unten):
  * *Selbstsignierte Zertifikate erlauben* (Häkchen im Panel): verschlüsselt,
    Identität **ungeprüft**.
  * *Zertifikat anheften* (`worker-cert.pem` über den Knopf **Zertifikat** an der
    Worker-Karte): **echte** Prüfung von Signatur, Gültigkeit und Passung.
* **Oberfläche zeigt den Zustand pro Rechner:** „geprüft“ (grün),
  „verschlüsselt (nicht geprüft)“ (gelb), „ohne Verschlüsselung“ (grau).
* **Härtung:** TLS < 1.2 wird abgelehnt; der private Schlüssel liegt mit Rechten
  `0600` und verlässt den Rechner nie; ein kaputtes Zertifikat führt zur
  **Ablehnung** der Verbindung, nicht zu einer schwächeren; widersprüchliche
  Beacon-Angaben (`tls` + `ws`) werden als Klartext behandelt.
* **Eigenes Zertifikat** aus einer PKI möglich: `--tls-cert` + `--tls-key`.
* **Klartext bleibt möglich** (alte Umgebungen): Häkchen *Verschlüsselt (TLS)* in
  der Worker-App entfernen.

> **Ehrliche Grenze:** Godot gibt bei `WebSocketPeer` das empfangene Zertifikat
> nicht heraus – eine Fingerabdruck-Prüfung im Client ist damit
> **technisch nicht möglich**. Deshalb gibt es keine Scheinlösung, sondern die
> zwei klar benannten Wege oben. Ohne angeheftetes Zertifikat schützt TLS gegen
> **Mitlesen**, nicht gegen einen aktiven Angreifer im selben Netz.

---

## 2. Datei-Transfer in der Oberfläche

Bisher war der Datei-Transfer (0.3.0) nur über Code erreichbar. Jetzt:

* **Knopf „Dateien“** in der Aufgaben-Karte (Mehrfachauswahl). Die Anzeige
  daneben nennt Anzahl, Gesamtgröße und Namen.
* **Transfer-Fortschritt** mit Balken:
  `Transfer model.dat: [########------------] 42 % -> Worker_1`
* **Wartende Aufgabe** zeigt in der Spalte *Fortschritt* „Daten werden
  übertragen“ statt eines irreführenden „wartet“.
* Abgeschlossene/fehlgeschlagene Transfers stehen im Protokoll.

---

## 3. Behobene Fehler

| Fehler | Wirkung | Behebung |
|---|---|---|
| **„Aufgabe starten“ erzeugte keine Aufgabe** | Die Oberfläche las die Priorität aus der falschen Quelle (`get_item_metadata` statt `get_item_id`) → Laufzeitfehler `int(null)` beim ersten Klick | Priorität korrekt lesen; der Manager prüft Prioritätswerte zusätzlich und fällt auf `NORMAL` zurück |
| **`--diagnose` wäre mit TLS kaputtgegangen** | Die Statuszeilen der Zertifikatserzeugung landeten vor dem JSON → „Umgebung prüfen“ hätte einen Fehler gezeigt | Statuszeilen bei `--diagnose`/`--tls-fingerprint` nach stderr; die App schneidet das JSON zusätzlich robust heraus |
| `X509Certificate.load` schrieb Engine-Fehler bei falschem Pfad | schwer lesbares Rauschen im Log | Existenz/Größe werden vorher geprüft; Meldung geht über das Protokoll der Oberfläche |
| Fehlende Vertrauensdatei hätte stillschweigend schwächer verbunden | Sicherheitsrisiko | Verbindung wird **abgelehnt** und der Grund gemeldet |
| **Das PyInstaller-Paket war unvollständig** | `worker.spec` band nur `orchestrator_worker.py` ein – eine gebaute `Worker.exe` wäre mit „FEHLER: python_build.py fehlt“ (Exit 2) gestartet. Ein neuer Pakettest prüft jetzt alle Pflichtmodule |
| **Das Worker-ZIP kannte `tls_cert.py` nicht** | Ein entpacktes Paket hätte den Worker nicht starten lassen |

### Neu: Paket-Test
`tests/orchestrator/test_release_package.py` vergleicht die Paketdefinitionen mit
den tatsächlich importierten Modulen, prüft, dass kein Token im ZIP landet, und
**startet den Worker aus dem entpackten ZIP** (Zertifikat + `--diagnose`).

---

## 4. Tests (alle grün)

```text
[OrchestratorTests]  403 passed, 0 failed   (+60 gegenüber 0.3.0)
  inkl. TLS-Vertrauensarten, PEM-Fingerabdruck gegen einen OpenSSL-Vektor,
       Oberflächen-Durchlauf ohne Fenster (TLS-Zeile, Transferbalken,
       Aufgabe über die Oberfläche starten), Einstiegsdatei im Projektordner
[worker-test]         45 passed, 0 failed
[file-test]           21 passed, 0 failed
[worker-ui]           34 passed, 0 failed   (+13: TLS-Startargumente, Diagnosetext)
[tls-test]            29 passed, 0 failed   (neu)
[release-test]        21 passed, 0 failed   (neu: Paket vollständig + läuft)
[e2e Transport]       ERFOLG
[cluster-e2e]         ERFOLG
[cluster-offline-e2e] ERFOLG
[cluster-tls-e2e]     ERFOLG (neu)
```

Der neue TLS-End-to-End-Test läuft den ganzen Weg, den ein Benutzer geht:
Discovery → Handshake absichtlich abgelehnt → Freigabe → Aufgaben über `wss` →
420 KB-Eingabedatei in mehreren Stücken übertragen und im Programm per SHA-256
bestätigt → Zertifikat angeheftet („geprüft“) → weiterer Auftrag läuft.

---

## 5. Pakete in diesem Ordner

| Datei | Inhalt |
|---|---|
| `PythonBridge-Plugin-0.4.0.zip` | das Godot-Addon (Manager/Oberfläche, Kern, Worker-Quellen) |
| `PythonBridge-Worker-0.4.0.zip` | das Client-Programm (`worker_app.py`, `orchestrator_worker.py`, `tls_cert.py`, `file_store.py`, `python_build.py`, Launcher, `LIESMICH.txt`, Anleitungen) |
| `SHA256SUMS.txt` | Prüfsummen beider Pakete |

Bauen (reproduzierbar): `./versions/build_zips.sh`

---

## 6. Upgrade-Hinweis

Ein **bestehender** Worker startet nach dem Update verschlüsselt (neuer
Standard). Der Manager braucht dazu **einmal** das Häkchen *Selbstsignierte
Zertifikate erlauben* – oder gleich das Zertifikat angeheftet. Wer das nicht
will, entfernt in der Worker-App das Häkchen *Verschlüsselt (TLS)* und bleibt
bei `ws://` wie bisher.

Anleitung: `addons/python_bridge/orchestrator/CLUSTER_V1_SETUP.md`, Abschnitt 3b.
