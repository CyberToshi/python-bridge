---
sidebar_position: 9
title: Cluster-Sicherheit (Token & TLS)
description: Token-Pflicht, verschlüsselte Verbindungen ab Werk, die zwei Vertrauensarten und ihre ehrlichen Grenzen.
---

# Cluster-Sicherheit (Token & TLS)

Ein Worker führt Python-Code aus, den der Hauptrechner schickt. Das ist die
gewollte Funktion – und genau deshalb gibt es zwei Schutzschichten:
**Token** (wer darf verbinden) und **TLS** (was sieht das Netz).

## 1. Token: ohne geht es nicht

* Der Worker **startet nicht ohne Token** (16–256 Zeichen,
  `secrets.token_urlsafe(32)`).
* Die Worker-App erzeugt es beim ersten Start selbst und speichert es.
* Jede Verbindung muss sich zuerst mit einem Auth-Frame ausweisen
  (Vergleich gegen Timing-Angriffe gehärtet, max. 3 Fehlversuche, 10 s
  Zeitfenster). Vor der Anmeldung wird **kein** Frame verarbeitet.
* Token wie ein Passwort behandeln: nicht per Chat/Mail weitergeben.

**Auto-Pair:** Damit der Manager ohne Eingabe verbinden kann, kann der Worker
sein Token im Discovery-Beacon mitsenden – bequem im vertrauten LAN. Mit TLS
ist der Beacon-Inhalt unterwegs verschlüsselt; in fremden Netzen trotzdem
besser abschalten und das Token einmalig an der Worker-Karte eintragen.

## 2. TLS: verschlüsselt ab Werk

Ab Version 0.4.0 läuft der Worker **standardmäßig verschlüsselt** (`wss://`)
und erzeugt sein Zertifikat beim ersten Start **selbst**:

* reine Standardbibliothek – kein `openssl`, kein `cryptography`, kein
  Terminal, auch auf einem nackten Windows,
* RSA-2048, gültig 825 Tage, danach still erneuert,
* der **private Schlüssel verlässt den Rechner nie** (Dateirechte `0600`),
* TLS < 1.2 wird abgelehnt,
* der Discovery-Beacon meldet `wss://` **und** den SHA-256-Fingerabdruck.

Der Manager verbindet sich daraufhin automatisch verschlüsselt. Ist die
Vertrauensart nicht gesetzt, scheitert der Handshake **sichtbar**:

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
| **Zertifikat anheften** | An der Worker-Karte **Zertifikat** drücken und `worker-cert.pem` wählen | **Echte** Prüfung: Signatur, Gültigkeit und Passung. Die Anzeige wird zu *TLS, Zertifikat angeheftet und geprüft*. |

Den Pfad zur Datei zeigt die Worker-App beim Knopf **Fingerabdruck anzeigen** –
einmal auf den Hauptrechner kopieren genügt, der Manager merkt sich den Pfad.
Der Fingerabdruck erscheint auf beiden Seiten; **stimmen sie überein, ist es
derselbe Rechner.**

Die Karte im Cluster-Fenster sagt immer, was gilt:

```text
TLS, Zertifikat angeheftet und geprüft          (grün)  beste Variante
TLS, verschlüsselt (Zertifikat nicht geprüft)   (gelb)  Freigabe aktiv
Ohne Verschlüsselung (ws://)                    (grau)  Klartext
```

## 4. Was TLS hier leistet – und was nicht

**Leistet:**

* Mitlesen im Netz ist wirkungslos: Token, Python-Code, Dateien und Ergebnisse
  sind verschlüsselt.
* Mit angeheftetem Zertifikat ist zusätzlich die **Identität** des Rechners
  geprüft.
* Eine geänderte oder kaputte Vertrauensdatei führt zur **Ablehnung** der
  Verbindung, nie zu einer schwächeren.
* Auch beim automatischen Wiederverbinden bleibt die Vertrauensart gleich.

**Leistet nicht:**

* Ohne angeheftetes Zertifikat schützt TLS gegen **Mitlesen**, nicht gegen
  einen **aktiven** Angreifer im selben Netz (Man-in-the-Middle).
* Godot gibt bei `WebSocketPeer` das empfangene Zertifikat nicht heraus – eine
  Fingerabdruck-Prüfung *im Client* ist damit technisch nicht möglich. Deshalb
  gibt es keine Scheinlösung, sondern die zwei Wege oben.
* TLS ersetzt keine Sandbox: übertragener Code läuft mit den Rechten des
  Worker-Benutzers.

:::warning Fremde Netze
Über Messe-, Hotel- oder Gast-WLAN zusätzlich einen **VPN-Tunnel** verwenden
(z. B. WireGuard) und „Auto-Pair“ abschalten.
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
Häkchen **„Verschlüsselt (TLS)“** entfernen. Der Worker spricht dann wieder
`ws://` – das Verhalten der früheren Versionen. Danach im Cluster-Fenster keine
TLS-Freigabe mehr nötig.

## 7. Empfohlene Aufstellung

1. Worker mit **eigenem, unprivilegiertem Benutzerkonto** starten.
2. TLS eingeschaltet lassen und **einmal** `worker-cert.pem` anheften – dann ist
   die Verbindung verschlüsselt **und** geprüft.
3. Token wie ein Passwort behandeln; bei Verdacht in der App **„Neu erzeugen“**
   und im Manager neu eintragen.
4. Firewall: nur TCP 8765 und UDP 8766 im LAN erlauben.
5. Für fremde Netze: VPN **und** Auto-Pair aus.

:::tip Tiefere Prüfung
Die vollständige Sicherheitsprüfung (Bedrohungsmodell, gefundene und behobene
Fehler, bewusste Grenzen, Verifikationsliste) steht in
`addons/python_bridge/orchestrator/SAFETY.md` im Addon.
:::
