---
sidebar_position: 10
title: Fehlerbehebung
description: Häufige Probleme, alle Fehlercodes und eine Diagnose-Reihenfolge.
---

# Fehlerbehebung

## Diagnose-Reihenfolge (immer zuerst)

Wenn etwas nicht funktioniert:

1. **Erste Fehlermeldung** in der Godot-Konsole lesen (nicht die letzte).
2. **Status prüfen:** `print(PythonBridge.instance_status("default"))` –
   erwartet: `ready`.
3. **Portdatei:** existiert `res://python_bridge/tmp/default.json`?
4. **pip-Log:** `res://python_bridge/tmp/pip.log` auf Installationsfehler.
5. **Prozessliste:** läuft ein `run_server.py`-Prozess?
6. **Systematische Prüfung:** [Godot-Verifikation](./godot-verification).

## Alle Fehlercodes (Referenz)

`result.error.code` – stabil für eigene Fehlerbehandlung:

| Code | Bedeutung | Typische Ursache | Was tun |
|---|---|---|---|
| `PYTHON_EXCEPTION` | Exception in deinem Python-Code | Bug, falsche Argumente | `error["type"]`/`error["message"]`/`error["traceback"]` ansehen und korrigieren |
| `TASK_ERROR` | Task-Ebene | Queue voll, Payload zu groß, Task abgebrochen, Handle stale | Limits prüfen; Ergebnis neu erzeugen |
| `TIMEOUT_ERROR` | Antwort kam nicht rechtzeitig | Rechnung dauert länger als `timeout_sec`/`task_timeout_ms`; Queue-Timeout | `timeout_sec` erhöhen; `queue_timeout_ms` prüfen; langen Code mit `__bridge__.checkpoint()` abbrechbar machen |
| `CONNECTION_ERROR` | WebSocket getrennt | Prozess weg, Verbindung abgebrochen | Restart-Policy greift automatisch; bei Retry-Bedarf `retry_policy` konfigurieren |
| `PROCESS_ERROR` | Python-Prozess beendet/abgestürzt | Crash, Watchdog-Kill nach Runaway | Prozess startet per Backoff neu; Kontexte werden selbstheilend neu aufgebaut |
| `DEPENDENCY_ERROR` | venv/pip/Import fehlgeschlagen | Python fehlt, pip ohne Netz, Paket nicht installierbar | `pip.log` lesen; `python_executable` setzen; `dependencies` prüfen |
| `SERIALIZATION_ERROR` | Kodierung/Dekodierung | Ergebnis > `max_result_bytes`; Datei fehlt/korrupt; sha256-Mismatch | Limit erhöhen oder DataRef nutzen; neu materialisieren |
| `PROTOCOL_ERROR` | Protokoll-/Hash-Verletzung | Source-Hash passt nicht | Sollte selbstheilend sein; Addon/Server-Versionen prüfen |
| `BRIDGE_ERROR` | Infrastrukturfehler | Skript nicht gefunden, Instanz unbekannt, Shutdown aktiv | Meldung lesen: Skript-ID, Instanzname, Reihenfolge prüfen |

Legacy-Status (für Kompatibilität): `ok`, `error`, `timeout`, `not_ready`,
`down`, `internal`, `cancelled`. Der Code-Mapping:
`PYTHON_EXCEPTION`/`TASK_ERROR` → `error` · `TIMEOUT_ERROR` → `timeout` ·
`CONNECTION_ERROR`/`PROCESS_ERROR` → `down` · die übrigen → `internal`.

```gdscript
if result.is_error():
    match result.error_code():
        "PYTHON_EXCEPTION":
            print(result.error.get("type"), ":", result.error.get("message"))
        "TIMEOUT_ERROR":
            print("Timeout – Aufruf erneut mit mehr Zeit versuchen")
        "CONNECTION_ERROR", "PROCESS_ERROR":
            print("Instanzproblem – Retry sinnvoll")
        _:
            print("Fehler [", result.error_code(), "]: ", result.error_message())
```

## Start- und Installationsprobleme

| Symptom | Ursache | Lösung |
|---|---|---|
| `Kein Python gefunden` | Python nicht installiert / nicht im PATH | `configure({"python_executable": "/usr/bin/python3"})` (Windows z. B. `C:/Python312/python.exe`) |
| `DEPENDENCY_ERROR` beim Start | pip fehlgeschlagen | Log `res://python_bridge/tmp/pip.log` prüfen (Netz? Rechte?) |
| Erster Start dauert lange | venv + pip laufen | Normal (1–3 Min.); `tmp/pip.log` zeigt Fortschritt |
| Workspace nicht beschreibbar | `res://` im exportierten Spiel schreibgeschützt | `workspace_dir` auf `user://python_bridge` setzen |
| Flatpak-Godot: kein Python | Sandbox | wird automatisch erkannt (host-spawn); sonst nativen Godot-Build nutzen |

## Editor-Probleme

| Symptom | Ursache | Lösung |
|---|---|---|
| Dock „Python Bridge“ fehlt | Plugin nicht aktiv | Projekt → Projekt-Einstellungen → Plugins → aktivieren; ggf. Projekt neu laden |
| Autoload fehlt | Plugin konnte nicht registrieren | In `project.godot` prüfen: `PythonBridge="*res://addons/python_bridge/core/python_bridge.gd"` unter `[autoload]` |
| Parse-Fehler beim Projektstart | alte Godot-Version / unvollständige Kopie | Godot 4.2+; Addon-Ordner frisch kopieren |
| Dock reagiert nicht | Autoload noch nicht bereit | Editor einmal neu laden |

## Laufzeitprobleme (häufige Anfängerfehler)

| Symptom | Ursache | Lösung |
|---|---|---|
| `Script not found: hello` | Datei fehlt oder ID falsch | Skript muss unter `<workspace>/scripts/hello.py` liegen; ID = Name ohne `.py` |
| `Instance not ready` / `status = not_ready` | Aufruf vor `start_instance()` | Immer erst `await PythonBridge.start_instance("default")` |
| Ergebnis ist `null`/leer | Funktion gibt nichts zurück | `return` im Python-Code setzen |
| Zustand „verschwindet“ | Andere Instanz als beim ersten Aufruf | Kontext ist instanzgebunden: immer dieselbe Instanz angeben |
| Python-Änderung wirkt nicht | mtime-Cache bzw. kein Hot Reload | `PythonBridge.hot_reload_script("mein_skript")` oder Dock-Button |
| print() aus Python fehlt in Godot | Ausgaben werden nicht durchgereicht | Werte per `return` liefern und in GDScript printen (Details: [Python-Seite](./python-seite)) |
| Task endet mit Timeout trotz kurzer Funktion | Queue-Timeout (Wartezeit) | `queue_timeout_ms` erhöhen oder Instanz entlasten |

## Große Daten & Frame-Ruckler

| Symptom | Ursache | Lösung |
|---|---|---|
| `SERIALIZATION_ERROR`: Ergebnis zu groß | Antwort > `max_result_bytes` | Limit erhöhen **oder** numpy-Ergebnis nutzen (→ automatischer DataRef) |
| Frame-Ruckler bei großer Antwort | Decode-Budget pro Frame | `max_decode_bytes_per_frame`/`max_results_per_frame` anpassen (sollte bei Defaults nicht nötig sein) |
| `DataRef stale` | Instanz neu gestartet oder Handle freigegeben | Neues Ergebnis erzeugen; Handles sind prozessgebunden |
| Datei-Transport schlägt fehl | Datei fehlt/Prüfsumme | `materialize_data` erneut; Daten neu erzeugen |

## Prozesse & Ports

| Symptom | Ursache | Lösung |
|---|---|---|
| `run_server`-Prozess hängt | Graceful Shutdown umgangen | Einmal manuell beenden; reguläres `shutdown()`/`shutdown_now()` räumt auf |
| Kein Port in `tmp/default.json` | Server startet nicht | Prozessstart-Fehler im Output; `python_executable` prüfen |
| Instanz startet im Kreis (`crashed` → `restarting`) | Prozess stirbt sofort | Fehlermeldung der Instanz lesen (`instance_status`); meist Python-/venv-Problem |

## Noch Fragen?

Die vollständigen Konzepte: [Python-Seite verstehen](./python-seite) ·
[Große Daten](./datenebene) · [Konfiguration](./konfiguration) ·
[API-Referenz](./api)
