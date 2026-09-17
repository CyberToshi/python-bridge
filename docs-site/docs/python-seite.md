---
sidebar_position: 6
title: Python-Seite verstehen
description: Was beim Ausführen deines Python-Codes passiert – Kontexte, Zustand, Ausgaben, Abbruch.
---

# Python-Seite verstehen

Du schreibst normales Python. Damit du aber genau weißt, **was** wann läuft
und wo Zustand bleibt, erklärt diese Seite die Ausführungs-Semantik der
Bridge.

## Ein Kontext pro Skript

Jede Python-Instanz hält **Kontexte**: persistente Namespaces. Ein Skript
`hello.py` läuft im Kontext `script:res://python_bridge/scripts/hello.py`.
Das hat drei praktische Konsequenzen:

1. **Modul-Zustand bleibt erhalten.** Variablen, Importe und Klassen auf
   Modulebene überleben zwischen mehreren `call_script`-Aufrufen.
2. **Mehrere Skripte stören sich nicht.** Jedes Skript hat seinen eigenen
   Namespace.
3. **Der Kontext wird nur bei Änderung neu geladen.** Die Bridge vergleicht
   den SHA-256-Hash des Sources. Unveränderter Code wird nicht erneut
   übertragen und nicht erneut definiert.

```python
# counter.py – der Zähler bleibt über Aufrufe hinweg erhalten
_counter = 0

def increment(step: int = 1) -> dict:
    global _counter
    _counter += step
    return {"counter": _counter}
```

```gdscript
await PythonBridge.call_script("counter", "increment", [], {}, "default", 10.0)  # {"counter": 1}
await PythonBridge.call_script("counter", "increment", [], {}, "default", 10.0)  # {"counter": 2}
```

:::tip Gut zu wissen
Der Namespace heißt intern `__pybridge__` (nicht `__main__`). Ein
`if __name__ == "__main__":`-Block wird deshalb **nicht** ausgeführt.
:::

## Die drei Ausführungsarten

| Godot-Aufruf | Python-seitig | Wann? |
|---|---|---|
| `call_script(id, fn, args)` | **call** – definiert Kontext nur bei Änderung, ruft dann `fn(*args, **kwargs)` | Standard für Funktionen aus Dateien |
| `execute_script(id, input)` | **run** – führt die Datei **bei jedem Aufruf neu aus**; Variablen `input`/`result` | Skript als „Programm“, Modul-Zustand bleibt trotzdem |
| `execute(code)` | **run** im frischen Kontext `temp-N` | Kurzlebigen Code, kein Zustand gewollt |
| `define_script(id)` | **define** – führt die Datei einmal aus, ruft nichts auf | Initialisierung/Vorbereitung |

Beim **run**-Stil gilt die `input`/`result`-Konvention:

```python
# datum.py – wird mit execute_script("datum", {...}) aufgerufen
import datetime

result = {
    "eingabe": input,
    "heute": str(datetime.date.today()),
}
```

Beim **call**-Stil ist die Funktion die Schnittstelle – Argumente kommen
positional oder als Keywords, der `return`-Wert ist das Ergebnis.

## Funktionen schreiben

- **Type-Hints sind optional und nur Dokumentation** – sie werden nicht
  erzwungen und nicht zur Laufzeit geprüft.
- **Default-Werte gehören nach Python.** Der generierte GDScript-Wrapper
  erkennt sie und lässt sie weg, wenn du sie nicht übergibst (Python bleibt
  autoritativ).
- Python akzeptiert beliebige Argumentarten, die der Wrapper über
  `*args`/`**kwargs`-Strukturen korrekt weiterreicht (posonly, varargs,
  kwonly, `**kwargs`).

```python
def berechne(a: float, b: float = 2.0, *, faktor: float = 1.0) -> float:
    """Multipliziert a und b und skaliert mit faktor."""
    return (a * b) * faktor
```

```gdscript
# b defaultet auf Python-Seite (2.0); faktor als Keyword
var r := await PythonBridge.call_script(
    "rechnen", "berechne", [3.0], {"faktor": 10.0})
```

## Fehler und Tracebacks

Tritt in Python eine Exception auf, stirbt **nichts**: Der Prozess bleibt
leben, der Task endet strukturiert fehlgeschlagen.

```gdscript
if r.is_error():
    print("Code:    ", r.error_code())            # PYTHON_EXCEPTION
    print("Typ:     ", r.error.get("type"))       # z. B. ValueError
    print("Meldung: ", r.error.get("message"))
    print("Traceback:", r.error.get("traceback")) # vollständig, inkl. <bridge:...>-Zeilen
```

Im Traceback siehst du Zeilen wie
`File "<bridge:script:res://.../rechnen.py>", line 3, in berechne` – der
Dateiname verrät den Kontext, in dem der Code lief.

## Ausgaben (print) – ehrlich erklärt

`print()` und `stderr` deines Codes werden **serverseitig erfasst** und
**begrenzt** (`max_stdout_bytes`/`max_stderr_bytes`, Default je 1 MiB; bei
Überschreitung wird der Rest verworfen und als „truncated“ markiert).

Derzeit werden diese erfassten Ausgaben aber **nicht automatisch in die
Godot-Konsole durchgereicht**. Wenn du etwas im Godot-Output sehen willst:

- gib Werte per `return` zurück und `print()`-e sie in GDScript, oder
- logge sie selbst (z. B. über `bridge_event`-fähige Rückgaben, falls du
  eigene Events baust).

Ein `print()` in Python ist also eher zum Debuggen im Log des Python-Servers
nützlich als für die Godot-Konsole.

## Lange Aufgaben abbrechen (kooperativ)

Ein Python-Thread lässt sich **nicht sicher von außen killen**. Deshalb gibt
es zwei Ebenen:

1. **Kooperative Cancellation (Standard).** In jedem Kontext liegt ein
   Helfer `__bridge__`:

```python
def lange_rechnung(n: int) -> int:
    total = 0
    for i in range(n):
        __bridge__.checkpoint()   # wirft intern, sobald CANCEL eingetroffen ist
        total += i
    return total

# Alternative ohne Exception: Schleife beenden und Teilergebnis liefern
def mache_etwas(limit: int) -> int:
    i = 0
    while i < limit and not __bridge__.cancel_requested():
        tu_arbeit(i)
        i += 1
    return i
```

   Bricht Godot den Task ab (`cancel_task` bzw. Timeout), endet der Task
   strukturiert mit `status = cancelled` / `TASK_ERROR` (`CancelledError`).
   Wirf **keine** eigene Exception als „Abbruch“ – das wäre ein normaler
   Python-Fehler (`PYTHON_EXCEPTION`). Nutze `checkpoint()` oder prüfe
   `cancel_requested()` und kehre sauber zurück.

2. **Watchdog (letzte Maßnahme).** Ohne Checkpoints läuft der Thread weiter.
   Nach dem Timeout gibt es eine Gnadenfrist (`runaway_grace_ms`, Default
   10 s). Läuft der Job dann immer noch, **beendet sich der Python-Prozess
   selbst** und wird gemäß Restart-Policy neu gestartet. Folge: Kontexte
   dieses Prozesses sind weg und werden beim nächsten Aufruf automatisch
   wieder aufgebaut (Registry-Selbstheilung) – dein Godot-Zustand bleibt
   unberührt, aber **Python-Modulzustand ist nach so einem Neustart verloren**.

## Mehrere Instanzen & Parallelität

- Mehrere **Instanzen** = mehrere Prozesse = echte CPU-Parallelität
  (GIL-unabhängig). Starte sie mit eigenen Namen:
  `start_instance("worker-a")`, `start_instance("worker-b")`.
- `workers_per_instance > 1` = mehrere Threads **innerhalb** eines Prozesses.
  Davon profitieren I/O-lastige Aufgaben und Bibliotheken, die den GIL
  freigeben (NumPy, …). Reiner Python-CPU-Code skaliert darüber **nicht**.
- Kontexte sind **instanzgebunden**: gib bei persistentem Zustand immer
  dieselbe Instanz an. Auto-Zuordnung (`instance_id = ""` bei raw Tasks)
  kann zwischen Instanzen wechseln und verliert dann Kontextzustand.

## NumPy & schwere Bibliotheken

- Die venv enthält von Haus aus nur `websockets`. Zusätzliche Pakete kommen
  über die Konfiguration:

```gdscript
PythonBridge.configure({"dependencies": ["numpy"]})
```

  (vor `start_instance`) – oder manuell in die Workspace-venv:
  `<workspace>/venv/bin/python -m pip install numpy`.

- NumPy-Arrays werden zu **typisierten Godot-Arrays** konvertiert; große
  Ergebnisse ab `data_ref_threshold_bytes` (Default 16 MiB) werden
  automatisch zu **DataRef-Handles** statt direkt übertragen. Details:
  [Große Daten (DataRefs)](./datenebene).

## Beispiel: komplettes Python-Skript

```python
# analyse.py – persistenter Kontext, numpy, langer Lauf mit Checkpoints
import time
import numpy as np

_data = None                      # Modulzustand: bleibt zwischen Aufrufen

def prepare(n: int) -> dict:
    """Erzeugt einen Datenpuffer und merkt ihn sich."""
    global _data
    _data = np.linspace(0.0, 1.0, n)
    return {"n": n, "dtype": str(_data.dtype)}

def summe_mit_checkpoints(anzahl: int = 10) -> float:
    """Simulierte lange Rechnung – sauber abbrechbar."""
    total = 0.0
    for i in range(anzahl):
        __bridge__.checkpoint()          # reagiert auf CANCEL
        time.sleep(0.05)
        total += float(np.sum(_data)) if _data is not None else 0.0
    return total
```

```gdscript
await PythonBridge.call_script("analyse", "prepare", [1000])
var r := await PythonBridge.call_script("analyse", "summe_mit_checkpoints", [20], {}, "default", 5.0)
```

Verwandt: [API-Referenz](./api) · [Große Daten](./datenebene) ·
[Konfiguration](./konfiguration)
