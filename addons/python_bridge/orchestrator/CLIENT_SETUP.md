# CLIENT_SETUP.md – Clients (Worker-PCs) an den Hauptrechner anbinden

Dieses Dokument beschreibt den **sicheren** Weg, einen anderen Rechner als
Worker an den Orchestrator anzubinden (das „neue Konstrukt“ mit Token-Auth).

Rollen:

```text
Hauptrechner (Godot + Dock "Task Orchestrator")  =  CONTROLLER
Andere Rechner (führen Python-Skripte aus)       =  WORKER / CLIENT
```

> **Für den normalen Betrieb ist [CLUSTER_V1_SETUP.md](CLUSTER_V1_SETUP.md) der
> aktuelle Weg** (Worker-App mit automatischer Erkennung und TLS an). Dieses
> Dokument bleibt als **manuelle Variante** erhalten und beschreibt den Start
> auf der Kommandozeile.

> **Sicherheit zuerst:** Der Worker führt Python-Code aus. Seit der
> Sicherheitsaktualisierung verweigert der Worker **ohne gültiges Token**
> grundsätzlich jede Verbindung. Ein ungesicherter Worker ist auf einem LAN
> ein Remote-Code-Execution-Risiko – das Token ist deshalb Pflicht, kein
> Optional.

---

## 1. Was jeder Worker-PC braucht

Nur drei Dinge – Godot ist auf dem Worker **nicht** nötig:

1. Python 3.8+ (`python3 --version` bzw. `py -3 --version`)
2. `orchestrator_worker.py` (aus
   `addons/python_bridge/orchestrator/worker/`)
3. Die Python-Skripte, die ausgeführt werden sollen
   (z. B. `hello.py`, `benchmark.py`) in einem eigenen Ordner

Auf dem Worker installieren (Linux):

```bash
python3 -m venv .worker-venv
. .worker-venv/bin/activate
python -m pip install "websockets>=10"
```

(Windows PowerShell):

```powershell
py -3 -m venv .worker-venv
.\.worker-venv\Scripts\Activate.ps1
python -m pip install "websockets>=10"
```

Empfohlene Ordnerstruktur auf dem Worker:

```text
worker/
├── orchestrator_worker.py
├── scripts/
│   ├── hello.py
│   └── benchmark.py
└── .worker-venv/
```

---

## 2. Token erzeugen (Hauptrechner)

Auf dem Hauptrechner ein langes Zufalls-Token erzeugen:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

(Windows PowerShell):

```powershell
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

Beispielausgabe:

```text
kT9x2mQ7vLpZ4wR8nF5yJ1cB3hD6sA0eG-uUoXiVaWk
```

**Regeln:**

- Ein Token pro Worker (oder ein gemeinsames für die private Gruppe –
  pro Worker ist sauberer, dann kann man einen Worker einzeln „aussperren“).
- Format: 16–256 Zeichen aus `A-Za-z0-9_-`. Das generierte Token erfüllt das.
- Das Token ist ein Geheimnis: nicht in Screenshots, Chats oder das Git-Repo.

---

## 3. Worker starten (Client-PC)

Linux / macOS:

```bash
cd /pfad/zu/worker
. .worker-venv/bin/activate

python orchestrator_worker.py \
  --bind 0.0.0.0 \
  --port 8765 \
  --name "Worker-PC-1" \
  --token "kT9x2mQ7vLpZ4wR8nF5yJ1cB3hD6sA0eG-uUoXiVaWk" \
  --scripts-dir "$PWD/scripts"
```

Alternativ (empfohlen für Dauerbetrieb) das Token in eine Datei legen, die
nur der Worker lesen kann:

```bash
echo -n "kT9x2mQ7..." > token.txt && chmod 600 token.txt

python orchestrator_worker.py --bind 0.0.0.0 --port 8765 \
  --name "Worker-PC-1" --token-file token.txt --scripts-dir "$PWD/scripts"
```

Windows PowerShell:

```powershell
cd C:\Pfad\zu\worker
.\.worker-venv\Scripts\Activate.ps1

python orchestrator_worker.py `
  --bind 0.0.0.0 `
  --port 8765 `
  --name "Worker-PC-1" `
  --token "kT9x2mQ7vLpZ4wR8nF5yJ1cB3hD6sA0eG-uUoXiVaWk" `
  --scripts-dir "$PWD\scripts"
```

**Ohne Token startet der Worker bewusst nicht** und weist auf die Generierung
hin. Erwartete Ausgabe:

```text
[orchestrator-worker] 'Worker-PC-1' lauscht auf ws://0.0.0.0:8765 (Skripte: /pfad/zu/worker/scripts)
```

Wichtige Kommandoschalter:

| Schalter           | Bedeutung                                              |
| ------------------ | ------------------------------------------------------ |
| `--bind 0.0.0.0`   | im LAN erreichbar (`127.0.0.1` = nur lokal, falsch dafür) |
| `--port 8765`      | WebSocket-Port (Standard)                              |
| `--name`           | Anzeigename im Orchestrator-Dock                       |
| `--token`          | Shared Secret (Pflicht, alternativ `--token-file`)     |
| `--scripts-dir`    | Ordner mit den ausführbaren `<name>.py`-Skripten       |
| `--queue-capacity` | parallele Tasks, die der Server annehmen darf          |

---

## 4. Worker im Dock eintragen (Hauptrechner)

1. Godot-Projekt öffnen, Plugin **Python Bridge** aktiviert lassen.
2. Dock **Task Orchestrator** öffnen (rechts).
3. `+ Worker...` klicken.
4. Eintragen:
   - **Worker-URL:** `ws://<LAN-IP-des-Workers>:8765`
     (z. B. `ws://192.168.1.42:8765` – **nicht** `localhost`)
   - **Anzeigename:** z. B. `Worker-PC-1`
   - **Token:** das gleiche Token wie beim Worker-Start
5. `Verbinden`.

Statusprüfung am Serverknoten:

```text
🟢 READY
CPU: ...
RAM: ...
Queue: 0/4
```

Erscheint der Knoten dauerhaft `❌ DISCONNECTED`, stimmt URL/Firewall/Bind.
Erscheint er kurz und wird dann getrennt, war das **Token falsch** – der
Worker schließt die Verbindung dann selbst mit `unauthorized`.

Die Verbindung (inklusive Token) wird in `orchestrator_workers.json` im
Projektordner gespeichert und beim nächsten Start automatisch wiederverbunden.
Diese Datei ist deshalb **nicht** in Git einzuchecken (siehe `.gitignore`).

### Erst-Sichttest: Skript auf dem Client ausführen

Im Dock `+ Task` → Script `hello` (oder `benchmark`) eintragen, z. B.
`call` mit Funktion `ping` und Argumenten `["Hallo Worker"]` → `Dispatch`.

Erwartet im Log:

```text
Task ... ACK von w1
Task ... → RUNNING auf w1
Task ... → COMPLETED auf w1
```

---

## 5. Einladungs-Ablauf für neue Clients (Zusammenfassung)

Für jede neue Person / jeden neuen Rechner:

```text
1. Token erzeugen (Hauptrechner)                python -c "import secrets; ..."
2. Token + orchestrator_worker.py + scripts/    an die Person übergeben
3. Person startet Worker mit --token            (Abschnitt 3)
4. Port prüfen:  nc -vz <IP> 8765  /  Test-NetConnection <IP> -Port 8765
5. Im Dock "+ Worker..." mit URL + Token         (Abschnitt 4)
6. Knoten muss READY 🟢 werden, Test-Task Dispatch
```

Damit ist ein Client „fast plug & play“: einmal Python + websockets, ein
Startbefehl, eine URL + Token im Dock.

---

## 6. Was der Worker ausführt – und was nicht

- Ausgeführt wird **nur** `<name>.py` direkt in `--scripts-dir`. Pfad-Tricks
  (`../`, `/etc/…`, Backslash) werden abgelehnt.
- Inline-Source vom Controller ist auf 2 MB begrenzt, Argumente/Input auf 1 MB.
- Große Frames (> 4 MB) werden verworfen.
- Erkennt der Worker eine Task-ID wieder (Netz-Retry), antwortet er mit dem
  gespeicherten Ergebnis statt doppelt auszuführen.
- Schlägt der Auth-Handshake 3× fehl, wird die Verbindung getrennt; unauthen-
  tifizierte Verbindungen werden nach 10 s automatisch geschlossen.

---

## 7. Fehlerdiagnose

| Symptom | Ursache / Fix |
| --- | --- |
| Worker startet gar nicht, Meldung „kein gueltiges Token“ | `--token`/`--token-file` vergessen oder zu kurz |
| Knoten bleibt `DISCONNECTED` | falsche URL, Worker bindet nur lokal, Firewall blockt 8765 |
| Knoten verbindet und fällt sofort ab | falsches Token → Worker-Ausgabe prüfen (`fehlgeschlagener Auth-Versuch`) |
| `READY`, Task bleibt `ASSIGNED` | Script fehlt im `scripts-dir` des Workers, oder `websockets` fehlt |
| `numpy_bench` schlägt fehl | NumPy in der Worker-venv installieren |
| Ergebnis bleibt aus bei langen Tasks | ist normal – Timeout des Controllers hochsetzen (`task_timeout_ms`) |

TCP-Vorprüfung vom Hauptrechner:

```bash
nc -vz 192.168.1.42 8765          # Linux/macOS
```

```powershell
Test-NetConnection 192.168.1.42 -Port 8765   # Windows
```

Firewall-Freigabe auf dem Worker (falls nötig):

```bash
sudo ufw allow from 192.168.1.0/24 to any port 8765 proto tcp
```

```powershell
New-NetFirewallRule -DisplayName "Orchestrator Worker" -Direction Inbound `
  -Protocol TCP -LocalPort 8765 -Action Allow -Profile Private
```

---

## 8. Bewusste Grenzen- **Dieser Start läuft ohne TLS:** die Befehle hier übergeben kein
  `--tls-self-signed`, der Worker spricht also `ws://` – Token, Code und
  Ergebnisse gehen im Klartext durchs Netz. Entweder `--tls-self-signed`
  ergänzen oder den Worker über die App starten (dort ist TLS voreingestellt);
  siehe [CLUSTER_V1_SETUP.md](CLUSTER_V1_SETUP.md) und [SAFETY.md](SAFETY.md).
- **Dateiübertragung ist umgesetzt:** Skripte und Eingabedateien kann der
  Manager selbst übertragen (Chunk-Transfer + SHA-256). Die Skripte müssen also
  **nicht** mehr vorab auf dem Worker liegen – der `--scripts-dir`-Weg bleibt
  als Alternative, wenn du die Dateien bewusst dort haben willst.
- **Keine Rollenrechte:** wer das Token hat, darf Aufgaben einreichen.
