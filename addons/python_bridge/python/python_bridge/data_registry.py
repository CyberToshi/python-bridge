"""Per-connection data registry for Bridge Data Objects (DataRef handles).

Grosse Ergebnisse (numpy-Arrays oberhalb der konfigurierten Schwelle) werden
nicht mehr als ein riesiger Binary-Chunk ueber den WebSocket geschickt,
sondern im Python-Prozess aufbewahrt. Godot erhaelt stattdessen einen
leichten Descriptor (``data_ref``) und kann die Daten bei Bedarf explizit
materialisieren (DATA_GET) und freigeben (DATA_RELEASE).

Lebenszyklus / Cleanup:
  - Das Store gehoert einer Verbindung (ein Python-Prozess kann nach einem
    Godot-Crash theoretisch kurz weiterlaufen). Beim Verbindungsende wird
    ``clear()`` aufgerufen und damit der Speicher freigegeben.
  - Nach einem Prozess-/Verbindungstod sind alle Handles automatisch stale:
    Godot markiert seine Ref-Objekte ueber die Instanz-Lifecycle-Events.

Thread-Sicherheit: Alle Mutationen laufen ueber den einen Worker-Thread des
Servers (Store-Entscheidung in _run_job, GET/RELEASE ueber denselben Pool);
ein coarse Lock schuetzt zusaetzlich die RELEASE-Antwort aus dem
Event-Loop-Thread gegen einen gleichzeitigen Store.
"""

import threading

# Kategorien, die als DataRef gespeichert werden koennen.
SUPPORTED_KINDS = ("ndarray",)

TAG = "$pb"


class DataStore:
    """Holds large reusable results keyed by a bridge-generated data id."""

    def __init__(self, threshold_bytes=0):
        self.threshold_bytes = int(threshold_bytes or 0)
        self._lock = threading.Lock()
        self._values = {}
        self._meta = {}
        self._seq = 0

    # ------------------------------------------------------------- store path
    def maybe_ref(self, value, kind="ndarray"):
        """Entscheidet automatisch, ob `value` als Handle abgelegt wird.

        Liefert den data_ref-Descriptor, wenn `value` ein grosses
        unterstuetztes Objekt ist (nbytes >= threshold), sonst None
        (normaler Transfer). Nur die oberste Ebene wird betrachtet -
        verschachtelte kleine Strukturen bleiben normale Werte.
        """
        if self.threshold_bytes <= 0:
            return None
        if kind not in SUPPORTED_KINDS:
            return None
        if kind == "ndarray":
            try:
                import numpy as np
            except Exception:  # pragma: no cover
                return None
            if not isinstance(value, np.ndarray):
                return None
            nbytes = int(value.nbytes)
            if nbytes < self.threshold_bytes:
                return None
            arr = np.ascontiguousarray(value)
            with self._lock:
                data_id = self._store(arr, kind, nbytes)
            return {
                TAG: "data_ref",
                "id": data_id,
                "kind": kind,
                "dtype": str(arr.dtype),
                "shape": list(arr.shape),
                "nbytes": nbytes,
                "order": "C",
                "readonly": True,
            }
        return None

    def _store(self, value, kind, nbytes):
        """Lock must be held by the caller."""
        self._seq += 1
        data_id = "data-%d" % self._seq
        self._values[data_id] = value
        self._meta[data_id] = {
            "id": data_id,
            "kind": kind,
            "dtype": str(value.dtype) if kind == "ndarray" else "uint8",
            "shape": list(value.shape) if kind == "ndarray" else [nbytes],
            "nbytes": nbytes,
            "readonly": True,
        }
        return data_id

    # ------------------------------------------------------------- access path
    def get(self, data_id):
        with self._lock:
            return self._values.get(data_id), self._meta.get(data_id)

    def describe(self, data_id):
        with self._lock:
            meta = self._meta.get(data_id)
            return dict(meta) if meta is not None else None

    def release(self, data_id):
        """Frees the backing store. Returns True when it existed."""
        with self._lock:
            had_value = self._values.pop(data_id, None) is not None
            self._meta.pop(data_id, None)
            return had_value

    def clear(self):
        with self._lock:
            self._values.clear()
            self._meta.clear()

    def count(self):
        with self._lock:
            return len(self._values)
