# Data Plane — grosse Daten & DataRef-Handles

Dieses Dokument beschreibt die **implementierte** Data-Plane der Bridge
(Phase 2, Stand der Commits `f625c7b`–`2c5fbc5`): wie grosse numerische
Daten transportiert werden, wann die Bridge automatisch ein Handle statt der
rohen Daten liefert und wie der Godot-Main-Thread geschuetzt bleibt.

```text
kleine strukturierte Daten            -> JSON im Header
grosse numerische Godot-Arrays        -> Little-Endian-Binary-Chunks
grosse numpy-Ergebnisse aus Python    -> automatisch DataRef-Handle
                                        (Materialisierung auf Anfrage)
```

---

## 1. Wann wird was verwendet?

| Situation | Verhalten |
|---|---|
| `PackedFloat32Array`/`Float64`/`Int32`/`Int64` (Godot → Python), groesser als 512 Bytes | Little-Endian-Rohbytes als Binary-Chunk mit `nbytes`-Descriptor; kommt in Python mit NumPy als `numpy.ndarray` an (ohne NumPy: raw `bytes`) |
| Dieselben Arrays, klein | JSON-Zahlenliste (unveraendert, rueckwaertskompatibel) |
| numpy-Ergebnis aus Python, kleiner als `data_ref_threshold_bytes` | direkter Binary-Chunk-Transfer, Ergebnis ist ein normales typisiertes Array |
| numpy-Ergebnis >= `data_ref_threshold_bytes` (Default 16 MiB) | Python behaelt die Daten; Godot erhaelt ein `PythonBridgeDataRef`-Handle |
| Bytes-/Blob-Ergebnisse | Binary-Chunk (unveraendert) |

Die Schwelle gilt nur fuer **eindimensionale Top-Level-numpy-Ergebnisse**
(der typische Fall fuer Punktwolken/Simulationsdaten). Verschachtelte kleine
Strukturen sind davon nicht betroffen.

Konfiguration (Facade `configure()` bzw. `project.godot`-Defaults):

```gdscript
{
    "data_ref_threshold_bytes": 16 * 1024 * 1024,  # 0 = DataRefs aus
    "max_decode_bytes_per_frame": 16 * 1024 * 1024,
}
```

`data_ref_threshold_bytes` wird beim Start der Instanz an den Python-Server
uebergeben (`--data-ref-threshold-bytes`). 0 deaktiviert die automatischen
Handles — grosse Ergebnisse werden dann wie vorher direkt uebertragen.

---

## 2. DataRef-Handles verwenden

Ein Skript, das einen grossen Datensatz erzeugt:

```python
import numpy as np

def erzeuge_punkte(n: int) -> np.ndarray:
    # 1 Mio xyz-Punkte -> 12 MiB float32
    pts = np.random.rand(n, 3).astype(np.float32)
    return pts
```

Aufruf aus Godot:

```gdscript
var r: PythonBridgeResult = await PythonBridge.call_script(
    "sim", "erzeuge_punkte", [1_000_000])
if r.is_error():
    push_error("Fehler: " + r.error_message())
    return

# Ergebnis ist EIN Handle, nicht die 12 MiB Daten:
var ref: PythonBridgeDataRef = r.value
print(ref.describe())   # {id, kind, dtype, shape, nbytes, instance, stale, ...}

# Daten erst hier holen - mehrfach moeglich, Ergebnis ist ein
# PackedFloat32Array der Form [1000000, 3]-Zeilen (2D -> Array von Zeilen):
var data: PythonBridgeResult = await PythonBridge.materialize_data(ref)
if data.is_ok():
    use_im_rendering(data.value)

# Speicher im Python-Prozess freigeben:
var rel: PythonBridgeResult = await PythonBridge.release_data(ref)
```

**Wichtig:** Nach `release_data` (oder Instanz-Stop/-Crash/-Restart) ist ein
Handle **stale**: `materialize_data` liefert dann einen strukturierten Fehler
(Kategorie `TASK_ERROR`, Meldung enthaelt „stale“), statt zu haengen oder
Muell zu liefern. `ref.is_stale()` prueft lokal ohne Roundtrip.

Die Bridge registriert Handles automatisch pro Instanz (auch bei
Auto-Zuordnung) und markiert sie beim Lifecycle-Ende als stale — es gibt
keinen manuellen GC-Aufruf.

---

## 3. API

| Funktion | Beschreibung |
|---|---|
| `await PythonBridge.materialize_data(ref, timeout_sec := 60.0)` | Holt die Daten (typisierte Arrays / bytes) |
| `await PythonBridge.release_data(ref, timeout_sec := 10.0)` | Gibt den Speicher im Python-Prozess frei, markiert stale. Liefert `{released, ref_id}`; `released=false` heisst „war schon weg/Instanz tot“ (kein Fehler) |
| `PythonBridge.describe_data(ref)` | Strukturierte Beschreibung ohne Roundtrip |
| `ref.is_stale()` / `ref.describe()` | Handle-Fragen lokal |

Protokollnachrichten (intern, fuer Transparenz): `data_get`/`data_result`,
`data_release`/`data_ack`. Der Python-Server haelt die Daten in einem
`DataStore` pro Verbindung; Verbindungsende raeumt automatisch auf (Crash-
Cleanup).

---

## 4. Godot-Main-Thread-Schutz

Eingehende WebSocket-Pakete werden roh zwischengepuffert und nur bis zu
`max_decode_bytes_per_frame` Bytes pro Frame dekodiert
(`BridgeConnectionManager.drain(byte_budget)`). Eine einzelne Nachricht ist
atomar und wird immer vollstaendig dekodiert (garantiert Fortschritt); ein
Schub grosser Antworten verteilt sich dadurch ueber mehrere Frames statt
einen Frame zu blockieren. `BridgeConnectionManager.last_drain_bytes` liefert
Telemetrie fuer Benchmarks.

Progressive/gestreamte Chunk-Materialisierung einzelner Datensaetze sowie
Progress-Events sind noch nicht umgesetzt (naechste Ausbaustufe); die
Dekodierung pro Frame ist begrenzt, die Materialisierung eines Datensatzes
erfolgt als ein (budgetierter) Schritt.

---

## 5. Validierung & Korruptionserkennung

Numerische Descriptoren tragen `nbytes`. Beide Decoder (GDScript und Python)
pruefen die deklarierte Groesse gegen die tatsaechliche Chunk-Groesse bevor
typisierte Arrays materialisiert werden:

- GDScript: Mismatch -> `push_error` + leeres Typed Array (kein Muell);
- Python: Mismatch -> raw-bytes-Fallback (kein stiller Garbage-ndarray).

Damit erzeugen verwaiste oder verfaelschte Chunks keine falschen Daten.

---

## 6. Benchmarks / Messungen

`tools/benchmark.py` reproduziert die Ausgangswerte der Bottleneck-Analyse
(z. B. ~2,5x JSON-Overhead bei 1 Mio Float32, ~331 ms Compile fuer 1-MB-
Quelle). Fuer die neuen Pfade liegen die entscheidenden Fragen bei: Byte- vs.
Zeitbudget pro Frame (Default 16 MiB) und der Crossover-Punkt
direkter Chunk-Transfer vs. DataRef — beide sind konfigurierbar und sollten
fuer die konkrete Zielhardware gemessen werden, bevor die Defaults
festgeschrieben werden.
