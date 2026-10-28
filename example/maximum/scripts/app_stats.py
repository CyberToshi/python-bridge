"""Beispielmodul für das Maximalbeispiel.

Deklariert seine Abhängigkeit selbst — die Bridge installiert fehlende Pakete
beim ersten Aufruf in die venv. Die Zeile muss auf Top-Level stehen, die
Position in der Datei ist frei.
"""

import numpy as np

__bridge_deps__ = ["numpy"]


def describe(values, bins=8):
    """Kleine Statistik als Dictionary zurückgeben."""
    arr = np.asarray(values, dtype="float64")
    hist, edges = np.histogram(arr, bins=bins)
    return {
        "count": int(arr.size),
        "mean": float(arr.mean()),
        "std": float(arr.std()),
        "hist": hist.tolist(),
        "edges": edges.tolist(),
    }


def big_matrix(n=64):
    """Ergebnis deutlich über der DataRef-Schwelle: kommt als Handle an."""
    return np.arange(n * n, dtype="float64").reshape(n, n)
