"""Demo-Skript für den Crash-Restart-Test.

`crash()` beendet den Python-Prozess absichtlich mit Exit-Code 1.
Die Bridge erkennt den Absturz, markiert laufende Tasks als fehlgeschlagen
und startet die Instanz gemäss Retry-Konfiguration (Exponential Backoff)
automatisch neu.

ACHTUNG: Dieses Skript crasht den Python-Prozess der Instanz, auf der es
ausgeführt wird. Danach muss die Instanz neu gestartet bzw. der Restart
abgewartet werden. Nur für Demonstrationszwecke verwenden.
"""

import os


def crash() -> None:
    """Beendet den Prozess sofort mit Exit-Code 1."""
    os._exit(1)