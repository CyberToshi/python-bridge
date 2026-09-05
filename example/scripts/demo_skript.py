"""Demo-Skript für die Python Bridge Demo-Szene.

Stellt eine Auswahl an Funktionen bereit, die von der Godot-Demo-Szene
über `PythonBridge.call_script` aufgerufen werden:

  - calculate      : einfache Berechnung (a ** b)
  - greet          : String-Formatierung mit Argumenten + kwargs
  - fibonacci      : Liste (int -> Array)
  - vector_list    : Liste von Dictionaries (strukturierte Daten)
  - boom           : wirft absichtlich eine Exception
  - slow           : schläft (für Timeout-Tests)
  - big_blob       : liefert grosse Binärdaten (bytes)

Das Skript ist eine normale .py-Datei und kann auch ausserhalb von Godot
direkt importiert werden.
"""

import math
import time


def calculate(a: float, b: float = 2.0) -> float:
    """Berechnet a ** b."""
    return math.pow(a, b)


def greet(name: str, prefix: str = "Hello") -> str:
    """Begrüsst jemanden."""
    return "%s, %s!" % (prefix, name)


def fibonacci(n: int) -> list:
    """Liefert die ersten n Fibonacci-Zahlen."""
    seq = [0, 1]
    while len(seq) < n:
        seq.append(seq[-1] + seq[-2])
    return seq[:n]


def vector_list(count: int = 5) -> list:
    """Liefert eine Liste strukturierter Dictionaries."""
    return [{"x": i, "y": i * i, "name": "p%d" % i} for i in range(count)]


def boom() -> None:
    """Wirft absichtlich eine ValueError-Exception (für die Fehler-Demo)."""
    raise ValueError("Absichtlicher Demo-Fehler aus Python")


def slow(seconds: float = 2.0) -> str:
    """Schläft `seconds` Sekunden (für die Timeout-Demo)."""
    time.sleep(seconds)
    return "fertig nach %.1fs" % seconds


def big_blob(size: int = 200000) -> bytes:
    """Liefert einen grossen Binär-Buffer (für die Binary-Frame-Demo)."""
    return bytes(i % 256 for i in range(size))