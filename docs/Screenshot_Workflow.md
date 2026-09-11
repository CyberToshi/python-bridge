# Screenshots für die Doku aufnehmen (Flameshot-Workflow)

Dieser Workflow erzeugt die nummerierten Live-GUI-Screenshots, die auf der
Docusaurus-Seite **„Godot-Integration (Editor-UI)“** angezeigt werden
(`docs-site/docs/editor-ui.md`).

**Prinzip:** Du fotografierst deinen echten Godot-Editor mit Flameshot, fügst
direkt im Bild rote Kreise/Pfeile mit Nummern (①, ②, …) hinzu und speicherst
die Datei unter dem **fest vorgegebenen Namen** in
`docs-site/static/img/ui/`. Dort liegen aktuell Platzhalter-PNGs mit exakt
denselben Dateinamen – sie werden **1:1 überschrieben**, die Doku ist danach
sofort vollständig.

---

## 1. Voraussetzungen

- Godot-Editor (GUI) mit geöffnetem Projekt `python_bridge`.
- Plugin „Python Bridge“ ist aktiviert (Projekt → Projekt-Einstellungen → Plugins).
- Flameshot installiert:

```bash
# Debian/Ubuntu (empfohlen, native X11/Wayland-Unterstützung)
sudo apt install flameshot

# oder Flatpak
flatpak install flathub org.flameshot.Flameshot
```

Hinweis: Läuft dein Godot selbst als Flatpak, nimm die **native**
Flameshot-Installation (nicht das Flatpak), damit Screenshot-Regionen und
Annotations-Tool zuverlässig funktionieren.

## 2. Aufnahme pro Screenshot

1. Godot-Editor in den Zielzustand bringen (siehe Tabelle unten).
2. Terminal im Projektordner `python_bridge`:

```bash
flameshot gui -p docs-site/static/img/ui/ui-02-dock-uebersicht.png
```

3. Mit der Maus die gewünschte Region aufziehen.
4. Im Flameshot-Editor annotieren:
   - **Roter Kreis / Pfeil** um das Element,
   - **Text** mit der Nummer (①, ②, …) direkt daneben.
5. Speichern (Enter) – Flameshot schreibt an den `-p`-Pfad.

> Tipp: `-c` zusätzlich übergeben kopiert das Bild zusätzlich in die
> Zwischenablage. Mit `flameshot gui --raw` kannst du ohne Zwischenablage
> arbeiten. Wiederhole Schritt 2–5 für jede Zeile der Tabelle.

## 3. Aufnahme-Manifest (Datei → Zielzustand → Nummern)

Alle Dateien gehören nach `docs-site/static/img/ui/`.

| Datei | Zielzustand im Godot-Editor | Nummern / Annotation |
|---|---|---|
| `ui-01-plugin-aktivieren.png` | Projekt → Projekt-Einstellungen → **Plugins**, Liste mit „Python Bridge“ | ① Plugin-Zeile, ② Checkbox „Aktivieren“ |
| `ui-02-dock-uebersicht.png` | Editor normal, Dock **„Python Bridge“** rechts oben; **zwei Skripte in Tabs geöffnet**, eins davon ungespeichert (`*`) | ① Refresh, ② New script, ③ Statuszeile, ④ Skriptliste, ⑤ Tab-Leiste + Code-Editor (mehrere Dateien), ⑥ Save, ⑦ Run, ⑧ Generate wrapper, ⑨ Hot reload, ⑩ Log |
| `ui-03-neues-script.png` | Dialog **„New Python script“** offen, Eingabe `hello` | ① Klick auf New script, ② Eingabefeld, ③ OK |
| `ui-04-hello-py-editor.png` | `hello.py` im Dock-Editor geöffnet, Liste zeigt `hello` | ① Skript in Liste, ② Python-Code, ③ Save-Button |
| `ui-05-run-log.png` | `hello.py` offen, **Run** gedrückt, Log mit grüner `ok:`-Zeile | ① Run-Button, ② Log-Zeile `ok: …`, ③ Status `run ok` |
| `ui-06-live-ausgabe.png` | Szene `example/hello/hello_world.tscn` läuft (F6), **Output-Panel** unten | ① Antwort-Zeile „Python antwortet“, ② laufende Frame-Updates |
| `ui-07-wrapper-generiert.png` | `hello.py` offen, **Generate wrapper** gedrückt, Dateisystem-Dock sichtbar | ① Generate wrapper, ② Log `wrapper written: …`, ③ Datei `hello_wrapper.gd` |
| `ui-08-hp-dock.png` | Beide Docks sichtbar: **Python Bridge** + **HP GDScript** | ① HP-GDScript-Dock (Compute-Werkzeug, kein Transport) |

### Konkreter Ablauf für die wichtigsten Aufnahmen

1. **ui-01:** Projekt → Projekt-Einstellungen → Plugins öffnen, Plugin-Zeile markieren.
2. **ui-02:** Editor normal laufen lassen (Plugin aktiv). Werksskript anlegen
   oder `python_bridge/scripts/hello.py` vorhanden haben.
3. **ui-03/ui-04:** „New script“ → `hello` → Code einfügen (Beispiel aus der
   Doku-Seite) → Save.
4. **ui-05:** „Run“ klicken und warten, bis die grüne `ok:`-Zeile im Log steht.
5. **ui-06:** `example/hello/hello_world.tscn` öffnen und mit **F6** starten;
   das Output-Panel zeigt `[Godot] Python antwortet: …`. Screenshot im
   laufenden Zustand.
6. **ui-07:** „Generate wrapper“ klicken; im Dateisystem-Dock
   `python_bridge/wrappers/hello_wrapper.gd` aufklappen.
7. **ui-08:** Beide Docks andocken (Python Bridge + HP GDScript).

## 4. Prüfen

```bash
cd docs-site && ls static/img/ui/
# → 8 PNG-Dateien, alle ohne „Platzhalter“-Optik
```

Danach die Doku-Seite im Browser neu laden:
http://localhost:3000/docs/editor-ui

Läuft der Dev-Server nicht: `cd docs-site && npm start`.

Für eine **Produktions-/Deploy-Ausgabe** nach dem Austausch der Bilder einmal
neu bauen, da Docusaurus statische Bilder mit Inhalts-Hash einbettet:

```bash
cd docs-site && npm run build
```

## 5. Bildformat-Empfehlung

- Region großzügig, aber nur bis zum relevanten Inhalt wählen.
- PNG (Standard von Flameshot) – 16:9-förmige Ausschnitte sehen in der Doku
  am besten aus, die Seite skaliert aber jede Größe.
- Falls ein Bild neu aufgenommen wird: **immer denselben Dateinamen** wählen,
  damit keine Links in der Doku brechen.
