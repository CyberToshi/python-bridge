# Python Bridge — Architekturplan der nächsten Generation

**Status:** Konzept- und Umsetzungsplan, keine vollständige Implementierung

**Ausgangspunkt:** aktuelle Python Bridge v0.2.x, Protokoll v2

**Zielplattformen:** Godot 4.x, Windows, Linux, macOS, Python 3.8+

Dieses Dokument beschreibt die nächste Architekturentwicklung der Python Bridge. Es ersetzt nicht die Beschreibung der aktuell implementierten v0.2-Architektur in `docs/ARCHITEKTUR.md`. Es definiert, wie der bestehende Kern schrittweise erweitert werden soll, ohne WebSockets, Task Manager, Scheduler, Lifecycle-Management oder die Python-zentrierte API unnötig zu verwerfen.

Die Architektur ist ausdrücklich in Stufen gegliedert. Nicht jede hier beschriebene Fähigkeit muss gleichzeitig implementiert werden.

---

## 0. Architekturregeln

Die folgenden Regeln sind verbindlich:

1. **Python bleibt Python.** Python-Dateien bleiben normale `.py`-Dateien. Die Bridge übersetzt keinen Python-Bytecode in GDScript und umgekehrt.
2. **WebSocket bleibt Control Channel.** Kleine Steuer- und Metadaten-Nachrichten bleiben über WebSocket und JSON nachvollziehbar.
3. **Control Plane und Data Plane werden getrennt.** Große numerische Daten dürfen einen anderen Transport verwenden als Steuerbefehle.
4. **Kein Transport darf eine Blackbox sein.** Die Bridge muss ihre Entscheidung intern protokollieren können: Datentyp, geschätzte Größe, gewählter Transport, Fallback-Grund.
5. **Kein unkontrolliertes Warten im Godot-Main-Thread.** Weder Python-Ausführung noch große Daten-Dekodierung dürfen einen unbeschränkten Frame-Stall verursachen.
6. **Persistenter Zustand benötigt stabiles Routing.** Ein persistenter Python-Kontext darf nicht zufällig zwischen Prozessen wechseln.
7. **Timeout bedeutet nicht automatisch Prozessabbruch.** Ein sicherer Abbruch von beliebigem Python-Code ist in einem Thread nicht garantiert. Harte Isolation erfolgt über Prozesse.
8. **Neue Technologien benötigen einen konkreten Vorteil.** Shared Memory, mmap, Arrow oder native Erweiterungen werden nur eingeführt, wenn Messungen zeigen, dass der bestehende Transport den Use Case begrenzt.
9. **Fallbacks sind Pflicht.** Wenn ein Transport nicht verfügbar ist, fällt die Bridge auf Binary Frames oder JSON zurück.
10. **Erst messen, dann optimieren.** Alle Schwellenwerte für JSON, Binary, mmap und Shared Memory bleiben konfigurierbar und werden durch Benchmarks validiert.

### Prioritätsbegriffe

| Begriff | Bedeutung |
|---|---|
| **Notwendig** | Behebt einen bereits nachgewiesenen Kernengpass und gehört in die nächste stabile Ausbaustufe. |
| **Sinnvoll** | Voraussichtlich hoher Nutzen, aber mit größerem Änderungsumfang oder zusätzlicher Messung. |
| **Optional** | Nur für bestimmte Workloads oder Plattformen erforderlich. |
| **Zukünftige Ausbaustufe** | Erst nach stabiler Basis und Messdaten umsetzen. |

---

# 1. Architektur-Zielbild

## 1.1 Zielarchitektur

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Godot Main Thread                                                    │
│                                                                      │
│ PythonBridge Facade                                                 │
│ ├─ TaskManager: Queue, Priorität, Timeout, Retry, Backpressure       │
│ ├─ Scheduler: Routing, Slots, Batching, Frame-Budgets               │
│ ├─ ScriptRegistry: Source-Hash, DEFINE/CALL, Hot Reload              │
│ ├─ DataObjectRegistry: Handles, Refcount, Materialisierung           │
│ └─ FrameBudgetManager: Zeit-/Byte-Budget für eingehende Daten         │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                 Control Plane│ WebSocket + JSON
                               │
┌──────────────────────────────▼───────────────────────────────────────┐
│ Python Control Server                                                │
│ ├─ Handshake / Capabilities                                         │
│ ├─ Script Registry                                                   │
│ ├─ Task Router                                                       │
│ ├─ Handle/Data Registry                                              │
│ └─ Worker Supervisor                                                 │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                 Data Plane   │ automatisch ausgewählt
                               │
       ┌───────────────┬───────┴────────┬────────────────┐
       │ JSON          │ Binary Frames  │ Handle / mmap  │ Shared Memory
       │ kleine Daten  │ mittelgroß     │ große Daten    │ optional
       └───────────────┴────────────────┴────────────────┴──────────────

┌──────────────────────────────────────────────────────────────────────┐
│ Python Execution Plane                                               │
│                                                                      │
│ Python-Prozess / Instanz                                             │
│ ├─ ScriptRuntime: Source → Hash → Code Object → Context              │
│ ├─ Worker Pool oder serieller Worker                                 │
│ ├─ Context-Affinität und Kontext-Locks                               │
│ ├─ Object Store für große Daten                                      │
│ └─ Watchdog / Prozess-Recovery                                       │
└──────────────────────────────────────────────────────────────────────┘
```

## 1.2 Öffentliche API bleibt stabil

Die Entwickler-API soll möglichst gleich bleiben:

```gdscript
await PythonBridge.start_instance("default")
var result = await PythonBridge.call_script("analysis", "calculate", [input])
```

Die Transportauswahl bleibt intern. Für fortgeschrittene Anwendungen kommt eine optionale Daten-API hinzu:

```gdscript
var data_ref = result.value
var local_data = await PythonBridge.data.materialize(data_ref)
PythonBridge.data.release(data_ref)
```

Der normale Entwickler muss nicht selbst `use_shared_memory = true` oder `use_binary = true` setzen.

## 1.3 Drei getrennte Ebenen

### Control Plane

WebSocket und JSON für:

- `HELLO` / Capability Negotiation
- `DEFINE_SCRIPT`
- `CALL_FUNCTION`
- `START_TASK`
- `CANCEL`
- `GET_STATUS`
- `HOT_RELOAD`
- Handle-Erzeugung, Referenzen und Freigaben
- Fortschritts- und Fehler-Metadaten

### Data Plane

Automatisch gewählter Transport für Nutzdaten:

- Inline-JSON
- Binary Frame
- gestreamte Binary Frames
- dateibasierter mmap-/Chunk-Transport
- Shared Memory über optionale native Unterstützung
- Handle ohne Datenkopie

### Execution Plane

Ausführung, Isolation und Wiederverwendung:

- Script Registry
- Compile Cache
- persistente Contexts
- Worker und Worker-Slots
- Prozessgruppen
- Watchdog und Recovery

---

# 2. Die größten aktuellen Bottlenecks

Die vollständige technische Analyse steht in `docs/BOTTLENECKS.md`. Die wichtigsten Engpässe sind:

| ID | Problem | Aktuelle Ursache | Hauptwirkung |
|---|---|---|---|
| A1 | Serielle Python-Ausführung | `ThreadPoolExecutor(max_workers=1)` und `max_inflight_per_instance = 1` | geringer Durchsatz pro Instanz |
| A2 | Runaway Task | Timeout verwirft nur das Ergebnis; Worker läuft weiter | gesamte Instanz kann blockieren |
| A3 | Source-Overhead | Datei lesen, Source senden und hashen bei jedem Call | unnötiger CPU-, I/O- und Netzwerkaufwand |
| A4 | Wiederholte Kompilierung | `run()` kompiliert jedes Mal neu | zusätzliche Latenz bei häufigen Ausführungen |
| A5 | Main-Thread-Decoding | vollständiges Parsen in `drain()`/`_process` | Frame-Stalls bei großen Ergebnissen |
| A6 | Numerische Arrays über JSON | Packed-Arrays werden als JSON-Zahlenlisten kodiert | hohe Datenmenge und viele Allokationen |
| A7 | Elementweise Serialisierung | rekursive Tag-/Objekt-Erzeugung | CPU- und Speicher-Overhead |
| A8 | Queue-Timeout | Timeout beginnt bei Task-Erstellung | Tasks können vor Start ablaufen |
| A9 | Instanz-Routing | Auto-Zuordnung ohne Context-Affinität | geteilter Zustand wird fragmentiert |
| D1 | JSON-Overhead | JSON für fast alle Nutzdaten | feste Kosten pro Nachricht |
| D2 | Binary-Builder | wiederholte Bytes-Konkatenation | unnötige Kopien bei vielen Chunks |
| D4 | Unbegrenzte Ergebnisse | keine robuste Ergebnis-/stdout-Grenze | Speicher- und Frame-Risiko |

Die Architektur reagiert nicht mit zwölf isolierten Patches. Vier übergeordnete Konzepte lösen mehrere Ursachen gleichzeitig:

1. **Content-addressed Script Registry** löst A3, A4 und Teile von A9.
2. **Intelligenter Data Plane mit Handles** löst A5, A6, A7, D1 und D4.
3. **Context-aware Scheduler mit Worker-/Prozessgruppen** löst A1, A2, A8 und A9.
4. **Frame-Budget- und Stream-Schicht** schützt Godots Main-Thread bei großen Ergebnissen.

---

# 3. Lösung für jeden Bottleneck

Für jede Entscheidung gilt das Schema:

```text
Problem
→ Ursache
→ Lösung
→ erwarteter Vorteil
→ neue Nachteile/Risiken
→ Priorität
```

## 3.1 Serielle Python-Ausführung

**Problem:** Eine Instanz verarbeitet effektiv nur einen Task gleichzeitig.

**Ursache:** Ein Worker-Thread und `max_inflight_per_instance = 1`.

**Lösung:** `workers_per_instance` als konfigurierbare Fähigkeit einführen. Tasks gleicher Context-Affinität bleiben serialisiert; Tasks verschiedener Contexts dürfen unterschiedliche Worker-Slots verwenden. Für echte CPU-Parallelität werden mehrere Prozesse in einer Instanzgruppe verwendet.

**Erwarteter Vorteil:** I/O-lastige Tasks und NumPy-/C-Erweiterungen, die den GIL freigeben, können parallel laufen. Ein langsamer Task belegt nicht zwingend die gesamte Instanz.

**Neue Nachteile/Risiken:** Reine Python-CPU-Berechnungen werden durch mehrere Threads wegen des CPython-GIL nicht automatisch schneller. Gemeinsamer Context-Zustand benötigt Locks oder strikt serielles Routing. Mehr Worker erhöhen Speicherverbrauch.

**Priorität:** **Sinnvoll**, nach den Code- und Datenpfad-Grundlagen.

## 3.2 Runaway Tasks

**Problem:** Eine Endlosschleife oder blockierte native Funktion kann eine Instanz unbrauchbar machen.

**Ursache:** `asyncio.wait_for` beendet keinen beliebigen Python-Thread. `CANCEL` wird im aktuellen Executor nur vor dem Job-Start geprüft.

**Lösung:** Drei Schutzstufen:

1. kooperative Cancellation-API für Python-Code;
2. mehrere Worker als Isolation gegen einzelne blockierte Slots;
3. Watchdog: Bei Überschreitung eines konfigurierbaren Hard-Limits wird der Worker bzw. der gesamte Python-Prozess als unzuverlässig markiert und über den bestehenden Restart-Pfad beendet.

Ein beliebiger Python-Thread darf nicht als sicher abbrechbar dargestellt werden.

**Erwarteter Vorteil:** Ein normal abbrechbarer Task reagiert kooperativ. Ein einzelner hängender Task blockiert bei mehreren Workern nicht alle unabhängigen Tasks. Der Prozess kann als letzte Maßnahme sicher neu gestartet werden.

**Neue Nachteile/Risiken:** Ein Prozess-Kill verliert alle persistenten Contexts und noch nicht ausgelagerte Data Objects. Native Erweiterungen können beim Kill eigene Ressourcen hinterlassen. Ein Hard-Kill darf daher nur als explizite Recovery-Policy erfolgen.

**Priorität:** **Notwendig** für robuste Produktionsnutzung.

## 3.3 Source-Code-Overhead

**Problem:** Unveränderter Source wird bei jedem Call erneut gelesen, übertragen und gehasht.

**Ursache:** `call_script()` liest die Datei; Task-Nachrichten enthalten den Source; Python berechnet den Source-Hash erneut.

**Lösung:** Content-addressed Script Registry:

```text
Source-Datei
  → lokaler Hash-Cache
  → DEFINE_SCRIPT(hash, source) genau einmal
  → DEFINE_ACK(hash, runtime_id)
  → CALL(runtime_id, function, args, kwargs)
```

Ein Call enthält danach nur noch `runtime_id` oder `source_hash`, Funktionsname und Argumente. Bei Änderung wird ein neuer Hash erzeugt und gezielt neu definiert.

**Erwarteter Vorteil:** Kein Source-Transfer und kein erneutes Source-Hashing auf dem Hot Path. Große Skripte verursachen nur beim ersten Laden oder bei Änderung Kosten.

**Neue Nachteile/Risiken:** Registry-Einträge benötigen Lebensdauer- und Eviction-Regeln. Nach einem Prozess-Restart ist die Registry des Prozesses leer und muss rekonstruiert werden. Hash-Kollisionen sind bei SHA-256 praktisch unwahrscheinlich, aber die Registry muss Hash und Metadaten trotzdem validieren.

**Priorität:** **Notwendig**.

## 3.4 Wiederholte Kompilierung

**Problem:** `execute`/`run` kompiliert unveränderten Source erneut.

**Ursache:** Der `run`-Pfad besitzt keinen Code-Object-Cache.

**Lösung:** Python-seitiger Compile Cache:

```text
(source_hash, python_version, compile_mode)
  → code object
```

`run` verwendet bei gleichem Hash das vorhandene Code Object. Die Ausführung mit `exec` bleibt davon getrennt: Kompilieren wird eingespart, Seiteneffekte der `run`-Semantik bleiben erhalten.

Optional kann ein `marshal`-Cache auf der Festplatte untersucht werden. Dieser ist immer an Python-Version, Plattform und Compile-Parameter zu binden.

**Erwarteter Vorteil:** Compile-Kosten entfallen für unveränderte wiederholte `run`-Aufrufe.

**Neue Nachteile/Risiken:** Code Objects und Contexts verbrauchen Speicher. `marshal` ist kein universell stabiles Austauschformat und darf nicht wie ein plattformunabhängiges Artefakt behandelt werden.

**Priorität:** **Sinnvoll**, zusammen mit der Script Registry.

## 3.5 Main-Thread-Decoding

**Problem:** Große Antworten werden vollständig innerhalb eines Godot-Frames dekodiert.

**Ursache:** `ConnectionManager.drain()` führt UTF-8-Decoding, JSON-Parsing und rekursive Typkonvertierung aus, bevor die Frame-Inbox greifen kann.

**Lösung:** Eingangs-Pipeline mit drei Stufen:

```text
WebSocket packet
  → Raw Frame Queue
  → Decode Budget Manager
  → Task/Data Result Queue
  → Main-Thread-Abschluss
```

Neue Limits:

- `max_decode_bytes_per_frame`
- `max_decode_ms_per_frame`
- `max_materialize_bytes_per_frame`
- `max_result_bytes`
- `max_stdout_bytes`

Große Daten werden als Stream oder Handle repräsentiert und nicht zwingend sofort materialisiert.

**Erwarteter Vorteil:** Ein großer Datensatz kann über mehrere Frames verarbeitet werden. Kleine Steuerergebnisse bleiben schnell; große Daten erzeugen keinen unbeschränkten Einzel-Frame-Stall.

**Neue Nachteile/Risiken:** Ergebnisse sind eventuell erst nach mehreren Frames vollständig verfügbar. Rohdaten benötigen temporären Speicher. Die Reihenfolge zwischen Steuer- und Datenereignissen muss eindeutig definiert werden.

**Priorität:** **Notwendig**.

## 3.6 Numerische Arrays über JSON

**Problem:** Numerische Packed-Arrays werden als JSON-Zahlenlisten übertragen.

**Ursache:** Nur Bytes, Images und bestimmte NumPy-Pfade nutzen aktuell Binary Chunks.

**Lösung:** Alle homogenen numerischen Arrays werden über rohe Little-Endian-Bytes übertragen:

```json
{
  "$pb": "numeric_array",
  "dtype": "float32",
  "shape": [5000000, 3],
  "count": 15000000,
  "nbytes": 60000000,
  "chunk": 0
}
```

Die Metadaten bleiben JSON; die Werte liegen im Binary-Chunk. Die vorhandenen `PackedByteArray.to_float32_array()`, `to_float64_array()` und entsprechenden Integer-Konvertierungen können als Grundlage dienen.

**Erwarteter Vorteil:** Dramatisch weniger JSON-Größe, weniger Parserarbeit und weniger temporäre Variant-Objekte.

**Neue Nachteile/Risiken:** Dtype-, Shape-, Alignment- und Endianness-Fehler müssen strikt getestet werden. Nicht jeder Python-Dtype besitzt eine direkte Godot-Entsprechung.

**Priorität:** **Notwendig**, höchster Nutzen für wissenschaftliche Daten.

## 3.7 Serialization Overhead

**Problem:** Große verschachtelte Daten erzeugen viele temporäre Objekte und Funktionsaufrufe.

**Ursache:** Rekursive elementweise Kodierung, wiederholte Typprüfungen und Tag-Objekte.

**Lösung:**

- NumPy-Erkennung einmalig lazy initialisieren, nicht pro Element importieren;
- Bulk-Fast-Paths für homogene Listen und Packed-Arrays;
- primitive Sequenzen direkt als numerischen Binary Buffer behandeln;
- strukturierte Tabellen bei Bedarf spaltenweise übertragen;
- Small-Object-JSON von Large-Object-DataRef trennen.

**Erwarteter Vorteil:** Weniger Python-Allokationen, weniger JSON und schnellere Godot-Materialisierung.

**Neue Nachteile/Risiken:** Mehr Spezialpfade erhöhen die Testmatrix. Ein Fast Path darf nicht stillschweigend die Semantik heterogener Listen verändern.

**Priorität:** **Sinnvoll**.

## 3.8 Queue-Timeouts

**Problem:** Tasks können wegen langer Queue-Zeit als Ausführungstimeout erscheinen, obwohl sie noch nicht gestartet wurden.

**Ursache:** `created_at_ms` ist der einzige Timeout-Bezugspunkt.

**Lösung:** Timeout in mindestens zwei Werte aufteilen:

```text
queue_timeout_ms   = maximale Wartezeit auf einen Slot
execution_timeout_ms = maximale Zeit nach RUNNING
```

Optional kommt ein separates `transport_timeout_ms` hinzu.

**Erwarteter Vorteil:** Fehlerursachen werden korrekt unterschieden. Der Scheduler kann Queue-Überlastung anders behandeln als Python-Ausführungsfehler.

**Neue Nachteile/Risiken:** Mehr Zustände und Fehlercodes. Bestehende API-Aufrufe benötigen Rückwärtskompatibilitätsdefaults.

**Priorität:** **Notwendig**, geringer Implementierungsaufwand.

## 3.9 Instanz-Routing

**Problem:** Auto-zugeordnete Calls wechseln zwischen Prozessen und verlieren persistenten Context-Zustand.

**Ursache:** Leere `instance_id` bedeutet aktuell beliebige Ready-Instanz.

**Lösung:** Context-Affinität:

```text
context_key → instance_id
```

Der erste Call eines persistenten Contexts pinnt ihn an eine Instanz. Weitere Calls werden dorthin geroutet. Bei Ausfall kann die Affinität bewusst verworfen und der Context auf einer neuen Instanz neu definiert werden.

**Erwarteter Vorteil:** Persistente Modulvariablen und Compile Caches bleiben nutzbar. Source wird nicht bei jedem Instanzwechsel erneut definiert.

**Neue Nachteile/Risiken:** Sticky Routing kann Last ungleich verteilen. Contexts müssen bei Prozessverlust rekonstruierbar sein. Routing darf nicht als transaktionssichere Datenbanksemantik missverstanden werden.

**Priorität:** **Notwendig**, sobald mehrere Instanzen mit persistentem Zustand verwendet werden.

## 3.10 JSON- und Protokoll-Overhead

**Problem:** JSON wird auch für große Nutzdaten verwendet.

**Ursache:** Control Plane und Data Plane sind noch nicht vollständig getrennt.

**Lösung:** JSON bleibt für Control und Metadaten. Die Data Plane verwendet Binary Chunks, Streams oder Handles. Ein vollständiges binäres Control-Protokoll wird nicht eingeführt.

**Erwarteter Vorteil:** Debuggability und Transparenz bleiben erhalten, während große Nutzdaten nicht mehr durch JSON müssen.

**Neue Nachteile/Risiken:** Zwei Datenpfade benötigen Capability Negotiation und Tests. Fehlerhafte Fallbacks können schwer zu diagnostizieren sein.

**Priorität:** **Notwendig**, aber gezielt statt vollständig.

## 3.11 Große Resultate und stdout/stderr

**Problem:** Große Rückgabewerte und Ausgaben können Speicher, Netzwerk und Frame-Budget überlasten.

**Ursache:** Keine konsequente Resultat- oder Output-Grenze.

**Lösung:**

- `max_result_bytes` server- und clientseitig;
- `max_stdout_bytes` und `max_stderr_bytes`;
- Truncation mit `truncated: true` statt stiller Abschneidung;
- große Rückgabewerte automatisch als `DataRef`;
- optionaler Stream-Modus für kontrollierte Ausgabe.

**Erwarteter Vorteil:** Ressourcenverbrauch wird begrenzt und Fehler werden strukturiert gemeldet.

**Neue Nachteile/Risiken:** Manche Anwendungen benötigen bewusst große Logs. Defaults müssen entwicklerfreundlich, aber sicher sein.

**Priorität:** **Sinnvoll**, für Produktionsbetrieb praktisch notwendig.

## 3.12 Binary Transport und Chunking

**Problem:** Der vorhandene Binary Transport erzeugt unnötige Kopien und verarbeitet große Payloads als Einzelereignis.

**Ursache:** Python verwendet wiederholte `bytes`-Konkatenation; Chunk-Lebensdauer und Frame-Budget sind nicht ausreichend abstrahiert.

**Lösung:**

- `bytearray` oder vorab berechnete `b"".join(parts)`-Struktur verwenden;
- adaptive Chunk-/Frame-Größe;
- Continuation-Metadaten für mehrteilige Datenströme;
- Backpressure und begrenzte Sendefenster;
- kleine Chunks in einem Frame zusammenfassen;
- große Objekte bevorzugt als Handle veröffentlichen.

**Erwarteter Vorteil:** Weniger Kopien und besser kontrollierbare Latenz.

**Neue Nachteile/Risiken:** Stream-Reassembly, Abbruch und Cleanup werden komplexer. Ein Handle ist nur gültig, solange die zugrunde liegenden Daten existieren.

**Priorität:** **Sinnvoll**.

---

# 4. Persistent Script Runtime & Bytecode-Caching

## 4.1 Drei verschiedene Ebenen

Die Bridge muss strikt zwischen folgenden Ebenen unterscheiden:

```text
Python Source
  = vom Entwickler bearbeitete .py-Datei

Compiled Code Object
  = von CPython kompiliertes Laufzeitobjekt

Runtime Context
  = Namespace, Funktionen, Imports, Variablen und persistenter Zustand
```

Diese Ebenen sind nicht austauschbar:

- Python Source ist die autoritative Quelle.
- Ein Code Object ist CPython-intern und nicht GDScript-kompatibel.
- Ein Runtime Context lebt in einem bestimmten Python-Prozess.
- Nach einem Prozessneustart muss ein Context neu aufgebaut werden.

## 4.2 Script Registry

```text
script_id
  → source_path
  → source_hash
  → source_size
  → mtime
  → runtime_id je Python-Instanz
  → compile_state
```

### Ablauf beim ersten Call

1. Godot prüft zuerst `mtime` und Dateigröße.
2. Nur bei Veränderung wird der Source gelesen und gehasht.
3. Godot sendet `DEFINE_SCRIPT` mit Hash und Source.
4. Python validiert den Hash, kompiliert und registriert den Source.
5. Python antwortet mit `DEFINE_ACK` und `runtime_id`.
6. Weitere Calls referenzieren nur noch `runtime_id` oder Hash.

### Ablauf bei Änderung

1. Editor-Watcher oder expliziter Hot Reload erkennt Änderung.
2. Neuer Hash wird erzeugt.
3. Alte Runtime-Version wird als veraltet markiert.
4. `DEFINE_SCRIPT` erzeugt eine neue Version.
5. Bereits laufende Tasks behalten die alte Version bis zum Abschluss, sofern das konfiguriert ist.
6. Neue Tasks verwenden die neue Version.

## 4.3 Compile Cache

Der Python-Prozess hält einen Cache:

```text
(source_hash, python_major_minor, compile_mode)
  → code object
```

Der Cache darf nicht nur nach Dateiname indizieren. Derselbe Dateiname kann unterschiedlichen Source enthalten.

Der Speicher muss begrenzt werden:

- maximale Anzahl Code Objects;
- maximale Cache-Größe;
- LRU-Entfernung;
- explizite Invalidierung bei Hot Reload.

## 4.4 Persistente Contexts

Ein Context enthält unter anderem:

```text
context_id
script_runtime_id
namespace
source_hash
compiled_code
last_used
instance_id
```

Ein Context darf nur dann parallel ausgeführt werden, wenn die Semantik ausdrücklich dafür definiert ist. Standardmäßig gilt:

```text
gleicher Context → serielle Ausführung
verschiedene unabhängige Contexts → parallelisierbar
```

Dadurch bleiben Modulvariablen und Imports deterministisch.

## 4.5 Bytecode auf der Festplatte

Ein optionaler `marshal`-Cache kann den Compile-Schritt über Prozessstarts hinweg verkürzen. Er ist jedoch keine primäre Architekturkomponente:

- `marshal` ist Python-versionsabhängig;
- Plattform- und Compile-Parameter müssen im Cache-Key stehen;
- beschädigte Einträge müssen jederzeit gelöscht werden können;
- Source-Hash bleibt die Autorität;
- niemals `marshal` als GDScript- oder Python-ABI-unabhängiges Format behandeln.

**Bewertung:** sinnvolle spätere Optimierung, nicht Voraussetzung für die Script Registry.

---

# 5. Intelligentes Daten- und Transport-System

## 5.1 TransportManager

Der `TransportManager` wird eine interne Policy-Schicht zwischen Serializer und Protocol:

```text
logical value
  → classify(type, size, lifetime, access_pattern, capabilities)
  → choose transport
  → encode descriptor + payload
```

Der Entwickler übergibt weiterhin einen normalen Wert oder ein Bridge Data Object.

## 5.2 Entscheidungskriterien

| Kriterium | Beispiel |
|---|---|
| Typ | scalar, dict, bytes, ndarray, PackedFloat32Array, image |
| Größe | geschätzte Byte-Anzahl |
| Lebensdauer | einmalige Antwort oder langlebiger Datensatz |
| Zugriffsmuster | einmal lesen, mehrfach lesen, Teilbereiche lesen |
| Richtung | Godot → Python oder Python → Godot |
| Lokalität | gleicher Rechner oder später Remote-Transport |
| Fähigkeiten | verfügbare Binary-, mmap- oder Shared-Memory-Transporter |
| Ressourcen | Speicherlimit, offene Handles, laufende Streams |

## 5.3 Vorläufige Policy

Die Schwellenwerte sind Startwerte und müssen gemessen werden:

| Situation | Standardentscheidung |
|---|---|
| Kleine Skalare und strukturierte Daten | Inline-JSON |
| Homogene numerische Daten ab einigen Kilobytes | Binary Frame |
| Große einmalige Daten | gestreamter Binary Transport |
| Große wiederverwendete Daten | DataRef/Handle |
| Sehr große lokale Daten mit wiederholtem Zugriff | mmap- oder Shared-Memory-Transport, wenn verfügbar |
| Nicht unterstützter Spezialtyp | strukturierter Fehler oder expliziter repr-Fallback |

Konkrete Schwellenwerte wie 4 MiB oder 16 MiB dürfen erst nach Benchmarks als Defaults festgeschrieben werden.

## 5.4 Capability Negotiation

Der `HELLO`-Handshake wird um Fähigkeiten erweitert:

```json
{
  "transports": ["json", "binary_chunks", "stream", "file_mapping"],
  "numeric_dtypes": ["float32", "float64", "int32", "int64", "uint8"],
  "max_frame_bytes": 67108864,
  "shared_memory": false,
  "protocol_features": ["handles", "progress", "script_registry"]
}
```

Die Bridge wählt nur einen Transport, den beide Seiten unterstützen. Wenn ein optionaler Transport nicht verfügbar ist, fällt sie transparent auf Binary oder JSON zurück.

## 5.5 Transparenz

Die Automatik darf keine Blackbox sein. Im Debug-Modus soll die Bridge protokollieren:

```text
value=PointCloud
nbytes=80000000
dtype=float32
lifetime=persistent
selected=handle+binary_stream
reason=size_and_reuse
fallback=file_mapping
```

---

# 6. Shared Memory / Memory Mapping

## 6.1 Wichtige technische Einschränkung

Python kann plattformübergreifend Shared Memory über die Standardbibliothek verwenden, beispielsweise `multiprocessing.shared_memory`. Godot/GDScript stellt jedoch nicht automatisch eine plattformunabhängige API bereit, mit der ein beliebiger Shared-Memory-Namensraum als `PackedFloat32Array` betrachtet wird.

Deshalb bedeutet „Shared Memory“ nicht automatisch „Zero Copy bis in GDScript“.

Godots `Packed*Array`-Objekte müssen in der Regel einen eigenen verwalteten Speicher besitzen. Eine native Erweiterung kann das Mapping und eine schnelle Kopie übernehmen, aber eine dauerhaft externe Speicherreferenz muss hinsichtlich Lebensdauer und Thread-Sicherheit separat bewiesen werden.

Die realistischen Stufen sind:

## 6.2 Stufe 1: Datei-basierter Mapping-/Chunk-Transport

Python schreibt einen Datensatz in eine temporäre Datei. Godot liest ihn über `FileAccess` stückweise und innerhalb des Frame-Budgets.

**Problem → Ursache → Lösung → Vorteil → Risiken → Priorität**

- **Problem:** WebSocket und JSON sind für sehr große Daten teuer.
- **Ursache:** Jede Nutzlast wird über den Control-/Socketpfad bewegt.
- **Lösung:** File-backed Dataset mit Descriptor, Größe, Dtype, Shape und Prüfsumme.
- **Erwarteter Vorteil:** WebSocket bleibt klein; Daten können chunkweise und wiederaufnehmbar gelesen werden; keine zusätzliche native Erweiterung nötig.
- **Neue Nachteile/Risiken:** Es gibt weiterhin Kopien vom Dateisystem in Godot-Speicher. Dateirechte, Cleanup, parallele Zugriffe und Exportpfade müssen behandelt werden.
- **Priorität:** **Sinnvoll**, sobald Binary Frames nach Messung nicht ausreichen.

## 6.3 Stufe 2: Python Shared Memory

Python kann große Arrays in einen Shared-Memory-Block schreiben und nur dessen Descriptor senden:

```text
name
size
shape
dtype
readonly
owner
version
```

**Problem → Ursache → Lösung → Vorteil → Risiken → Priorität**

- **Problem:** Wiederholte Übertragung desselben Datensatzes.
- **Ursache:** Daten werden bei jedem Task erneut serialisiert.
- **Lösung:** Shared-Memory-Block + Handle.
- **Erwarteter Vorteil:** Python-interne Wiederverwendung ohne Socket-Kopie.
- **Neue Nachteile/Risiken:** Godot benötigt für direkten Zugriff eine native Erweiterung oder muss den Block über einen unterstützten Dateipfad materialisieren. Cleanup nach Crash ist zwingend.
- **Priorität:** **Optional**.

## 6.4 Stufe 3: Native GDExtension

Eine GDExtension kann plattformspezifisch:

- Windows `CreateFileMapping`/`MapViewOfFile`;
- Linux/macOS POSIX Shared Memory oder mmap;
- file-backed mapping;
- kontrollierte Kopien in Godot Packed Arrays

implementieren.

**Problem → Ursache → Lösung → Vorteil → Risiken → Priorität**

- **Problem:** GDScript besitzt keinen vollständigen, einheitlichen Shared-Memory-Zugriff.
- **Ursache:** Betriebssystem-IPC ist nicht durch eine portable GDScript-API abstrahiert.
- **Lösung:** Kleine optionale GDExtension hinter `BridgeDataTransport`.
- **Erwarteter Vorteil:** Schneller lokaler Zugriff und weniger Socket-/JSON-Overhead.
- **Neue Nachteile/Risiken:** Native Fehler können Godot direkt destabilisieren. Es entsteht eine Build-Matrix für Windows, Linux und macOS. Debugging und Distribution werden schwieriger.
- **Priorität:** **Zukünftige Ausbaustufe**.

## 6.5 Wann Shared Memory sinnvoll ist

Shared Memory lohnt sich nicht automatisch für jede Payload. Es ist besonders interessant, wenn:

- die Daten größer als mehrere Megabytes sind;
- derselbe Datensatz mehrfach verwendet wird;
- Python und Godot auf demselben Rechner laufen;
- der Datensatz länger lebt als ein einzelner Task;
- Materialisierung nicht bei jedem Zugriff erforderlich ist.

Der genaue Crossover-Punkt muss benchmarkbasiert bestimmt werden.

## 6.6 Cleanup- und Ownership-Modell

Jeder Shared-Datensatz braucht:

```text
owner process
reference count
created_at
last_access
size limit
release state
crash cleanup policy
```

Nach einem Prozessabsturz müssen verwaiste Dateien oder Shared-Memory-Segmente erkannt und bereinigt werden. Ein Handle ohne gültigen Besitzer wird als `DATA_HANDLE_STALE` gemeldet.

---

# 7. Binary Transport & Chunking

## 7.1 Einheitliches Numeric-Array-Format

Alle unterstützten homogenen Arrays verwenden ein gemeinsames Descriptor-Format:

```json
{
  "$pb": "numeric_array",
  "dtype": "float32",
  "shape": [5000000, 3],
  "order": "C",
  "nbytes": 60000000,
  "chunk": 0
}
```

Little Endian wird als Protokollstandard beibehalten. Dtype und Shape müssen vor dem Materialisieren validiert werden.

## 7.2 Adaptive Chunks

Die Bridge soll nicht jedes Ergebnis als eine einzelne riesige WebSocket-Nachricht behandeln.

```text
logical dataset
  → descriptor
  → chunk 0
  → chunk 1
  → ...
  → completion
```

Chunk-Größe ist adaptiv und abhängig von:

- Frame-Budget;
- WebSocket-Limits;
- verfügbarer Speichergröße;
- Datentyp;
- erwarteter Verarbeitungszeit.

Startwerte wie 1–4 MiB pro Chunk sind nur Hypothesen und müssen gemessen werden.

## 7.3 Progress und Backpressure

Ein Stream besitzt:

```text
stream_id
sequence
bytes_done
bytes_total
checksum
is_final
```

Progress-Events werden rate-limitiert. Es darf nicht für jeden kleinen Chunk ein separates Godot-Signal entstehen.

Wenn Godot den Stream nicht schnell genug materialisieren kann, muss der Receiver ein kontrolliertes Fenster schließen. Python darf nicht unbegrenzt neue Chunks in den Speicher produzieren.

## 7.4 Binary-Builder korrigieren

Die aktuelle Python-Implementierung verwendet wiederholte `bytes`-Konkatenation. Das wird ersetzt durch:

- `bytearray` mit vorheriger Größenplanung; oder
- Aufbau einer Liste von Byte-Teilen und einmaliges `b"".join(parts)`.

Das ist ein kleiner, klarer Fix und unabhängig von Shared Memory.

## 7.5 Kompression

Kompression wird nicht standardmäßig eingeführt:

- Float32-Daten sind bereits kompakt;
- Kompression verbraucht CPU;
- unterschiedliche Daten haben sehr unterschiedliche Kompressionsraten;
- zusätzliche Bibliotheken erhöhen die Abhängigkeiten.

Kompression kann später als verhandeltes Feature für stark redundante oder textartige Daten untersucht werden.

---

# 8. Bridge Data Objects / Handles

## 8.1 Zielmodell

Ein großer Datensatz wird nicht automatisch als vollständige Godot-Struktur zurückgegeben, sondern kann als DataRef erscheinen:

```json
{
  "$pb": "data_ref",
  "id": "data-42",
  "kind": "point_cloud",
  "dtype": "float32",
  "shape": [5000000, 3],
  "nbytes": 60000000,
  "transport": "binary_stream",
  "version": 1,
  "readonly": true
}
```

Der Entwickler arbeitet logisch mit dem Objekt; intern bleibt die Datenrepräsentation beim Python-Prozess, in einer Datei, im Shared Memory oder im Binary-Stream.

## 8.2 Data Object Registry

Python-seitig:

```text
data_id
payload / backing store
kind
schema
shape
dtype
nbytes
transport
refcount
last_access
owner_context
version
```

Godot-seitig existiert ein korrespondierender Handle-Tracker. Beide Seiten müssen Freigaben und Stale Handles behandeln.

## 8.3 Operationen

Vorgesehene interne/optionale API:

```gdscript
var ref = result.value
var metadata = PythonBridge.data.describe(ref)
var local = await PythonBridge.data.materialize(ref)
var slice = await PythonBridge.data.read_slice(ref, offset, count)
PythonBridge.data.retain(ref)
PythonBridge.data.release(ref)
```

Die automatische Standardregel lautet:

- kleine Ergebnisse → normaler Wert;
- große einmalige Ergebnisse → Stream oder budgetierte Materialisierung;
- große wiederverwendete Ergebnisse → DataRef;
- Python-Folgeoperationen → Handle zurück an Python statt Datenkopie.

## 8.4 Unterstützte Datenklassen

| Datenklasse | Eignung für Handles |
|---|---|
| NumPy Arrays | sehr hoch |
| Punktwolken | sehr hoch |
| Matrizen/Tensoren | sehr hoch |
| Mesh-Daten | hoch, sofern Lebenszyklus definiert ist |
| Bilder | hoch |
| Simulationszustände | hoch, häufig als mehrere verbundene DataRefs |
| kleine Dictionaries | niedrig; JSON bleibt besser |
| einzelne Skalare | nicht sinnvoll |

## 8.5 In-Place- und Versionierungsmodell

Ein DataRef kann unveränderlich sein oder Versionen besitzen:

```text
pointcloud-42@v1
pointcloud-42@v2
```

Standardmäßig werden unveränderliche Referenzen bevorzugt. In-Place-Mutationen benötigen explizite Synchronisationsregeln, sonst können Godot und Python gleichzeitig unterschiedliche Zustände sehen.

---

# 9. Task-, Worker- und Scheduler-Architektur

## 9.1 Bestehende Komponenten bleiben

Der aktuelle `TaskManager` und `Scheduler` werden erweitert, nicht ersetzt:

```text
TaskManager
├─ queue_timeout
├─ execution_timeout
├─ task priority
├─ context affinity
├─ data dependencies
├─ retry policy
└─ backpressure

Scheduler
├─ instance selection
├─ worker slot selection
├─ batch policy
├─ frame budgets
├─ stream budgets
└─ result delivery
```

## 9.2 Worker-Modell

### Standard

Eine Instanz darf weiterhin mit einem Worker betrieben werden. Das erhält die aktuelle Semantik und minimiert Ressourcenverbrauch.

### Erweiterung

```text
Python Instance
├─ Control Event Loop
├─ Worker 1
├─ Worker 2
├─ ...
└─ Context Locks
```

Ein Context darf standardmäßig nicht gleichzeitig in mehreren Workern ausgeführt werden.

### GIL-Einschränkung

Mehrere Threads in einem CPython-Prozess liefern keine allgemeine Parallelisierung für CPU-bound reinen Python-Code. Vorteile entstehen vor allem bei:

- I/O-bound Tasks;
- C-/Cython-/NumPy-Operationen, die den GIL freigeben;
- Entkopplung einzelner blockierter Slots.

Für echte CPU-Parallelität werden mehrere Python-Prozesse benötigt.

## 9.3 Instanzgruppen

Mehrere Prozesse können zu einer logischen Gruppe gehören:

```text
analysis_group
├─ worker_process_1
├─ worker_process_2
└─ worker_process_3
```

Der Scheduler entscheidet anhand von:

- Context-Affinität;
- laufenden Slots;
- Priorität;
- Datenlokalität;
- Health-State;
- optionalem Speicherverbrauch.

Ein Context darf nur verschoben werden, wenn sein Zustand neu aufgebaut werden kann oder explizit als stateless markiert ist.

## 9.4 Worker-Recovery

Ein Timeout durchläuft folgende Stufen:

```text
RUNNING
  → timeout warning
  → cooperative cancel
  → worker slot quarantined
  → hard process recovery, wenn policy dies erlaubt
```

Ein Thread wird nicht als erfolgreich abgebrochen markiert, solange er tatsächlich weiterläuft.

## 9.5 Fairness und Backpressure

Zusätzlich zu globalen Limits sind sinnvoll:

- maximale Tasks pro Context in der Queue;
- maximale Bytes pro Context;
- Prioritäts- und Fairness-Regeln;
- getrennte interaktive und Bulk-Queues;
- Schutz vor einem einzelnen Produzenten, der die gesamte Queue füllt.

---

# 10. Godot Main-Thread und Frame-Budgets

## 10.1 Budgettypen

Die bisherige Nachrichtenanzahl reicht nicht aus. Es werden getrennte Budgets benötigt:

```text
max_control_messages_per_frame
max_decode_bytes_per_frame
max_decode_ms_per_frame
max_materialize_bytes_per_frame
max_materialize_ms_per_frame
max_progress_events_per_frame
```

Zeitbudgets sind Sicherheitsgrenzen, keine exakten Echtzeitgarantien. Ein einzelner Engine-Aufruf kann selbst Schwankungen verursachen.

## 10.2 Priorisierung

Reihenfolge innerhalb eines Frames:

1. Lifecycle- und Fehlernachrichten;
2. kleine interaktive Task-Ergebnisse;
3. Handle-Metadaten;
4. Stream-Fortschritt;
5. große Bulk-Materialisierung.

Bulk-Daten dürfen nicht alle Steuerereignisse verdrängen.

## 10.3 Raw Queue vor Decode

Wichtig ist die Position der Grenze:

```text
WebSocket receive
  → Raw packet queue
  → size/time budget
  → decode one portion
  → typed result
```

Das komplette JSON-/Binary-Paket darf nicht zwangsläufig vor dem Budget vollständig in eine Godot-Struktur umgewandelt werden.

## 10.4 Hintergrundverarbeitung

Godot bietet mit `WorkerThreadPool` grundsätzlich eine Möglichkeit für CPU-Arbeiten außerhalb des Main-Threads. Das darf nur für klar thread-sichere Datenoperationen verwendet werden.

Vor einer Nutzung müssen experimentell geprüft werden:

- Thread-Sicherheit von JSON-Parsing in der konkreten Godot-Version;
- Thread-Sicherheit von Packed-Array-Konvertierungen;
- Übergabe von Ergebnissen zurück an den Main-Thread;
- Shutdown und Cancellation von WorkerThreadPool-Tasks.

Die notwendige erste Schutzmaßnahme bleibt das explizite Zeit-/Byte-Budget, nicht das ungemessene Verschieben aller Dekodierung in Threads.

## 10.5 Ergebniszustände

Große Ergebnisse benötigen sichtbare Zustände:

```text
RECEIVED_METADATA
WAITING_FOR_MATERIALIZATION
MATERIALIZING
READY
FAILED
CANCELLED
STALE
```

---

# 11. Plattformübergreifende Abstraktion

## 11.1 Gemeinsame Schnittstelle

Der Kern soll nicht direkt POSIX-, Windows- oder GDExtension-Code enthalten. Vorgesehen ist eine interne Transport-Schnittstelle:

```text
BridgeDataTransport
├─ InlineJsonTransport
├─ BinaryChunkTransport
├─ StreamTransport
├─ MappedFileTransport
└─ SharedMemoryTransport (optional)
```

Jeder Transport meldet:

```text
available()
capabilities()
create_descriptor()
send_or_publish()
receive_or_materialize()
release()
cleanup_after_crash()
```

## 11.2 Plattformmatrix

| Fähigkeit | Windows | Linux | macOS | Abhängigkeit |
|---|---:|---:|---:|---|
| WebSocket Control | ja | ja | ja | bestehende Bridge |
| JSON | ja | ja | ja | Python/Godot Standard |
| Binary Frames | ja | ja | ja | bestehendes Protokoll |
| Datei-basierter Stream | ja | ja | ja | FileAccess + Python-Datei-I/O |
| Python `mmap` | ja | ja | ja | Python-Standardbibliothek |
| Python Shared Memory | ja | ja | ja | Python-Standardbibliothek |
| direkter Godot Shared-Memory-Zugriff | nicht standardmäßig | nicht standardmäßig | nicht standardmäßig | GDExtension erforderlich |
| Arrow nativ in Godot | nicht standardmäßig | nicht standardmäßig | nicht standardmäßig | eigener Parser oder GDExtension |

## 11.3 Endianness

Das Protokoll verwendet Little Endian für Längen und numerische Binary Payloads. Dtype, Shape, Byte-Reihenfolge und erwartete Payload-Größe werden validiert.

## 11.4 Export- und Schreibpfade

Der aktuelle Default `res://python_bridge` ist für Editor-/Entwicklungsbetrieb praktisch, aber in einem exportierten Projekt nicht automatisch beschreibbar. Für Runtime-Betrieb muss ein writable Workspace, beispielsweise unter `user://`, konfiguriert werden.

Das ist keine reine Transportfrage und muss Teil der Deployment-Konfiguration werden.

---

# 12. Welche Technologien tatsächlich benötigt werden

| Technologie | Konkreter Nutzen | Bewertung |
|---|---|---|
| WebSocket | Control Channel, Lifecycle, Tasks, Handles | **Beibehalten / notwendig** |
| JSON | Kleine Steuer- und Metadaten, Debuggability | **Beibehalten / notwendig** |
| Binary Chunks | numerische Arrays und mittlere Daten | **Ausbauen / notwendig** |
| Content Hashing | Source Registry und Cache-Identität | **Notwendig** |
| Python Code-Object-Cache | wiederholte Compile-Kosten vermeiden | **Sinnvoll** |
| `mmap`-Dateien | große lokale, wiederverwendete Daten | **Sinnvoll/optional** |
| `multiprocessing.shared_memory` | Python-seitige Wiederverwendung großer Daten | **Optional** |
| GDExtension | direkter lokaler Mapping-/Shared-Memory-Zugriff | **Zukünftige Ausbaustufe** |
| Apache Arrow | Schema-reiche spaltenorientierte Daten | **Optional, nach Evaluation** |
| Named Pipes | zweiter IPC-Control-/Datenkanal | **Vorerst verwerfen** |
| gRPC/Protobuf | starke Schemas und RPC | **Vorerst verwerfen**; WebSocket erfüllt den Control-Use-Case bereits |
| LZ4/Zstd | Kompression | **Vorerst nicht standardmäßig** |
| Zero-Copy bis GDScript | direkte externe PackedArray-Sicht | **Nicht als Annahme zulässig** |
| Object Store/Handles | Daten nicht wiederholt übertragen | **Sinnvoll bis notwendig für große Daten** |

## 12.1 Apache Arrow im Detail

Apache Arrow ist für Python, NumPy, pandas und Data-Engineering-Anwendungen interessant, weil es spaltenorientierte Daten, Schema, Nullmasken und verschiedene Datentypen standardisiert.

Es löst aber nicht automatisch das Godot-Problem:

- Godot/GDScript besitzt keinen eingebauten Arrow-IPC-Reader;
- ein Reader in GDScript wäre ein eigenes großes Subsystem;
- eine native Arrow-GDExtension erhöht Build- und Distributionsaufwand;
- für reine Float-/Int-Arrays kann das bestehende, viel kleinere dtype-basierte Binary-Format ausreichen.

**Entscheidung:** Arrow wird als optionaler Adapter hinter der Data-Transport-Abstraktion untersucht, aber nicht zur Grundlage der ersten Optimierungsphase gemacht.

---

# 13. Welche Ideen bewusst nicht sofort umgesetzt werden sollten

## 13.1 Kein vollständiges binäres Control-Protokoll

Control-Nachrichten sind klein. JSON ist hier wertvoll für Debugging, Logs und Forward Compatibility. Der große Gewinn liegt im Data Plane.

## 13.2 Kein Arrow-Zwang

Arrow ist interessant, aber ohne Godot-seitigen Reader würde nur die Python-Seite optimiert. Erst ein Prototyp muss zeigen, dass die zusätzlichen Abhängigkeiten den Nutzen rechtfertigen.

## 13.3 Kein Shared Memory als Pflichtabhängigkeit

Die Bridge muss ohne native Erweiterung funktionieren. Shared Memory bleibt ein Capability-basierter optionaler Transport.

## 13.4 Keine Prozess-Erzeugung pro Task

Ein Prozess pro Task würde Isolation verbessern, aber Startkosten, Context-Aufbau und Ressourcenverbrauch verschlechtern. Der bestehende Instanz-Lifecycle ist die bessere Grundlage; Prozess-Kill bleibt Recovery-Maßnahme.

## 13.5 Keine Bytecode-Übersetzung

Python-Bytecode und GDScript-Bytecode haben unterschiedliche Laufzeitmodelle. Es gibt keinen seriösen Grund, eine inkompatible Übersetzung zu versuchen.

## 13.6 Keine pauschale Kompression

Kompression wird nur für Datentypen aktiviert, bei denen Benchmarks einen Vorteil zeigen.

## 13.7 Kein pauschales Offloading auf Godot-Threads

Threading ohne geprüfte Thread-Sicherheit kann neue Race Conditions und Shutdown-Probleme schaffen. Budgets und Handles kommen zuerst.

## 13.8 Kein WebSocket-Ersatz

WebSockets bleiben für Control und mittelgroße Daten ausreichend. Ein zweiter Socket- oder Pipe-Stack wird nur eingeführt, wenn konkrete Messungen einen relevanten Vorteil zeigen.

---

# 14. Priorisierte Roadmap von einfach nach fortgeschritten

## Phase 0 — Messbarkeit und Quick Wins

**Priorität:** notwendig

1. Benchmark-Harness für:
   - JSON vs Binary;
   - PackedFloat32Array;
   - NumPy ndarray;
   - verschiedene Größen;
   - Dekodierzeit pro Frame;
   - Source-Transfer und Compile-Zeit.
2. `build_binary` ohne quadratische Bytes-Konkatenation.
3. `queue_timeout_ms` und `execution_timeout_ms` trennen.
4. Ergebnis-, stdout- und stderr-Limits.
5. NumPy-Erkennung lazy cachen.
6. Telemetrie für Payload-Größe, Encode-, Send-, Decode- und Materialisierungszeit.

**Akzeptanzkriterien:** Bestehende Tests bleiben grün; Benchmarks liefern reproduzierbare Werte; keine API-Breaks für Standardaufrufe.

## Phase 1 — Code Plane

**Priorität:** notwendig

1. `ScriptRegistry` auf Godot-Seite.
2. `DEFINE_SCRIPT`/`DEFINE_ACK` und `CALL` per Runtime-ID.
3. Python Compile Cache.
4. mtime-/size-basierter Source-Read-Cache.
5. Context-Affinität und sticky Routing.
6. Rückwärtskompatibler Fallback für ältere Task-Nachrichten mit Source.

**Akzeptanzkriterien:** Unveränderter 1-MB-Source wird nach Initialisierung nicht erneut über WebSocket übertragen; Änderung erzeugt genau eine neue Definition; Prozess-Restart baut Context korrekt wieder auf.

## Phase 2 — Data Plane

**Priorität:** notwendig für wissenschaftliche Daten

1. Numerische Packed-Arrays über Binary Chunks.
2. Dtype-/Shape-/nbytes-Validierung.
3. Raw Frame Queue.
4. Byte- und Zeitbudgets pro Frame.
5. progressive Materialisierung.
6. Handle-/DataRef-Grundmodell.
7. Progress-Events und Release/GC.

**Akzeptanzkriterien:** Große Float32-Daten laufen nicht als JSON-Zahlenliste; ein definierter Benchmark-Datensatz erzeugt keinen unbeschränkten Frame-Stall; Handles können mehrfach genutzt und explizit freigegeben werden.

## Phase 3 — Worker und Recovery

**Priorität:** sinnvoll

1. `workers_per_instance`.
2. Context-Locks.
3. getrennte Worker-Slots und Slot-Timeouts.
4. kooperative Cancellation-API.
5. Watchdog und konfigurierter Kill-on-Runaway.
6. Instanzgruppen und load-aware Routing.

**Akzeptanzkriterien:** Ein blockierter Worker verhindert nicht die Ausführung unabhängiger Contexts, sofern freie Slots vorhanden sind; ein Hard-Recovery hinterlässt keine Python-Prozesse; Context-Verlust wird strukturiert gemeldet.

## Phase 4 — Datei-basierte große Daten

**Priorität:** sinnvoll/optional

1. file-backed DataRef.
2. chunkweises Lesen über `FileAccess`.
3. writable Workspace unter `user://` für Exporte.
4. Cleanup nach normalem Ende und Crash.

**Akzeptanzkriterien:** Ein großer Datensatz kann ohne WebSocket-Transfer materialisiert werden; parallele Instanzen verwenden getrennte Namen und temporäre Pfade.

## Phase 5 — Native High-Performance-Erweiterung

**Priorität:** zukünftige Ausbaustufe

1. GDExtension für Mapping/Shared Memory.
2. Plattformmatrix Windows/Linux/macOS.
3. optionaler Arrow-IPC-Adapter.
4. geprüfte WorkerThreadPool-Materialisierung.
5. Benchmark-basierte adaptive Thresholds.

**Akzeptanzkriterien:** Native Erweiterung ist optional; fehlende Binärdatei führt zu sauberem Fallback; ein Benchmark zeigt einen realen Vorteil gegenüber Binary Frames und Datei-Transport.

---

# 15. Konkretes End-to-End-Beispiel: große Punktwolke

## 15.1 Szenario

Python erzeugt fünf Millionen Punkte. Jede Position besitzt drei `float32`-Werte:

```text
5,000,000 × 3 × 4 Bytes = 60,000,000 Bytes
```

Zusätzliche Farben oder Attribute können den Datensatz auf etwa 80 MiB vergrößern.

## 15.2 Python-Code

```python
# pointcloud.py
import numpy as np


def create_cloud(count: int) -> np.ndarray:
    points = np.empty((count, 3), dtype=np.float32)
    points[:, 0] = np.linspace(-1.0, 1.0, count, dtype=np.float32)
    points[:, 1] = np.sin(points[:, 0] * 12.0)
    points[:, 2] = np.cos(points[:, 0] * 7.0)
    return points


def transform_cloud(points: np.ndarray, scale: float) -> np.ndarray:
    return points * np.float32(scale)
```

## 15.3 GDScript-Code auf der logischen Ebene

```gdscript
extends Node

func _ready() -> void:
    var started: PythonBridgeResult = await PythonBridge.start_instance("default")
    if started.is_error():
        push_error(started.error_message())
        return

    var result: PythonBridgeResult = await PythonBridge.call_script(
        "pointcloud",
        "create_cloud",
        [5_000_000],
        {},
        "default",
        60.0)

    if result.is_error():
        push_error(result.error_message())
        return

    # In der neuen Architektur kann value ein DataRef statt einer
    # 60-MB-Godot-Struktur sein.
    var cloud_ref: Variant = result.value
    var metadata: PythonBridgeResult = await PythonBridge.data.describe(cloud_ref)
    print("Cloud metadata: ", metadata.value)

    var positions: PythonBridgeResult = await PythonBridge.data.materialize(cloud_ref)
    if positions.is_ok():
        _use_positions(positions.value)

    PythonBridge.data.release(cloud_ref)

func _use_positions(points: Variant) -> void:
    # Die fertige Godot-Struktur wird erst nach budgetierter Materialisierung
    # verwendet. Die konkrete Mesh-/MultiMesh-Erzeugung bleibt Godot-Code.
    print("Received positions: ", points.size())
```

## 15.4 Interner Ablauf

```text
1. call_script wird angefordert.
2. ScriptRegistry stellt fest, ob pointcloud.py bereits definiert ist.
3. Nur beim ersten Mal: Source übertragen und compilieren.
4. CALL enthält nur runtime_id, Funktionsname und count.
5. Python erzeugt ndarray.
6. TransportManager erkennt dtype=float32 und nbytes≈60 MB.
7. Ergebnis wird als DataRef veröffentlicht.
8. Control Channel überträgt nur Descriptor und Handle.
9. Godot erhält Metadaten ohne 60 MB JSON-Parse.
10. materialize entscheidet Binary Stream, Datei oder Shared Memory.
11. Daten werden innerhalb von Byte-/Zeitbudgets materialisiert.
12. Erst nach READY wird die fertige Godot-Struktur verwendet.
13. Ein Folge-Call kann denselben Handle zurück an Python senden.
14. release beendet die Nutzung; Registry/GC bereinigt den Datensatz.
```

## 15.5 Folgeoperation ohne erneute Übertragung

```gdscript
var transformed: PythonBridgeResult = await PythonBridge.call_script(
    "pointcloud",
    "transform_cloud",
    [cloud_ref, 2.0],
    {},
    "default",
    60.0)
```

Python erkennt den Handle, greift auf das vorhandene Dataset zu und muss die 60 MiB nicht erneut von Godot empfangen. Der tatsächliche Vorteil hängt davon ab, ob die Operation in Python das vorhandene Array direkt oder eine neue Ausgabe benötigt.

## 15.6 Aktuelle Architektur gegenüber Zielarchitektur

| Schritt | Aktuelle v0.2-Ausführung | Zielarchitektur |
|---|---|---|
| Script | Source wird pro Call mitgeschickt | DEFINE einmal, CALL per Runtime-ID |
| ndarray | Binary Chunk möglich, aber komplette Antwort | DataRef/Stream nach Policy |
| Godot-Eingang | vollständige Dekodierung im Main-Thread | Raw Queue + Byte-/Zeitbudget |
| Wiederverwendung | Folge-Call sendet Daten erneut | Handle bleibt lokal verfügbar |
| Frame-Verhalten | abhängig von Payload-Größe | progressive Materialisierung |
| Fallback | JSON/Binary | JSON/Binary/File/Shared Memory nach Capabilities |

---

# 16. Risiken und mögliche neue Bottlenecks

## 16.1 Komplexität des TransportManagers

**Risiko:** Automatische Auswahl wird undurchsichtig.

**Gegenmaßnahme:** Jede Entscheidung wird mit Größe, Typ, Lebensdauer, Capability und Fallback-Grund geloggt. Policy bleibt zentral und testbar.

## 16.2 Handle-Leaks

**Risiko:** Python oder Godot vergisst `release`; große Daten bleiben im Speicher.

**Gegenmaßnahme:** Refcount, TTL, Session-GC, Speicherlimits, Shutdown-Cleanup und Warnungen für alte Handles.

## 16.3 Stale Handles nach Prozess-Restart

**Risiko:** Ein Handle zeigt auf Daten eines nicht mehr existierenden Python-Prozesses.

**Gegenmaßnahme:** Handle enthält Instance-/Session-Generation. Nach Restart werden alte Handles explizit als stale abgelehnt.

## 16.4 Sticky Routing erzeugt Lastungleichgewicht

**Risiko:** Ein Context mit persistentem Zustand wird sehr groß und bleibt auf einem Worker.

**Gegenmaßnahme:** Stateless Contexts dürfen migrieren; stateful Contexts zeigen ihre Affinität sichtbar. Optional Snapshot/Restore erst als spätere Ausbaustufe.

## 16.5 Mehrere Worker erzeugen Race Conditions

**Risiko:** Zwei Calls verändern denselben Namespace gleichzeitig.

**Gegenmaßnahme:** Context-Lock, standardmäßig serielle Context-Semantik, explizite parallele Contexts nur als spätere API-Erweiterung.

## 16.6 Prozess-Kill verliert Zustand

**Risiko:** Hard-Recovery löst zwar den Runaway Task, verliert aber Contexts und DataRefs.

**Gegenmaßnahme:** Kill nur nach Hard-Limit; wichtige Daten als persistierbare Datei oder rekonstruierbare Quelle behandeln; Recovery-Fehler strukturiert melden.

## 16.7 Datei-basierter Transport erzeugt I/O- und Cleanup-Kosten

**Risiko:** SSD-/Dateisystemlast, langsame Netzlaufwerke, Antivirus-Scans unter Windows, verwaiste Dateien.

**Gegenmaßnahme:** lokaler writable Workspace, eindeutige temporäre Namen, Prüfsummen, Cleanup-Index und Messung gegen Binary Frames.

## 16.8 Shared Memory ist nicht automatisch Zero-Copy in Godot

**Risiko:** Architektur verspricht weniger Kopien, als Packed Arrays tatsächlich ermöglichen.

**Gegenmaßnahme:** explizit zwischen „keine erneute Übertragung“, „eine schnelle memcpy“ und echtem externem Speicherzugriff unterscheiden.

## 16.9 Frame-Budgets können zu konservativ sein

**Risiko:** Framerate bleibt stabil, aber große Daten werden zu langsam materialisiert.

**Gegenmaßnahme:** Budgets konfigurierbar machen, adaptive Regelung untersuchen und Durchsatz/Latenz sichtbar messen.

## 16.10 Progress-Event-Flut

**Risiko:** Fortschrittsmeldungen selbst erzeugen Control-Overhead.

**Gegenmaßnahme:** Rate-Limit, Mindestfortschritt in Bytes oder Zeit, Zusammenfassung pro Frame.

## 16.11 Arrow-Abhängigkeit und GDExtension-Buildmatrix

**Risiko:** Neue Technologie erhöht Installations- und Distributionskomplexität stärker als sie Nutzen bringt.

**Gegenmaßnahme:** Arrow und GDExtension nur hinter optionalen Adaptern; Binary-/Handle-Pfad muss ohne sie vollständig funktionieren.

## 16.12 Noch zu messende Punkte

Die folgenden Aussagen dürfen vor Messung nicht als feste Leistungsversprechen dokumentiert werden:

- tatsächlicher WebSocket-Loopback-Durchsatz auf Windows/Linux/macOS;
- Crossover-Größe zwischen JSON, Binary, Datei und Shared Memory;
- Nutzen mehrerer Threads für die konkret verwendeten NumPy-/BLAS-Operationen;
- Thread-Sicherheit von JSON- und Packed-Array-Konvertierungen in WorkerThreadPool;
- Kosten der Materialisierung in Godot Packed Arrays;
- tatsächlicher Vorteil von Arrow gegenüber dem spezialisierten Numeric-Array-Format;
- Verhalten von Shared Memory und Cleanup nach Prozessabsturz;
- optimale Chunk-Größe und Frame-Budget;
- Speicherverbrauch des Data Object Stores unter Dauerlast.

---

# 17. Architektur-Entscheidungsmatrix und Abnahmekriterien

## 17.1 Entscheidungsmatrix

| Entscheidung | Problem | Ursache | Lösung | Erwarteter Vorteil | Neue Nachteile/Risiken | Priorität |
|---|---|---|---|---|---|---|
| Script Registry | Source wird bei jedem Call übertragen | `call_script()` liest und sendet den Source erneut | Hash-basierte `DEFINE`-Versionen und `CALL(runtime_id)` | weniger I/O, Hashing, JSON und Netzwerk | Registry-Eviction, Rebuild nach Restart | **Notwendig** |
| Compile Cache | `run()` kompiliert wiederholt | kein Code-Object-Cache | Cache nach Source-Hash + Python-Version | geringere Call-Latenz | zusätzlicher Speicher, keine ABI-Portabilität | **Sinnvoll** |
| Context Affinity | Zustand wird zwischen Instanzen geteilt | Auto-Routing kennt keinen persistenten Context | `context_key → instance_id` | korrekter Zustand und bessere Cache-Nutzung | Lastungleichgewicht, Migration schwierig | **Notwendig** |
| Numeric Binary Path | Zahlenlisten laufen durch JSON | Packed-Arrays nutzen keinen einheitlichen Binary-Pfad | Dtype-/Shape-Descriptor + rohe Bytes | deutlich weniger Payload und Allokationen | Dtype-/Endian-Tests und mehr Spezialpfade | **Notwendig** |
| Frame Budget Manager | große Antworten blockieren den Main-Thread | Dekodierung erfolgt vor der Inbox vollständig | Raw Queue + Byte-/Zeitbudget + progressive Materialisierung | stabile Framezeiten | größere Ergebnisse werden später fertig | **Notwendig** |
| DataRef/Handle | langlebige Daten werden mehrfach kopiert | kein gemeinsames Datenobjekt-Modell | Registry, Handle, retain/release, describe/materialize | Folgeoperationen ohne erneute Übertragung | Leaks, stale Handles, Ownership-Komplexität | **Sinnvoll** |
| Queue-/Execution-Timeout | Queue-Wartezeit sieht wie Python-Timeout aus | nur ein `created_at_ms` | getrennte Slot-, Queue- und Execution-Timeouts | korrektes Fehlerbild und bessere Policies | zusätzliche Zustände und API-Felder | **Notwendig** |
| Worker-/Prozess-Recovery | Runaway Task blockiert eine Instanz | Python-Threads können beliebigen Code nicht sicher abbrechen | kooperative Cancellation, Worker-Quarantäne, Prozess-Recovery | höhere Verfügbarkeit | Kill verliert Contexts und DataRefs | **Notwendig** |
| File-backed Transport | sehr große Daten über WS sind teuer | Control und Data Plane sind gekoppelt | mmap-Datei als optionaler Data Transport | wiederaufnehmbarer lokaler Transfer | I/O, Cleanup, Dateirechte | **Sinnvoll** |
| Shared Memory | gleiche lokale Daten werden erneut kopiert | kein portabler direkter Buffer-Zugriff in GDScript | capability-basierter Adapter, optional GDExtension | weniger Socket-Kopien bei Wiederverwendung | native Buildmatrix, Crash-Cleanup | **Optional** |
| Arrow Adapter | komplexe tabellarische Daten brauchen Schema | spezialisiertes Numeric-Format deckt Tabellen nicht ab | optionaler Arrow-Adapter hinter Data Plane | pandas-/Data-Engineering-Interoperabilität | große Abhängigkeit, kein eingebauter Godot-Reader | **Zukünftig** |

## 17.2 Definition of Done für Phase 0–2

Die ersten drei Phasen gelten erst als abgeschlossen, wenn alle folgenden Punkte erfüllt sind:

### Funktionale Kriterien

- Ein unverändertes Script wird nach der ersten Definition per Runtime-ID aufgerufen; der Source wird im Hot Path nicht erneut übertragen.
- Eine Source-Änderung erzeugt eine neue Version; laufende Tasks behalten die konfigurierte alte Version oder werden mit einem dokumentierten `SOURCE_SUPERSEDED`-Fehler beendet.
- Ein persistenter Context bleibt bei Auto-Routing an derselben Instanz, bis diese ausfällt.
- `PackedFloat32Array`, `PackedFloat64Array`, `PackedInt32Array` und `PackedInt64Array` können als validierte Binary-Daten übertragen werden.
- Große Ergebnisse können als Stream oder DataRef geliefert und später materialisiert werden.
- Queue-Timeout, Execution-Timeout und Transport-Timeout sind unterscheidbar.
- Ein abgebrochener oder fehlerhafter Stream gibt temporären Speicher und Handles frei.

### Stabilitätskriterien

- Der Godot-Main-Thread wartet nicht synchron auf Python, File-I/O oder Data-Plane-Materialisierung.
- Ein großer Einzel-Datensatz überschreitet das konfigurierte Decode-/Materialisierungsbudget nicht absichtlich; unvermeidbare Engine-Kosten werden gemessen und dokumentiert.
- Eine volle Queue, volle Inbox oder volle Stream-Window erzeugt einen strukturierten Fehler bzw. kontrolliertes Backpressure, niemals unbegrenztes Wachstum.
- Späte Ergebnisse für `TIMEOUT`, `CANCELLED` oder `STALE` verändern keinen Godot-State.
- Nach normalem Shutdown, Verbindungsabbruch und Prozess-Kill bleiben keine laufenden Python-Prozesse, temporären Streams oder registrierten Handles zurück.

### Kompatibilitätskriterien

- Bestehende Aufrufe wie `await PythonBridge.call_script(...)` funktionieren ohne Änderungen.
- Fehlt ein optionaler Transport, fällt die Bridge auf Binary Frames bzw. JSON zurück.
- Windows, Linux und macOS verwenden dieselbe logische API; Pfade und Cleanup sind plattformspezifisch getestet.
- Python-Source bleibt außerhalb der Bridge eine normale `.py`-Datei.
- Python-Code Objects werden niemals als GDScript-Code oder als plattformunabhängige Austauschbytes dokumentiert.

## 17.3 Benchmark-Abnahmekriterien

Vor der Aktivierung von Defaults müssen mindestens folgende Messungen auf allen Zielplattformen vorliegen:

| Benchmark | Messgröße | Vergleich |
|---|---|---|
| Script Registry | Source-Bytes pro Call, Compile-Zeit, p50/p95-Latenz | aktueller Source-in-Task-Pfad vs Runtime-ID |
| Numeric Arrays | Encode-/Decode-Zeit, Payload-Größe, Allokationen | JSON-Liste vs Binary Numeric Array |
| Große Ergebnisse | maximale Frame-Zeit, Materialisierungsdauer | Einzelresultat vs budgetierter Stream |
| DataRef | Anzahl Übertragungen bei drei Folgeoperationen | Kopie pro Call vs Handle |
| Worker | Durchsatz und Fehlerisolierung | 1 Worker vs mehrere Slots/Prozesse |
| File/Shared Memory | End-to-end-Latenz, RAM-Spitzen, Cleanup-Zeit | Binary Frame vs mmap vs Shared Memory |

Ein Transport darf nur zum Standard werden, wenn er in seinem Ziel-Use-Case einen reproduzierbaren Vorteil bietet und sein Fallback getestet ist.

---

# Schlussentscheidung

Die nächste Generation der Python Bridge sollte nicht primär ein neues IPC-Protokoll bauen. Die wichtigsten strukturellen Änderungen sind:

1. **Script Registry statt Source bei jedem Call.**
2. **Numeric Binary Path statt JSON-Zahlenlisten.**
3. **Handles statt wiederholter Übertragung langlebiger Daten.**
4. **Byte-/Zeitbudget statt unbeschränkter Main-Thread-Dekodierung.**
5. **Context-Affinität statt zufälligem Multi-Instance-Routing.**
6. **Worker-/Prozess-Recovery statt der Annahme, dass Threads sicher abbrechbar sind.**
7. **WebSocket/JSON für Control beibehalten und nur den Data Plane spezialisieren.**
8. **Shared Memory, mmap, Arrow und GDExtension erst nach Messung und hinter Fallbacks einführen.**

Damit bleibt die Bridge klein und transparent, während sie schrittweise für Punktwolken, Simulationen, Tensoren, Bilder und Data-Engineering-Daten wachsen kann.
