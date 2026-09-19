# Troubleshooting

## Status-Werte & Fehlerkategorien

| `result.status` | `error.code` | Bedeutung |
|---|---|---|
| `ok` | — | Erfolg |
| `error` | `PYTHON_EXCEPTION` | Python-Exception im Nutzer-Code |
| `error` | `TASK_ERROR` | Task abgelehnt (Queue voll, Payload zu groß, cancelled) |
| `timeout` | `TIMEOUT_ERROR` | Antwort kam nicht in `timeout_ms` |
| `down` | `CONNECTION_ERROR` | Verbindung/Prozess getrennt |
| `down` | `PROCESS_ERROR` | Prozess gestorben/abgestürzt |
| `internal` | `BRIDGE_ERROR` | Tool-Fehler (Skript fehlt, Sendefehler) |
| `internal` | `DEPENDENCY_ERROR` | venv/pip/Import-Verifikation fehlgeschlagen |
| `internal` | `SERIALIZATION_ERROR` / `PROTOCOL_ERROR` | Kodierung/Frame-Fehler |
| `cancelled` | `TASK_ERROR` | Task vor Abschluss abgebrochen |

Jeder Fehler enthält `{code, type, message, traceback, task_id, instance_id}`.

## Häufige Probleme

### „Kein Python gefunden“
`python_executable` setzen, `PYTHON_PATH` definieren oder Python zum PATH
hinzufügen. Danach Instanz neu starten.

### venv/pip hängt oder schlägt fehl
Provisioning ist poll-basiert und nicht-blockierend; Log unter
`python_bridge/tmp/pip.log`. Bei kaputter venv: `python_bridge/venv/`
löschen und neu starten.

### „Dependency fehlt“ (DEPENDENCY_ERROR)
Der Provisioner prüft nach `pip install`, ob jede konfigurierte Dependency
mit der venv-Python importierbar ist. Fehlgeschlagene Pakete stehen im
Provisioning-Log. Netzwerk/Index prüfen oder Paketname korrigieren.

### „Python-Prozess getrennt“ (CONNECTION_ERROR / PROCESS_ERROR)
- Crash-Restart greift: `max_restart_attempts` mit Exponential-Backoff,
  Reset nach `stable_uptime_ms`.
- Wenn es dauerhaft abstürzt: Server-Log (stdout des Prozesses) prüfen —
  die Serverausgabe landet in der Prozess-Standardausgabe; bei Abstürzen
  im Server selbst hilft ein Blick in `run_server.py`-Fehler.
- Wichtig: `addons/python_bridge/python/` (Quelle) und die Laufzeit-Kopie
  unter `python_bridge/bridge/` müssen identisch sein; das Plugin kopiert
  bei jedem Start automatisch.

### Health-Check-Restarts
`health_check_interval_ms` (Default 5000) und `health_missed_pong_limit`
(Default 3) konfigurieren, falls langlebige Tasks zu Pong-Verzögerungen
führen. Wichtig: Der Python-Server beantwortet Pings während langer Tasks
direkt im Event-Loop (Nutzer-Code läuft im Worker-Thread), daher sollte das
nicht nötig sein.

### Task „timeout“, obwohl Python noch rechnet
Timeout ist eine Godot-seitige Zusicherung; der Python-Worker läuft ggf.
weiter (kann nicht sicher unterbrochen werden), das Ergebnis wird
verworfen. Bei wiederholten Timeouts: Timeout erhöhen oder Instanz mit
`stop_instance()`/`start_instance()` neu starten.

### Werte kommen als String an („pyobject“-Fallback)
Nicht serialisierbare Objekte werden als `repr`-String übertragen. Häufige
Stdlib-Typen (`datetime`, `Decimal`, `UUID`, `Path`, `Enum`) werden seit
0.3.1 strukturiert übertragen und landen auf Godot-Seite als String bzw.
Enum-Wert. Für alles andere: Nur JSON-fähige Typen, `bytes`, `ndarray`,
Listen/Dicts verwenden oder einen Custom-Type per
`PythonBridgeTypeMapper.register()` ergänzen.

### „class_name PyBridgeX ist bereits vergeben“
Der Wrapper-Generator prüft die globale Klassenliste und bricht sichtbar
ab. Python-Datei umbenennen oder die kollidierende Klasse entfernen.

### Godot importiert venv-Dateien
`python_bridge/venv/.gdignore` muss existieren (im Addon enthalten).

## Prozess-/Lebenszyklus-Prüfung

- `PythonBridge.instance_status("default")` zeigt den Zustand.
- `instance_state_changed`-Signal liefert jeden Übergang.
- Nach `shutdown_now()`/`_exit_tree` dürfen keine Python-Prozesse mehr
  laufen (keine Zombies; Force-Kill nach Timeout).