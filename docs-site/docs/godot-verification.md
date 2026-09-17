---
sidebar_position: 5
title: Godot-Verifikation (P0)
description: Schritt-für-Schritt-Checkliste, um das Addon im Editor fehlerfrei zu prüfen.
---

# Godot-Verifikation (P0)

Diese Seite ist die konkrete Prüfanleitung für den ersten echten Godot-Start.
Sie ist bewusst als Checkliste aufgebaut: Jeder Schritt hat eine erwartbare
Beobachtung, damit du sofort erkennst, welche Stelle problematisch ist.

Der Python-Kern des Addons ist durch eine Testsuite abgedeckt (derzeit
90 Tests grün). Die GDScript-Seite ist durch 193 Unit-Assertions in vier
Suites abgedeckt, und der komplette End-to-End-Weg
(Godot → Python-Prozess → WebSocket → Task → Ergebnis) wurde headless mit
Godot 4.7.2 verifiziert.

## Automatisierte Verifikation (Terminal)

Falls du Godot über Flatpak installiert hast (Flathub), kannst du alle
Prüfpunkte auch im Terminal fahren — das ist der schnellste Weg, um nach
einem Update zu prüfen, dass noch alles funktioniert:

```bash
# 1) Skripte kompilieren fehlerfrei? (leerer Output = gut)
flatpak run org.godotengine.Godot --headless --editor --quit --path <PROJEKT> 2>&1 | grep -E "SCRIPT ERROR|Parse Error"

# 2) GDScript-Unit-Suites (4 Suiten, 193 Assertions)
flatpak run org.godotengine.Godot --headless --path <PROJEKT> --script res://tests/gdscript/run_tests.gd

# 3) Autoload + Dock + Plugin-Status
flatpak run org.godotengine.Godot --headless --editor --path <PROJEKT> --script res://tests/gdscript/verify_editor.gd

# 4) Live-End-to-End (startet echte Python-Instanz, dauert beim ersten Mal 1–3 min)
flatpak run org.godotengine.Godot --headless --path <PROJEKT> --script res://tests/gdscript/e2e_live.gd
```

Bei einer nativen Godot-Installation ersetzt du `flatpak run
org.godotengine.Godot` einfach durch deinen `godot`-Befehl.

Erwartete Ausgaben: `TOTAL: 193 passed, 0 failed`,
`[VERIFY] RESULT: PASS` und `[E2E] PASS`.

## Data-Plane-Verifikation (P1)

Der DataRef-/Binärpfad (Phase 2) ist mit einem echten Python-Prozess
headless geprüft – Stand: **PASS, 28 Checks**):

```bash
# DataRef-Lebenszyklus: auto-handle -> describe -> doppelt materialize ->
# release -> stale error, plus kleiner Direktwert unterhalb der Schwelle
flatpak run org.godotengine.Godot --headless --path <PROJEKT> \
  --script res://tests/gdscript/data_ref_p1.gd
```

Geprüft wird: Ein numpy-Ergebnis oberhalb der `data_ref_threshold_bytes`
(Standard 16 MiB) wird als leichtgewichtiges `data_ref`-Handle geliefert und
in GDScript automatisch zum `PythonBridgeDataRef` dekodiert (Instanz wird
automatisch zugeordnet). `describe_data` liefert id/kind/dtype/shape/nbytes;
`materialize_data` liefert zweimal identische `PackedFloat32Array`-Daten;
`release_data` meldet `released=true` und markiert das Handle stale; ein
erneutes `materialize_data` liefert einen strukturierten Fehler mit
„stale“-Hinweis. Ergebnisse unterhalb der Schwelle bleiben direkte
typisierte Arrays.

## 1. Projekt im Editor öffnen

1. Starte Godot 4 und öffne dein Projekt.
2. Warte, bis der erste Import abgeschlossen ist.
3. Schau in die **Output**-Konsole unten im Editor.

**Erwartet:** Keine `Parse Error`-Zeilen mit Bezug auf
`res://addons/python_bridge/`.

Falls Parse-Fehler erscheinen: Notiere die Datei und Zeile aus der Fehlermeldung.
Die Meldung `Failed to load script ... with error "Parse error"` zeigt direkt,
welches Skript betroffen ist.

## 2. Plugin-Status prüfen

1. Öffne **Projekt → Projekteinstellungen → Plugins**.
2. Prüfe, ob **Python Bridge** aktiviert ist.

**Erwartet:** Das Plugin ist mit Häkchen gelistet und aktiviert.

## 3. Autoload prüfen

1. Öffne **Projekt → Projekteinstellungen → Autoload**.
2. Prüfe den Eintrag `PythonBridge`.

**Erwartet:**

```text
PythonBridge → *res://addons/python_bridge/core/python_bridge.gd
```

Der Stern bedeutet „Aktiviert“. Fehlt der Eintrag, siehe
[Installation](./installation#3-plugin-aktivieren).

## 4. Editor-Docks prüfen

1. Schau in die obere rechte Dock-Leiste des Editors.
2. Suche nach dem Tab **Python Bridge**.

**Erwartet:**

- Das Dock **Python Bridge** ist sichtbar.
- Es enthält die Buttons **Refresh**, **New script**, **Save**, **Run**,
  **Generate wrapper** und **Hot reload**.
- Optional ist zusätzlich das Dock **HP GDScript** sichtbar – ein
  experimentelles CPU-Werkzeug für Godot-seitige Berechnung, **kein
  Kommunikationsweg** (siehe [Kommunikationspfade](./hochleistungspfade)).

## 5. Python-Skript über das Dock anlegen

1. Klicke im Dock auf **New script**.
2. Vergib die ID `hello` und bestätige.
3. Klicke auf **Refresh**.

**Erwartet:** Die Datei existiert danach als normale Python-Datei unter:

```text
res://python_bridge/scripts/hello.py
```

Du kannst sie auch außerhalb von Godot mit einem normalen Editor öffnen.

## 6. Erste Instanz starten

Hänge das Hello-World-Skript aus
[Erste Schritte](./getting-started) an einen Node und starte die Szene
mit **F6**.

**Erwartet in der Konsole:**

- Beim ersten Start: Log-Meldungen zur `venv`-Erstellung und `pip`-Installation.
  Das dauert je nach System 1–3 Minuten und passiert nur einmal.
- Danach: die Ausgabe des Hello-World-Beispiels, etwa:

```text
[Godot] Python antwortet: Hello Godot! Python received: Hello Python
```

**Wichtig:** Der Python-Prozess wird von Godot selbst gestartet. Du musst
Python nicht vorher im Terminal ausführen.

:::note Flatpak-Editor (Flathub)

Wenn du den Godot-Editor aus Flathub nutzt, erkennt die Bridge die Sandbox
automatisch und startet venv, pip und den Python-Server auf dem Host
(`flatpak-spawn --host`). Grund: Der Sandbox-eigene Python-Interpreter ist
eine andere Version als dein Host-Python und kann eine vom Host erstellte
venv nicht verwenden.

Sollte der Start mit einer Fehlermeldung zu `flatpak-spawn` scheitern, fehlt
die Freigabe für Host-Spawns. Lösung:

```bash
flatpak override --user --talk-name=org.freedesktop.Flatpak \
  org.godotengine.Godot
```

Danach den Editor neu starten.

:::

## 7. Sauberes Beenden prüfen

1. Schließe die laufende Szene (F8 oder Fenster schließen).

**Erwartet:**

- Der Python-Prozess wird beendet, es bleibt kein hängender Prozess zurück.
- Prüfen kannst du das in einem Terminal mit
  `ps aux | grep run_server` (Linux/macOS) bzw. dem Task-Manager (Windows):
  Nach dem Szenenende sollte kein `run_server.py`-Prozess mehr laufen.

## 8. Checkliste gesamt

| Schritt | Erwartete Beobachtung | Status |
|---|---|---|
| Projekt öffnen | keine Parse-Fehler im Output | ☐ |
| Plugin aktiviert | Häkchen in den Projekteinstellungen | ☐ |
| Autoload vorhanden | `PythonBridge` → `python_bridge.gd` | ☐ |
| Dock sichtbar | Tab „Python Bridge“ rechts oben | ☐ |
| Skript anlegen | `python_bridge/scripts/hello.py` existiert | ☐ |
| Instanz starten | Hello-Antwort in der Konsole | ☐ |
| Beenden | kein `run_server`-Prozess mehr übrig | ☐ |

Wenn alle Punkte erfüllt sind, ist die P0-Verifikation bestanden und die
Bridge ist einsatzbereit für eigene Tests.

Bei einem fehlgeschlagenen Schritt hilft
[Fehlerbehebung](./fehlerbehebung) weiter.
