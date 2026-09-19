---
sidebar_position: 6
title: Cython-Module (Desktop)
description: Rechenlastige Teile als .pyx kompilieren - mit Compiler-Fallback ohne System-Setup, Web bewusst ausgeschlossen.
---

# Cython-Module (Desktop)

Rechenintensive Funktionen (physik-nahe Schleifen, eigene Numerik) dürfen als
**Cython** geschrieben werden. Die Bridge behandelt `.pyx`-Skripte beim
Aufruf (`call_script`) genauso wie `.py`-Skripte — kompilieren, Import und
Namespace-Verdrahtung passieren automatisch.

:::note Nur Desktop
Cython braucht einen C-Compiler zur Build-Zeit. Im **Web-Export** (Pyodide)
gibt es keinen Compiler — `.pyx` wird dort bewusst nicht unterstützt; der
Export-Check warnt, wenn `.pyx`-Dateien im Projekt liegen.
:::

## Schnellstart

1. Im Python-Editor-Dock den Toggle **„Als Cython-Modul kompilieren (.pyx)“**
   aktivieren — die Datei wird ab sofort als `.pyx` gespeichert (bestehende
   `.py`-Dateien werden beim Umschalten umbenannt, der Inhalt bleibt).
2. Normales Python mit Cython-Typisierungen schreiben:

```python
# scripts/mathtools.pyx
import numpy as np          # Importe immer auf Modulebene

__bridge_deps__ = ["numpy"]

def smear(list xs, int passes):
    cdef double s = 0.0
    cdef int i
    for i in range(passes):
        s += xs[i % len(xs)]
    return s * 0.5
```

3. Aufrufen wie gewohnt — der Build passiert **automatisch vor dem ersten
   Aufruf** (oder manuell über den Button **Compile Cython**):

```gdscript
var r := await PythonBridge.call_script("mathtools", "smear", [3.5, 100_000])
```

## Was automatisch passiert

| Schritt | Mechanismus |
|---|---|
| Build-Trigger | Erster `call_script` auf ein `.pyx`-Skript ohne kompilierte Seite, Editor-Button oder `PythonBridge.compile_cython()` |
| Change-Detection | SHA-256 der `.pyx` gegen `.cython_state.json`; **unveränderte Module werden übersprungen** (Start bleibt schnell) |
| Kompilieren | inkrementell via setuptools `build_ext --inplace` in der bestehenden venv |
| Compiler | System-Compiler (gcc/cc/clang bzw. MSVC), **falls vorhanden** — sonst automatischer Fallback auf das pip-Paket `ziglang` (kompletter C-Compiler als Wheel, kein System-Setup) |
| Pakete | Fehlende Build-Komponenten (`cython`, `setuptools`, ggf. `ziglang`) installiert das Tool **selbst in die venv**; Skript-Deps wie `numpy` kommen wie gehabt über `__bridge_deps__` |
| Aufruf | Das kompilierte Modul wird importiert; seine öffentlichen Funktionen liegen im persistenten Kontext — `call_script` verhält sich identisch zu `.py` |

## Voraussetzungen

- **Python-Header** für die Build-Zeit: Linux `python3-dev` (bei den meisten
  Distributionen schon da), Windows bringt die venv-Header mit.
- **System-Compiler optional**: ohne gcc/MSVC übernimmt `ziglang`
  (`__bridge_deps__ = ["ziglang"]` oder automatische Selbstinstallation).
  Der erste zig-Build braucht ~30–60 s (eigener Stdlib-Cache), danach ist er
  genauso inkrementell schnell wie gcc.
- **Windows**: mit installierten „Build Tools for Visual Studio" nutzt die
  Bridge den MSVC automatisch; ohne ihn greift der ziglang-Fallback.

## Fehlerbilder

| Meldung | Ursache | Lösung |
|---|---|---|
| `CythonModuleNotFound` | `.pyx` noch nicht kompiliert (Build fehlgeschlagen) | Details aus dem Build-Report im Godot-Log; nach Fix erneut **Compile Cython** |
| `Cython-Build-Komponenten fehlen` | Self-Provisioning ausgeschaltet (`--no-install`) oder ohne Netz | `pip install cython setuptools` in der venv |
| Compile-Fehler im Report | Syntax-/Typfehler im Cython-Code | Fehlerzeile steht im `errors[0].message` des Reports |
| Web-Export warnt über `.pyx` | Cython im Browser nicht möglich | Diese Skripte Desktop-only nutzen oder in `.py` mit numpy lösen |

## Grenzen (ehrlich)

- Der **erste** Build eines Moduls dauert einige Sekunden (Cython + C-Compile)
  — geplante Hot-Reload-Zyklen daher lieber in `.py` entwickeln und erst für
  die produktive Nutzung auf `.pyx` umschalten.
- `cdef`-Klassen und C-Importe funktionieren wie in Cython üblich; reine
  Python-Imports (numpy & Co.) bleiben normal nutzbar.
- Der Build läuft außerhalb des Bridge-Servers als eigener Kurzprozess — ein
  fehlgeschlagener Build kann die laufende Instanz nie destabilisieren.
