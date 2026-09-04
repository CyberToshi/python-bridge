"""Beispielskript für die Python Bridge.

Konventionen:
  - call_script: Der Rückgabewert der Funktion geht an Godot.
  - execute_script: `input` ist die Eingabe, `result` die Ausgabe.
"""

import math


def calculate(a: float, b: float = 2.0) -> float:
    """Berechnet a ** b."""
    return math.pow(a, b)


def greet(name: str, prefix: str = "Hello") -> str:
    """Begrüßt jemanden."""
    return "%s, %s!" % (prefix, name)


def fibonacci(n: int) -> list:
    """Liefert die ersten n Fibonacci-Zahlen."""
    seq = [0, 1]
    while len(seq) < n:
        seq.append(seq[-1] + seq[-2])
    return seq[:n]


# Für execute_script: Eingabe in `input`, Ergebnis in `result`.
result = None
if input:
    result = {"received": input}