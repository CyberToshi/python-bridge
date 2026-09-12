# Orchestrator: zweiter Rechner als echter Worker

> **Für den normalen Betrieb ist [CLUSTER_V1_SETUP.md](CLUSTER_V1_SETUP.md) der
> aktuelle Weg** (Worker-App, automatische Erkennung, TLS an). Dieses Dokument
> beschreibt den **manuellen Start auf der Kommandozeile** – nützlich zum Testen
> und für Rechner, auf denen ohnehin ein Terminal offen ist.
>
> **Wichtig beim manuellen Start:** TLS ist auf der Kommandozeile **nicht**
> voreingestellt. Ohne `--tls-self-signed` (oder `--tls-cert`/`--tls-key`) läuft
> der Worker **unverschlüsselt (`ws://`)** – Token, Code und Ergebnisse gehen
> dann im Klartext durchs Netz. Die Worker-App macht das standardmäßig
> andersherum.

Dieses Dokument beschreibt den **ersten echten LAN-Test**. Der Rechner mit
Godot ist der **Controller**. Der andere Rechner ist ein **Worker**. Der Worker
führt vorhandene Python-Skripte aus; Godot bleibt für Graph, Routing,
ACK/Timeouts und Status zuständig.

```text
Godot / Controller  ── WebSocket ──>  Worker-PC
       Router + Dispatcher             Python-Ausführung
```

> **Dateiübertragung ist inzwischen umgesetzt** (File Registry, Chunk-Transfer,
> SHA-256-Prüfung): Skript und Eingabedateien kann der Manager selbst
> übertragen – siehe [CLUSTER_V1_SETUP.md](CLUSTER_V1_SETUP.md), Abschnitt
> „Große Eingabedateien“, und [SAFETY.md](SAFETY.md).
>
> Für den **manuellen** Weg hier gilt weiterhin: was auf dem Worker liegen
> soll, muss vorher dort liegen (`--scripts-dir`).

## 1. Voraussetzungen

Auf beiden Rechnern:

- Godot 4.2 oder neuer auf dem Controller; getestet mit Godot 4.7.
- Python 3.8 oder neuer auf dem Worker.
- Beide Rechner im selben LAN oder über eine erreichbare VPN-Verbindung.
- Der Worker-TCP-Port `8765` muss vom Controller aus erreichbar sein.
- Das Repository bzw. mindestens `addons/python_bridge/orchestrator/worker/orchestrator_worker.py`
  und die auszuführenden Skripte müssen auf dem Worker liegen.

Die IP-Adresse des Workers findet man beispielsweise mit:

```bash
# Linux
hostname -I
# Windows PowerShell
ipconfig
```

Verwende eine LAN-Adresse wie `192.168.1.42`, **nicht** `127.0.0.1` in der
Controller-Konfiguration. `127.0.0.1` bedeutet immer „dieser Rechner selbst".

### Token-Pflicht (wichtig)

Der Worker ist **nur mit Token** startbar. Ohne gültiges Token wird keine
Verbindung bedient (Close-Code 4401 `unauthorized`). Den kompletten
Client-Aufsetz-Ablauf beschreibt [CLIENT_SETUP.md](CLIENT_SETUP.md). Kurz:

```bash
# Token erzeugen (Hauptrechner):
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
# Worker-Start mit --token "$TOKEN" bzw. --token-file token.txt
```

## 2. Worker-PC vorbereiten

Repository auf den Worker kopieren oder aktualisieren. Der Worker braucht
mindestens diese Struktur:

```text
worker-root/
├── addons/python_bridge/orchestrator/worker/orchestrator_worker.py
└── python_bridge/
    └── scripts/
        ├── hello.py
        ├── benchmark.py
        └── ... deine Aufgaben ...
```

Die `scripts` werden nicht aus dem Controller kopiert. Der Worker führt genau
die lokalen Dateien aus. Für denselben Teststand müssen sie deshalb auf beiden
Rechnern synchron gehalten werden.

### Linux / macOS

```bash
cd /pfad/zu/worker-root
python3 -m venv .worker-venv
. .worker-venv/bin/activate
python -m pip install --upgrade pip
python -m pip install "websockets>=10"

python addons/python_bridge/orchestrator/worker/orchestrator_worker.py \
  --bind 0.0.0.0 \
  --port 8765 \
  --name "Worker-PC-1" \
  --token "$ORCHESTRATOR_TOKEN" \
  --scripts-dir "$PWD/python_bridge/scripts" \
  --queue-capacity 4
```

### Windows PowerShell

```powershell
cd C:\Pfad\zu\worker-root
py -3 -m venv .worker-venv
.\.worker-venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install "websockets>=10"

python .\addons\python_bridge\orchestrator\worker\orchestrator_worker.py `
  --bind 0.0.0.0 `
  --port 8765 `
  --name "Worker-PC-1" `
  --token "$env:ORCHESTRATOR_TOKEN" `
  --scripts-dir "$PWD\python_bridge\scripts" `
  --queue-capacity 4
```

Erwartete Ausgabe:

```text
[orchestrator-worker] 'Worker-PC-1' lauscht auf ws://0.0.0.0:8765 ...
```

Das Terminal muss während des Tests geöffnet bleiben. Der Worker wird nicht
als Systemdienst installiert.

### Firewall

Falls der Controller keine Verbindung herstellen kann, Port `8765/TCP` auf
dem Worker für das private LAN freigeben.

Linux mit UFW:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 8765 proto tcp
```

Windows PowerShell als Administrator:

```powershell
New-NetFirewallRule -DisplayName "Python Bridge Orchestrator Worker" `
  -Direction Inbound -Protocol TCP -LocalPort 8765 -Action Allow `
  -Profile Private
```

Nicht den Port öffentlich ins Internet stellen. Der Worker verlangt zwar jetzt
ein Token (kein ungeschützter RCE-Dienst mehr), bietet aber **kein TLS** – für
Nutzung über das Internet bitte nur über einen VPN-Tunnel. Details und der
komplette Client-Aufsetz-Ablauf: [CLIENT_SETUP.md](CLIENT_SETUP.md).

## 3. Verbindung vom Controller testen

Vor Godot zuerst prüfen, ob der Port erreichbar ist.

Linux/macOS:

```bash
nc -vz 192.168.1.42 8765
```

Windows PowerShell:

```powershell
Test-NetConnection 192.168.1.42 -Port 8765
```

`TcpTestSucceeded: True` bzw. `succeeded` muss erscheinen. Ein offener TCP-Port
beweist noch nicht den WebSocket-Ablauf, aber ein fehlgeschlagener TCP-Test
kann nicht durch eine Godot-Einstellung repariert werden.

## 4. Worker in Godot eintragen

1. Projekt `/home/toshix/briding-new-coming` in Godot öffnen.
2. Plugin **Python Bridge** aktivieren unter `Project → Project Settings →
   Plugins`.
3. Rechts sollte das Dock **Task Orchestrator** erscheinen. Falls nicht:
   Plugin einmal deaktivieren und wieder aktivieren, danach Godot neu öffnen.
4. Im Dock `+ Worker...` klicken.
5. Als URL eintragen:

   ```text
   ws://192.168.1.42:8765
   ```

6. Anzeigename z. B. `Worker-PC-1` eintragen und `Verbinden` klicken.
7. Nach kurzer Zeit muss im Server-Knoten erscheinen:

   ```text
   State: READY
   CPU: ...
   RAM: ...
   Queue: 0/4
   ```

Die Verbindung wird in `orchestrator_workers.json` im Projekt gespeichert und
beim nächsten Editorstart automatisch versucht. Diese Datei enthält **das
Worker-Token** und ist deshalb nicht ins Git-Repo einzuchecken (steht in der
`.gitignore`).

## 5. Ersten echten Task ausführen

Der Worker führt den Namen des Python-Skripts ohne `.py` aus. Für das vorhandene
Beispiel ist das `hello`.

1. Im Dock `+ Task` erzeugt zunächst `demo_task`; dieser Name existiert auf dem
   Worker normalerweise nicht und ist nur für den Demo-Modus geeignet.
2. Für den echten Test muss ein Task mit `python_task = "hello"` eingereicht
   werden. Bis der Aufgaben-Dialog dafür ergänzt ist, kann der Aufruf aus einem
   kleinen GDScript erfolgen:

```gdscript
# Beispiel innerhalb eines Nodes/Tools im Controller-Projekt.
var task := $OrchestratorPanel.submit_task("hello", OrchestratorTask.Priority.HIGH)
$OrchestratorPanel.dispatch_once()
```

Oder im Editor-Dock zunächst `+ Task` nur für die UI-Demo verwenden. Der
Transport selbst ist mit `hello` bereits durch den automatischen E2E-Test
verifiziert.

Erwarteter Ablauf im Log:

```text
Task ... erstellt (hello → HIGH)
→ Führe ... auf w1 aus
Task ... ACK von w1
Task ... → RUNNING auf w1
Task ... → COMPLETED auf w1
```

## 6. Automatischer lokaler E2E-Test

Auf dem Controller-Projekt funktioniert der echte Transport auch ohne zweiten
Rechner mit einem lokal gestarteten Worker:

```bash
cd /home/toshix/briding-new-coming
bash tests/orchestrator/run_transport_e2e.sh
```

Der Test startet den Worker auf `127.0.0.1:8799`, verbindet Godot als
Controller und prüft:

- WebSocket-Verbindung und Worker-Handshake
- Heartbeat, CPU/RAM und Latenz
- Task-Zuweisung über Router und Dispatcher
- ACK
- Startmeldung
- Ergebnis
- Freigabe der Kapazitätsreservierung

Erwartet:

```text
[e2e] ERFOLG: Transport-Ablauf vollständig grün.
```

Für einen entfernten Worker wird **nicht** dieses lokale Script verwendet.
Stattdessen Worker auf dem anderen PC starten, im Dock dessen LAN-URL
verwenden und einen echten Task mit einem dort vorhandenen Script senden.

## 7. Fehlerdiagnose

### Dock erscheint nicht

- `Project → Project Settings → Plugins`: Python Bridge muss `Enabled` sein.
- Godot neu starten oder Plugin deaktivieren/aktivieren.
- Im Editor-Output nach `Orchestrator` oder `SCRIPT ERROR` suchen.
- Das Dock wird direkt durch `addons/python_bridge/plugin.gd` registriert; es
  ist kein zweites EditorPlugin nötig.

### Server bleibt `DISCONNECTED`

- URL kontrollieren: `ws://WORKER-LAN-IP:8765`, nicht `localhost`.
- Worker-Terminal läuft noch?
- `Test-NetConnection`/`nc` ausführen.
- Firewall und VPN prüfen.
- Worker muss auf `0.0.0.0` oder seiner LAN-IP binden, nicht nur auf
  `127.0.0.1`.

### Server wird `UNRESPONSIVE`

Der Worker-Prozess läuft vermutlich noch, sendet aber keine Heartbeats. Im
Worker-Terminal nach Python-Fehlern sehen. Heartbeats werden standardmäßig alle
2 Sekunden gesendet; der Controller stuft den Server nach dem konfigurierten
Timeout zurück.

### Task bleibt `ASSIGNED` oder läuft in Retry

- Worker-Log auf `ACK`/`Task ... läuft` prüfen.
- Existiert `python_bridge/scripts/<python_task>.py` auf dem Worker?
- Ist `python_task` wirklich der Name ohne `.py`?
- Der Worker muss nach Änderungen am Script nicht neu gestartet werden; er liest
  die Datei beim nächsten Task ein.

### `numpy_bench` schlägt fehl

Der Worker braucht NumPy in seiner Umgebung:

```bash
. .worker-venv/bin/activate
python -m pip install numpy
```

Die Datei `numpy_bench.py` definiert Funktionen und führt beim direkten Start
keine davon automatisch aus. Mit `command = "call"` zusammen mit `function`
(und optional `args`/`kwargs`) ruft der Worker die gewünschte Funktion auf –
das ist angebunden und getestet. Für einen einfachen Smoke-Test bleibt
`hello.py` trotzdem der kürzere Weg.

## 8. Aktuelle Grenzen – bewusst ehrlich

Inzwischen umgesetzt und damit **kein** Grenzpunkt mehr:

- File Registry, Chunk-Transfer und SHA-256-Verifikation
- TLS (in der Worker-App voreingestellt, per `--tls-self-signed` auch hier)
- Installation des einzigen Zusatzpakets `websockets` per Knopf in der
  Worker-App (kein Terminal nötig); auf der Kommandozeile weiterhin `pip`

Weiterhin nicht Teil des Werkzeugs:

- persistente Wiederaufnahme eines Tasks nach **Controller**-Neustart
- vollständige Abbildung der bestehenden Python-Bridge-`call`-/`context`-API
  im Orchestrator-Worker
- Systemdienst/Autostart des Workers

Für diesen manuellen Weg gilt deshalb: erst mit kleinen, lokalen Skripten und
einem vertrauenswürdigen Netz testen. Der Kern für Routing, Kapazitätsgate,
Assignment, ACK, Timeout und Reassignment ist bereits durch Tests abgesichert.
