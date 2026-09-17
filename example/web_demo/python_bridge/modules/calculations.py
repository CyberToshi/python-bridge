"""Platform-independent demo module.

Identical code runs on Windows/Linux (real filesystem) and in the browser
(Pyodide virtual filesystem). No `if running_in_browser` anywhere - the
bridge compatibility layer handles the platform.
"""

import math


def circle_area(radius: float) -> float:
    return math.pi * radius * radius


def summarize(values) -> dict:
    values = list(values)
    return {
        "count": len(values),
        "sum": sum(values),
        "mean": sum(values) / len(values) if values else 0.0,
    }
