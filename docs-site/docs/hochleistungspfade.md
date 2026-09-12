---
sidebar_position: 7
title: Kommunikationspfade
description: Genau zwei Wege zwischen Godot und Python – WebSocket für Kontrolle, Shared Memory/IPC für große Daten. Ehrlicher Status, keine erfundenen Pfade.
---

# Kommunikationspfade

Zwischen Godot und Python gibt es genau **zwei Wege**. Alles andere
(GDScript2All, Cluster) ist entweder ein Werkzeug oder benutzt einen dieser
Wege – kein dritter Transportweg.

```text
Pfad 1 (verifiziert)        Pfad 2 (Konzept, lokal)
GDScript ──WebSocket──> Python      GDScript ─[C++-Shim]─ Shared Memory ─> Python
   Kontrolle + kleine Daten             große numerische Daten
   funktioniert auch über Netz          nur auf derselben Maschine
```

| Pfad | Status |
|---|---|
| 1: WebSocket | **Implementiert und End-to-End verifiziert** (Hello-World, Task-, Batch-, Fehlerpfad, DataRef-Lifecycle grün) |
| 2: Shared Memory / IPC | **Konzept + Python-Basis**: Shared-Memory-Registry existiert und ist in Python getestet; der kleine C++-Shim auf Godot-Seite fehlt noch |

---

## 1. Warum genau zwei Wege?

Daten zwischen zwei Prozessen müssen eine Prozessgrenze überqueren – per
Kernel (Socket) oder per gemeinsamem Mapping (Shared Memory). Daraus
ergeben sich zwei grundverschiedene Stärken:

- **WebSocket/JSON**: einfach, isoliert, funktioniert über Netz. Kostet
  pro Nachricht Serialisierung + TCP-Roundtrip. Ideal für Steuerung,
  Tasks und kleine strukturierte Daten.
- **Shared Memory**: dieselben physischen RAM-Seiten in beiden
  Adressräumen – kein Kopieren beim Zugriff. Ideal für große, wiederholt
  gelesene Binärfelder. Nur lokal, braucht Synchronisation.

**Wichtig:** GDScript selbst kann kein `mmap` und keinen rohen Zeiger –
es gibt keine syscall-API in der Sprache. Der Shared-Memory-Pfad braucht
deshalb auf Godot-Seite einen **kleinen, handgeschriebenen
GDExtension-Shim** (Region mappen, Header prüfen, einmal ein
`PackedFloat32Array` füllen). Das ist ein schmales Hilfsstück, **kein**
Sprach- oder Pfadkonzept.

### Analogie: Briefe versus Schwarzes Brett

```text
Pfad 1 = Briefverkehr                Pfad 2 = gemeinsames Brett
Godot ─(JSON, TCP)─► Python          ┌────────────────────────────┐
                                      │ Header: id, dtype, nbytes │
                                      │ Bytes: 0.0 0.5 1.0 …      │
                                      └────────────────────────────┘
                                      C++/Python sehen DIESELBEN
                                      Seiten → keine Datenkopie
```

Der Haken am Brett: **kein Brief = keine Benachrichtigung.** Der
Schreiber muss per WebSocket melden „fertig“ bzw. „freigeben“. Deshalb
ergänzen sich beide Wege: WebSocket bleibt der Kontrollkanal, das Brett
trägt die großen Daten.

### Ehrliche Größenordnungen (Richtwerte, keine Messungen)

| | Pfad 1 (WebSocket) | Pfad 2 (Shared Memory) |
|---|---|---|
| Kleiner Call | ~0,2–2 ms | ~0,05–0,5 ms (Handle + Header-Check) |
| Große Daten | schlecht: Bytes durch JSON + TCP | sehr gut: RAM-Mapping, keine Kopie zwischen C++ und Python |
| Dominanter Kostenpunkt | Serialisierung + Allokation | Synchronisation + Lebenszyklus |
| Über Netz (Cluster) | ja | nein |

---

## 2. Pfad 1: WebSocket (verifiziert)

### Datenfluss

```text
Godot-Mainthread                    Python-Prozess
  await call/execute                  Handler liest Frame
   → TaskManager (Queue)              → Worker-Thread führt Code aus
   → pro Frame gepollt                → Serializer → Antwort
   → send_text (TCP 127.0.0.1)  ────►│
   ◄─────────────────────────────────┘ drain(Byte-Budget pro Frame)
   → task.done → PythonBridgeResult   (Main-Thread geschützt)
```

- Python-Rechnen bleibt voll nutzbar; der Overhead liegt *um* den Call
  (TCP + JSON beidseitig), nicht in der Berechnung.
- Dafür: saubere Prozessisolation, einfach debuggen, remotefähig.
- **Wann falsch:** wenn Millionen Zahlen pro Sekunde fließen und das
  Ergebnis nur als großes Binärfeld konsumiert wird – dann siehe Pfad 2
  (bzw. heute schon: DataRef-Handles mit Datei-Transport).

### Setup im Editor (klickgenau)

1. **Projekt → Projekteinstellungen → Plugins**: Python Bridge aktivieren.
2. Autoload `PythonBridge` prüfen (Projekteinstellungen → Autoload).
3. Rechts oben: Dock **Python Bridge** → **New script** → ID `hello`.
4. In `res://python_bridge/scripts/hello.py`: `say_hello(message)` anlegen.
5. Szene `res://example/hello/hello_world.tscn` öffnen und **F6** drücken.
6. Konsole: `[hello] Python antwortet: Hello Godot! Python received: Hello Python`.
   Erster Start erzeugt die venv und installiert `websockets` (1–3 Min).

> Flatpak-Editor: Die Bridge erkennt die Sandbox und startet Python auf dem
> Host (`flatpak-spawn --host`). Fehlt die Berechtigung, siehe
> [Fehlerbehebung](./fehlerbehebung).

### Code (vollständig, läuft nachweislich)

`res://example/hello/hello_bridge.gd` (Kurzfassung):

```gdscript
extends Node
const PYTHON_SCRIPT := "hello"
const PYTHON_INSTANCE := "default"

func _ready() -> void:
    var started: PythonBridgeResult = await PythonBridge.start_instance(PYTHON_INSTANCE)
    if started.is_error():
        push_error("Start fehlgeschlagen: " + started.error_message())
        return
    var result: PythonBridgeResult = await PythonBridge.call_script(
        PYTHON_SCRIPT, "say_hello", ["Hello Python"], {}, PYTHON_INSTANCE, 30.0)
    if result.is_ok():
        print("[Godot] Python antwortet: ", result.value)
```

`res://python_bridge/scripts/hello.py`:

```python
def say_hello(message: str) -> str:
    """Normale Python-Funktion – kein Bridge-spezifischer Code nötig."""
    return f"Hello Godot! Python received: {message}"
```

Zeile für Zeile: `start_instance` startet Python und wartet auf READY;
`call_script` baut einen Task (Funktion + Argumente); `await` wartet auf
`task.done`; `result.value` ist die Antwort.

---

## 3. Pfad 2: Shared Memory / IPC (Konzept)

### Wie es auf Betriebssystemebene funktioniert

1. Ein Prozess ruft `mmap` (bzw. `shm_open` + `mmap`) auf; die MMU mappt
   **dieselben physischen RAM-Seiten** in beide Adressräume.
2. Ein **Metadaten-Header** am Regionenanfang beschreibt den Inhalt:
   `magic, id, dtype, nbytes, Zustand (erstellt/befüllt/bereit/frei),
   Checksumme, Besitzer`.
3. Lesen/Schreiben ist ein normaler Speicherzugriff; **Synchronisation
   ist das eigentliche Problem** (wer schreibt wann, wer liest wann).
4. Aufräumen: Der Besitzer gibt frei; verwaiste Regionen räumt der
   Serverstart auf (Muster existiert bereits bei den DataRef-Dateien).

```text
Godot/C++-Shim                  physischer RAM              Python
┌──────────────┐   mmap   ┌──────────────────┐   mmap   ┌──────────────┐
│ ptr → Header │─────────►│ gleiche Seiten   │◄─────────│ Header ← ptr │
└──────────────┘          └──────────────────┘          └──────────────┘
```

### Die unbequeme Wahrheit über „Zero-Copy“

Zero-Copy ist erreichbar **zwischen C++ und Python**. Nicht bis in eine
GDScript-Variable: `PackedFloat32Array` ist ein engine-verwalteter Puffer –
der Shim füllt ihn **einmal** aus dem Mapping. Diese eine Kopie ist
unvermeidbar und der Preis, den die GDScript-API kostet.

### Projektstand und nächster Schritt

- Python-Seite: Shared-Memory-Registry (`ipc_region`) getestet.
- Godot-Seite: **noch offen** – der schmale GDExtension-Shim
  (Konzeptskizze unten). Bis dahin übernehmen **DataRef-Handles mit
  Datei-Transport** die Aufgabe großer Daten (verifiziert, 36/36 Checks).

Konzeptskizze des Shims (kein fertiger Projektcode):

```cpp
// Region mappen + Header prüfen + einmal in einen Godot-Puffer kopieren.
void* region = mmap(0, header.nbytes, PROT_READ, MAP_SHARED, fd, 0);
if (region->magic != PB_MAGIC || region->dtype != DT_F32) return ERR_INVALID_DATA;
PackedFloat32Array out;
out.resize(region->items);
memcpy(out.ptrw(), region->payload, region->nbytes);
```

---

## 4. Was bewusst KEIN Pfad ist

- **GDScript2All / C++-Übersetzung:** kein Kommunikationsweg. Es kann
  Godot-seitige *Berechnung* beschleunigen (das HP-Dock ist im Editor
  vorhanden, experimentell). Am Transport ändert es nichts – WebSocket
  bleibt gleich schnell, und „übersetzen“ ist keine Datenübertragung.
  Beides getrennt zu denken verhindert die Verwechslung „ich übersetze,
  also ist mein Transport schnell“.
- **Cluster:** verteiltes Rechnen ist seit v0.4.0 **umgesetzt**
  ([Cluster](./cluster)), aber es ist **kein dritter Transportweg**: der
  Cluster benutzt Pfad 1 (WebSocket) über das Netz. Für ihn gilt außerdem:
  Shared Memory ist unbrauchbar (kein gemeinsamer RAM über Maschinen) –
  Pfad 2 bleibt eine Sache innerhalb *eines* Rechners.
- **Docker / Container-Orchestrierung:** weiterhin nicht Teil des Werkzeugs.
  Der Cluster ist bewusst für dasselbe LAN gebaut, nicht für Cloud-Betrieb
  (`docs/CLUSTER_INTEGRATION_PLAN.md` bleibt als Planungstext erhalten).

---

## 5. Kernaussagen

1. WebSocket + JSON ist für Kontrolle und kleine Daten richtig und
   verifiziert.
2. Shared Memory eliminiert die Datenkopie zwischen C++ und Python –
   für große lokale Felder; die letzte Kopie in ein GDScript-Array
   bleibt unvermeidbar.
3. GDScript2All beschleunigt Rechnen, nie Transport – und ist deshalb
   kein dritter Pfad.
4. Transportwahl nach Daten + Größe: Kontrolle → WebSocket, große
   lokale Daten → Shared Memory (bis dahin: DataRef/Datei), Cluster →
   WebSocket.
