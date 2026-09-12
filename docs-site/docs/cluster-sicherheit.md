---
sidebar_position: 9
title: Cluster-Sicherheit (Token & TLS)
description: Token-Pflicht, verschlüsselte Verbindungen in der Worker-App, die zwei Vertrauensarten und die ehrlichen Grenzen (auch beim Discovery-Beacon).
---

# Cluster-Sicherheit (Token & TLS)

Ein Worker führt Python-Code aus, den der Hauptrechner schickt. Das ist die
gewollte Funktion – und genau deshalb gibt es zwei Schutzschichten:
**Token** (wer darf verbinden) und **TLS** (was sieht das Netz). Beide haben
genau umrissene Grenzen; die wichtigste steht in Abschnitt 1 und betrifft die
Rechner-Erkennung, nicht die Verbindung.

## 1. Token: ohne geht es nicht

* Der Worker **startet nicht ohne Token** (16–256 Zeichen,
  `secrets.token_urlsafe(32)`).
* Die Worker-App erzeugt es beim ersten Start selbst und speichert es.
* Jede Verbindung muss sich zuerst mit einem Auth-Frame ausweisen
  (Vergleich gegen Timing-Angriffe gehärtet, max. 3 Fehlversuche, 10 s
  Zeitfenster). Vor der Anmeldung wird **kein** Frame verarbeitet.
* Token wie ein Passwort behandeln: nicht per Chat/Mail weitergeben.

**Auto-Pair – hier ist Vorsicht angebracht:** Damit der Manager ohne Eingabe
verbinden kann, darf der Worker sein Token im Discovery-Beacon mitsenden. Der
Beacon ist ein **unverschlüsselter UDP-Broadcast**: er ist *nicht* durch TLS
geschützt, sondern geht im Klartext durchs Netz. Wer im selben Netz
mithört, sieht das Token – und das Token ist der Schlüssel zum Ausführen von
Code.

> TLS schützt die WebSocket-Verbindung, **nicht** den Discovery-Beacon.

Standard der Worker-App: **Auto-Pair ist an** (`"auto_pair": true`), damit der
erste Start ohne Eintippen funktioniert. In einem Netz, dem du nicht vertraust,
das Häkchen **„Automatische Kopplung erlauben (bequem, weniger sicher)“**
entfernen und das Token einmalig an der Worker-Karte eintragen. (Das daneben
liegende Häkchen *Automatisch im Netz sichtbar (Discovery)* schaltet nur die
Suche selbst ab – dann findet der Manager den Rechner gar nicht mehr.)

```text
Auto-Pair an   Token reist im Klartext-Beacon mit   bequem, nur vertrautes LAN
Auto-Pair aus  Token muss im Manager eingetippt werden   sicherer
```

Auch das Token selbst liegt auf dem Worker im Klartext in der Datei
`worker_config.json` neben der App – sie wird ohne besondere Dateirechte
angelegt. Auf Rechnern mit mehreren Benutzerkonten also eigene Rechte setzen
(`chmod 600 worker_config.json`).

## 2. TLS: in der Worker-App Standard, auf der Kommandozeile nicht

Die **Worker-App** startet den Worker ab Version 0.4.0 standardmäßig
verschlüsselt (`wss://`): das Häkchen heißt
*„Verschluesselt (TLS) - Zertifikat wird automatisch erzeugt“* und ist
voreingestellt. Wer den Worker dagegen **von Hand auf der Kommandozeile**
startet, bekommt weiterhin Klartext – `--tls-self-signed` muss dort
ausdrücklich angegeben werden:

```bash
python orchestrator_worker.py --token "$TOKEN" --tls-self-signed   # verschlüsselt
python orchestrator_worker.py --token "$TOKEN"                     # ws:// – Klartext
```

Im Klartext-Betrieb meldet der Beacon `ws://`; der Manager verbindet dann
unverschlüsselt. Das passiert nicht heimlich – aber die Entscheidung trifft die
Startart des Workers, nicht der Manager.

Das Zertifikat entsteht beim ersten Start **selbst**; es liegt im Cache des
Workers unter `tls/`:

* reine Standardbibliothek – kein `openssl`, kein `cryptography`, kein
  Terminal, auch auf einem nackten Windows,
* RSA-2048, gültig 825 Tage; erneuert wird **sieben Tage vor Ablauf**
  (Zeitpunkt in `tls/worker-cert.json`),
* der **private Schlüssel verlässt den Rechner nie** (Dateirechte `0600`),
* TLS < 1.2 wird abgelehnt,
* der Discovery-Beacon meldet `wss://` **und** den SHA-256-Fingerabdruck des
  Zertifikats.

Der Manager erkennt `wss://` am Beacon und verbindet automatisch verschlüsselt.
Ist die Vertrauensart nicht gesetzt, scheitert der Handshake **sichtbar**:

```text
TLS-Problem bei Worker_1: TLS-Handshake mit Worker_1 fehlgeschlagen. Bei einem
selbstsignierten Zertifikat: in den Cluster-Einstellungen "Selbstsignierte
Zertifikate erlauben" einschalten oder das Zertifikat des Workers
(worker-cert.pem) als Vertrauensdatei hinterlegen.
```

> **Kein stiller Rückfall auf Klartext.** Lieber eine klare Meldung als eine
> unbemerkt unverschlüsselte Verbindung.

## 3. Zwei ehrliche Vertrauensarten

Ein selbstsigniertes Zertifikat kann keine öffentliche Stelle bestätigen. Statt
das zu umgehen, gibt es genau zwei klar benannte Wege:

| Weg | Bedienung | Was geprüft wird |
|---|---|---|
| **Selbstsigniert erlauben** | Häkchen im Cluster-Fenster: *Selbstsignierte Zertifikate erlauben* | Die Verbindung ist **verschlüsselt**, die Identität aber **nicht** geprüft. Schutz gegen Mitlesen, nicht gegen einen aktiven Angreifer im Netz. |
| **Zertifikat anheften** | An der Worker-Karte **Zertifikat** drücken und `worker-cert.pem` wählen | **Echte** Prüfung: Signatur, Gültigkeit und Passung. Die Anzeige wird zu *TLS, Zertifikat angeheftet und geprueft*. |

Den Pfad zur Datei (`.../tls/worker-cert.pem`) zeigt die Worker-App beim Knopf
**Fingerabdruck anzeigen** – einmal auf den Hauptrechner kopieren genügt, der
Manager merkt sich den Pfad. Der Fingerabdruck ist der SHA-256 über das
DER-Zertifikat. Achtung beim Vergleichen: die **Worker-App zeigt ihn vollständig
in Großbuchstaben mit Doppelpunkten**, die **Karte im Cluster-Fenster nur die
ersten 16 Zeichen in Kleinbuchstaben**. Stimmen diese 16 Zeichen überein, ist es
derselbe Rechner.

Die Karte im Cluster-Fenster sagt immer, was gilt (vier Zustände, nicht drei):

```text
TLS, Zertifikat angeheftet und geprueft           (grün)   geprüft (beste Variante)
TLS, verschluesselt (Zertifikat nicht geprueft)   (gelb)   Freigabe aktiv
TLS, Systemvertrauen (selbstsigniert scheitert)   (gelb)   wss:// ohne Freigabe –
                                                          Handshake scheitert
Ohne Verschluesselung (ws://)                     (grau)   Klartext
```

Die Schreibweise ohne Umlaute ist kein Tippfehler: die Oberfläche zeigt die
Texte genau so an (`geprueft`, `verschluesselt`).

## 4. Was TLS hier leistet – und was nicht

**Leistet:**

* Auf der WebSocket-Verbindung ist Mitlesen wirkungslos: Python-Code, Dateien,
  Ergebnisse und das Token **im Auth-Frame** sind verschlüsselt.
* Mit angeheftetem Zertifikat ist zusätzlich die **Identität** des Rechners
  geprüft.
* Eine geänderte oder kaputte Vertrauensdatei führt zur **Ablehnung** der
  Verbindung, nie zu einer schwächeren.
* Auch beim automatischen Wiederverbinden bleibt die Vertrauensart gleich.

**Leistet nicht:**

* Es schützt **nicht** den Discovery-Beacon. Ist Auto-Pair an, geht das Token als
  unverschlüsselter UDP-Broadcast durchs Netz, bevor irgendein TLS-Handshake
  beginnt (siehe Abschnitt 1).
* Ohne angeheftetes Zertifikat schützt TLS gegen **Mitlesen**, nicht gegen
  einen **aktiven** Angreifer im selben Netz (Man-in-the-Middle).
* Godot gibt bei `WebSocketPeer` das empfangene Zertifikat nicht heraus – eine
  Fingerabdruck-Prüfung *im Client* ist damit technisch nicht möglich. Deshalb
  gibt es keine Scheinlösung, sondern die zwei Wege oben.
* TLS ersetzt keine Sandbox: übertragener Code läuft mit den Rechten des
  Worker-Benutzers.

:::warning Fremde Netze
Über Messe-, Hotel- oder Gast-WLAN zusätzlich einen **VPN-Tunnel** verwenden
(z. B. WireGuard) und Auto-Pair abschalten (das Token liegt sonst im Klartext
im Netz).
:::

## 5. Eigenes Zertifikat (eigene PKI)

Wenn eine eigene Zertifizierungsstelle vorhanden ist, lässt sich der Worker
damit betreiben:

```bash
python orchestrator_worker.py \
  --tls-cert /pfad/server.crt --tls-key /pfad/server.key \
  --token "<token>"
```

Statt `--tls-self-signed` werden die beiden PEM-Dateien benutzt; im Manager
heftet man die passende CA bzw. das Zertifikat an. Fehlt eine der Dateien oder
ist sie unlesbar, **startet der Worker nicht** – statt heimlich unverschlüsselt
weiterzulaufen.

## 6. Ohne TLS arbeiten (bewusst)

Für Umgebungen, in denen der Manager kein TLS kann: in der Worker-App das
Häkchen **„Verschluesselt (TLS) - Zertifikat wird automatisch erzeugt“**
entfernen. Der Worker spricht dann wieder `ws://` – das Verhalten der früheren
Versionen. Danach im Cluster-Fenster keine TLS-Freigabe mehr nötig.

## 7. Empfohlene Aufstellung

1. Worker mit **eigenem, unprivilegiertem Benutzerkonto** starten und
   `worker_config.json` auf `chmod 600` setzen.
2. TLS eingeschaltet lassen, Auto-Pair **abschalten** („Automatische Kopplung
   erlauben“) und das Token einmal an der Worker-Karte eintragen.
3. Einmal `worker-cert.pem` anheften – dann ist die Verbindung verschlüsselt
   **und** geprüft.
4. Token wie ein Passwort behandeln; bei Verdacht in der App **„Neu erzeugen“**
   und im Manager neu eintragen.
5. Firewall: nur TCP 8765 und UDP 8766 im LAN erlauben.
6. Für fremde Netze: VPN **und** Auto-Pair aus.

:::tip Tiefere Prüfung
Die vollständige Sicherheitsprüfung (Bedrohungsmodell, gefundene und behobene
Fehler, bewusste Grenzen, Verifikationsliste) steht in
`addons/python_bridge/orchestrator/SAFETY.md` im Addon.
:::
