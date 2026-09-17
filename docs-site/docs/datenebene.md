---
sidebar_position: 7
title: Daten, Typen & große Datensätze
description: Wie Werte zwischen Godot und Python wandern – Typ-Mapping, Binary-Chunks, DataRefs.
---

# Daten, Typen & große Datensätze

Damit du weißt, was zwischen Godot und Python hin- und herwandert und wie
große Datenmengen behandelt werden.

## 1. Typ-Mapping (automatisch)

Kleine, strukturierte Werte reisen als JSON; **große homogene numerische
Arrays und Bytes reisen als rohe Little-Endian-Binär-Chunks** (nie als lange
JSON-Zahlenlisten). Kleine numerische Godot-Packed-Arrays werden als
JSON-Zahlenlisten kodiert. Die Konvertierung ist automatisch und beidseitig.

| Godot | Python | Hinweis |
|---|---|---|
| `null` | `None` | |
| `bool` | `bool` | |
| `int` | `int` | Godot-Int ist 64 Bit |
| `float` | `float` | |
| `String` | `str` | |
| `Vector2` / `Vector3` / `Vector4` | Liste mit 2 / 3 / 4 Zahlen | `(x,y)`, `(x,y,z)`, `(x,y,z,w)` |
| `Color` | Liste mit 4 Zahlen | `(r,g,b,a)` |
| `Transform3D` | Liste mit 12 Zahlen | Basis 9 + Ursprung 3 |
| `Array` | `list` | |
| `Dictionary` | `dict` | **Schlüssel als String empfohlen** |
| – | `tuple`, `set` | kommen als Godot-`Array` an |
| `PackedByteArray` | `bytes` / `bytearray` | Binär-Chunk |
| `PackedFloat32Array` | klein: `list` aus Zahlen; groß: numpy-`float32`-Array (sofern NumPy installiert, sonst Rohbytes) | Große → Binär-Chunk |
| `PackedFloat64Array` | klein: `list`; groß: numpy-`float64` | Große → Binär-Chunk |
| `PackedInt32Array` | klein: `list`; groß: numpy-`int32` | Große → Binär-Chunk |
| `PackedInt64Array` | klein: `list`; groß: numpy-`int64` | Große → Binär-Chunk |
| – | numpy `ndarray` | 1-D → typisiertes Packed-Array; mehrdimensional → Array von Zeilen |
| – | anderes Objekt | kommt als `String` (repr) bzw. `null` an (`pyobject`/`unsupported`) |

Große strukturierte Daten sollten nicht in `Dictionary`/`Array`-Form durch
JSON wandern – dafür gibt es DataRefs (unten).

## 2. Die drei Transportwege (automatisch gewählt)

| Größe / Art | Weg |
|---|---|
| kleine Skalare & Strukturen | JSON inline |
| Bytes, Bilder, homogene numerische Arrays | Binär-Chunks (Little Endian, mit `nbytes`-Validierung) |
| große numpy-Ergebnisse (ab Schwelle) | **DataRef-Handle** – Daten bleiben im Python-Prozess bzw. liegen als Datei |

## 3. DataRefs – große Ergebnisse ohne Kopie

Ein numpy-Ergebnis ab `data_ref_threshold_bytes` (Default **16 MiB**) wird
**nicht** direkt über den WebSocket geschickt. Python meldet nur einen
Deskriptor, Godot erzeugt daraus automatisch einen `PythonBridgeDataRef`
(Handle). Die Daten werden erst auf deine Anfrage geholt.

```gdscript
var r := await PythonBridge.execute(
    "import numpy as np\nresult = np.arange(4_200_000, dtype=np.float32)",
    {}, "default", 30.0)

if r.is_ok() and r.value is PythonBridgeDataRef:
    var ref: PythonBridgeDataRef = r.value
    print(ref.describe())          # {id, kind: ndarray, dtype: float32,
                                   #  shape: [4200000], nbytes: 16800000, …}

    # Daten holen (mehrfach erlaubt) – bei großen Werten über die Datei,
    # sonst über Binär-Chunks:
    var mat: PythonBridgeResult = await PythonBridge.materialize_data(ref, 5.0)
    if mat.is_ok():
        var arr: PackedFloat32Array = mat.value
        print(arr[100_000])        # echtes Array, kein Handle mehr

    # Freigeben: räumt Speicher (und ggf. die Datei) auf
    await PythonBridge.release_data(ref)
```

### Wichtige Regeln

- **Mehrfach materialisieren ist erlaubt.** Der Handle bleibt gültig, bis du
  ihn freigibst oder die Instanz endet.
- **`release_data` ist deine Pflicht.** Danach ist der Handle `stale`
  (`is_stale()`), weitere Materialisierungen liefern einen strukturierten
  Fehler statt Müll.
- **Instanz-Ende macht Handles ungültig.** Crash, Neustart oder `stop()`
  → alle Handles dieser Instanz sind `stale`; `materialize_data` meldet
  einen Fehler. Erzeuge in dem Fall einfach ein neues Ergebnis.
- **Ohne Freigabe räumt der Prozess** beim Verbindungs-/Instanzende auf –
  verlass dich aber nicht darauf, sondern gib bewusst frei.

### Was intern passiert (Transparenz)

1. Python hält die Daten im `DataStore` und meldet den Deskriptor.
2. `materialize_data` sendet `data_get` mit `want: "file"`. Für große
   Datensätze schreibt der Server eine Datei
   `<workspace>/tmp/data/data-<tag>-<id>.bin` (mit SHA-256 im Deskriptor)
   und liefert nur Pfad/Größe/Hash – **die Daten wandern nicht über den
   WebSocket**.
3. Godot liest die Datei **chunkweise per Frame** (Budget:
   `file_read_bytes_per_frame`, Default 16 MiB), prüft Größe + SHA-256 und
   dekodiert am Ende in den Zieltyp. Dadurch bleibt der Main-Thread auch bei
   Hunderten MB ruhig.
4. `release_data` entfernt die Datei und gibt den Speicher frei.

Fehler (fehlende/korrupte Datei, Prüfsummen-Mismatch) kommen als
`SERIALIZATION_ERROR` mit klarer Meldung zurück.

## 4. Godot → Python: große Daten senden

Auch für den Weg **in** Python gilt: große Daten nicht als JSON-Liste
stecken. Übergib typisierte Packed-Arrays direkt als Argument – kleine
werden als JSON-Zahlenliste kodiert, **große automatisch als Binär-Chunk**:

```gdscript
var big := PackedFloat32Array()
big.resize(1_000_000)
# … füllen …
var r := await PythonBridge.call_script(
    "analyse", "nimm_array", [big], {}, "default", 30.0)
```

```python
def nimm_array(a) -> dict:
    # a ist: klein → Python-Liste, groß → numpy-Array (mit NumPy)
    # bzw. Rohbytes (Fallback ohne NumPy). np.asarray normalisiert alles:
    import numpy as np
    arr = np.asarray(a, dtype=np.float32)
    return {"n": int(arr.size), "mittel": float(arr.mean())}
```

**Empfehlung:** Für numerische Arbeit `numpy` in die venv installieren
(`PythonBridge.configure({"dependencies": ["numpy"]})`), damit große Chunks
auf Python-Seite als echte numpy-Arrays ankommen statt als Rohbytes.

:::note Achtung bei Argumentgrößen
`max_payload_bytes` (Default 64 MiB) begrenzt eine einzelne Task-Nachricht.
Für sehr große Sende-Daten besser in Stücken arbeiten oder das Limit für
deinen Anwendungsfall anpassen ([Konfiguration](./konfiguration)).
:::

## 5. Ergebnisgrößen-Begrenzungen

| Limit | Default | Wirkung |
|---|---|---|
| `max_payload_bytes` | 64 MiB | Max. Task-Nachricht (Argumente + Source) |
| `max_result_bytes` | 256 MiB | Max. Ergebnis-Nachricht |
| `data_ref_threshold_bytes` | 16 MiB | Ab hier werden numpy-Ergebnisse zu DataRefs |
| `max_decode_bytes_per_frame` | 16 MiB | Decode-Budget pro Frame (Main-Thread-Schutz) |
| `file_read_bytes_per_frame` | 16 MiB | Lese-Budget pro Frame bei Datei-Transport |
| `max_stdout_bytes` / `max_stderr_bytes` | 1 MiB | Capturing-Grenzen für print()/stderr |

Überschreitet eine **Antwort** `max_result_bytes`, kommt ein
`SERIALIZATION_ERROR` – erhöhe das Limit oder nutze DataRefs. Übersteigt ein
**Argument** `max_payload_bytes`, wird der Task schon beim Einreichen
abgelehnt (`TASK_ERROR`).

Verwandt: [Python-Seite verstehen](./python-seite) · [API-Referenz](./api) ·
[Konfiguration](./konfiguration)
