# Parallel Workers & Recovery (Phase 3)

Dieses Dokument beschreibt die **implementierte** Worker-/Recovery-Stufe
(Phase 3, Stand der Commits `623a23b` und `f6cfb1e`): mehrere Worker-Slots
pro Python-Instanz, strikte Context-Serialisierung, kooperative Cancellation
und den Watchdog gegen haengengebliebene Tasks.

**Wichtig vorab (GIL):** Mehrere Threads in einem CPython-Prozess machen
reine Python-CPU-Berechnung nicht parallel — Vorteile entstehen bei
I/O-lastigen Tasks sowie bei NumPy-/C-Operationen, die den GIL freigeben.
Fuer echte CPU-Parallelitaet braucht es mehrere Python-Prozesse
(Instanzgruppen, Ausbaustufe).

---

## 1. Konfiguration

```gdscript
{
    "workers_per_instance": 1,      # Worker-Slots im Python-Prozess
    "max_inflight_per_instance": 1, # gleichzeitig offene Units (Godot)
    "runaway_grace_ms": 10000,      # Watchdog-Frist; 0 = deaktiviert
}
```

Fuer Parallelitaet **beide** Werte erhoehen (z. B. beide auf 4):
`max_inflight_per_instance` begrenzt, wie viele Tasks Godot gleichzeitig an
die Instanz schickt; `workers_per_instance` bestimmt, wie viele davon im
Python-Prozess tatsaechlich nebeneinander laufen.

```gdscript
PythonBridge.configure({
    "workers_per_instance": 4,
    "max_inflight_per_instance": 4,
})
```

## 2. Was parallel laeuft — und was nicht

| Situation | Verhalten |
|---|---|
| Tasks **verschiedener Contexts** | laufen parallel (unterschiedliche Worker-Slots) |
| Tasks **desselben Contexts** | strikt seriell — nie gleichzeitig (geteilter Namespace) |
| Batch-Jobs | laufen als eine Unit; sperren alle ihre Contexts (sortiert, deadlock-frei) |
| Ein Task ueberschreitet sein Timeout | belegt nur seinen Slot; unabhaengige Contexts laufen weiter |

Die Godot-Seite verhindert bereits das Dispatch-Problem: Der Scheduler
merkt sich die gerade laufenden Contexts einer Instanz
(`running_contexts()`) und waehlt keine weiteren Tasks dieser Contexts aus,
bis sie fertig sind. So wartet ein Task nie in Python auf seinen eigenen
Context (kein versteckter Queue-Timeout).

## 3. Kooperative Cancellation

Ein laufender Thread darf nie „sicher“ unterbrochen werden. Stattdessen
kann dein Python-Code eigene Abbruchpunkte setzen — dann reagiert er auf
ein CANCEL (z. B. nach Timeout von Godot) kontrolliert:

```python
# langer Task mit Abbruchpunkten
def berechne(n: int) -> int:
    total = 0
    for i in range(n):
        __bridge__.checkpoint()          # wirft, wenn CANCEL vorliegt
        total += i
    return total
```

oder mit Schleifenbedingung:

```python
while not __bridge__.cancel_requested():
    do_work()
```

Ein via `checkpoint()`/`cancel_requested()` abgebrochener Task endet
strukturiert mit `status="cancelled"` (`CancelledError`) — kein
hinterlassener Slot, kein Folgefehler. Code ohne Abbruchpunkte kann nicht
kooperativ abgebrochen werden (bewusste Grenze); dann greift der Watchdog.

## 4. Watchdog / Kill-on-Runaway

Wird ein Task per Execution-Timeout abgebrochen, laeuft sein Thread
(sofern nicht kooperativ beendet) weiter und belegt Slot **und** Context.
Das ist fuer die Instanz tolerierbar, solange freie Slots existieren. Ein
wirklich haengender Task (Endlosschleife) wird nie von selbst fertig —
deshalb beendet sich der Prozess selbst, wenn ein solcher Job laenger als
`runaway_grace_ms` (Default 10 s) nach seinem Timeout weiterrechnet:

```text
RUNNING
  → Timeout (Ergebnis wird verworfen)
  → CANCEL (kooperativ, falls der Code Checkpoints hat)
  → Slot/Context bleiben reserviert (Isolation)
  → laeuft der Job nach runaway_grace_ms weiter:
    → Prozess beendet sich (Exit-Code != 0)
    → Godot erkennt den Crash und startet ueber die Restart-Policy neu
```

Kontext-Zustaende gehen bei einem Prozess-Neustart verloren (wie bei jedem
Crash) — die ScriptRegistry baut sie beim naechsten Call automatisch neu
auf (DEFINE-once, Phase 1).

## 5. Grenzen / naechste Ausbaustufe

- Echte CPU-Parallelitaet: mehrere Prozesse (Instanzgruppen) — geplant,
  noch nicht gebaut.
- Load-aware Routing ueber Instanzgruppen hinweg.
- Kontext-Slot-Quarantäne als persistenter Zustand (aktuell reicht die
  busy-Serialisierung + Watchdog-Neustart).
