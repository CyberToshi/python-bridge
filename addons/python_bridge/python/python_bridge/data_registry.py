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

import hashlib
import os
import threading

# Kategorien, die als DataRef gespeichert werden koennen.
SUPPORTED_KINDS = ("ndarray",)

TAG = "$pb"


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def cleanup_orphan_files(file_dir, tag):
    """Entfernt verwaiste Daten-Dateien einer Instanz (Crash-Cleanup beim
    Serverstart). Liefert die Anzahl entferner Dateien."""
    if not file_dir or not os.path.isdir(file_dir):
        return 0
    prefix = "data-%s-" % tag
    removed = 0
    try:
        for name in os.listdir(file_dir):
            if name.startswith(prefix) and name.endswith(".bin"):
                try:
                    os.remove(os.path.join(file_dir, name))
                    removed += 1
                except OSError:  # pragma: no cover
                    pass
    except OSError:  # pragma: no cover
        pass
    return removed


class DataStore:
    """Holds large reusable results keyed by a bridge-generated data id.

    Phase 4: Zusaetzlich zum In-Memory-Halten kann der Datensatz in eine
    Datei unter `file_dir` geschrieben werden (ein FileAccess-Gegenstueck in
    Godot kann ihn ohne WebSocket-Transfer chunkweise lesen). `tag` ist der
    Instanzname und macht Dateinamen ueber parallele Instanzen hinweg
    eindeutig. Dateien werden bei release()/clear() entfernt; verwaiste
    Dateien (Crash) raeumt der Server beim Start auf.
    """

    def __init__(self, threshold_bytes=0, file_dir=None, tag=""):
        self.threshold_bytes = int(threshold_bytes or 0)
        self.file_dir = file_dir
        self.tag = tag
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

    def _file_path(self, data_id):
        if not self.file_dir:
            return None
        return os.path.join(self.file_dir, "data-%s-%s.bin" % (self.tag, data_id))

    def _write_file(self, value, data_id, nbytes):
        """Schreibt die Rohbytes in eine Datei (sha256 als Integritaetsmerkmal).
        Fehler sind nicht fatal: der Datensatz bleibt In-Memory verfuegbar."""
        try:
            os.makedirs(self.file_dir, exist_ok=True)
            raw = value.tobytes(order="C")
            if len(raw) != nbytes:
                return None
            digest = _sha256_bytes(raw)
            path = self._file_path(data_id)
            with open(path, "wb") as f:
                f.write(raw)
            return {"file_path": path, "file_size": nbytes,
                    "file_sha256": digest}
        except Exception:  # pragma: no cover - defensiv (Schreibfehler)
            return None

    def _delete_file(self, data_id):
        path = self._file_path(data_id)
        if path:
            try:
                if os.path.exists(path):
                    os.remove(path)
            except OSError:  # pragma: no cover
                pass

    def _store(self, value, kind, nbytes):
        """Lock must be held by the caller."""
        self._seq += 1
        data_id = "data-%d" % self._seq
        self._values[data_id] = value
        meta = {
            "id": data_id,
            "kind": kind,
            "dtype": str(value.dtype) if kind == "ndarray" else "uint8",
            "shape": list(value.shape) if kind == "ndarray" else [nbytes],
            "nbytes": nbytes,
            "readonly": True,
        }
        file_info = self._write_file(value, data_id, nbytes)
        if file_info:
            meta.update(file_info)
        self._meta[data_id] = meta
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
        """Frees the backing store (inkl. Datei). Returns True when it existed."""
        with self._lock:
            had_value = self._values.pop(data_id, None) is not None
            self._meta.pop(data_id, None)
        if had_value:
            self._delete_file(data_id)
        return had_value

    def clear(self):
        """Gibt alles frei (inkl. aller Daten-Dateien dieser Instanz)."""
        with self._lock:
            data_ids = list(self._values.keys())
            self._values.clear()
            self._meta.clear()
        for data_id in data_ids:
            self._delete_file(data_id)

    def file_info(self, data_id):
        """Datei-Metadaten eines Handles (wenn file-backed)."""
        with self._lock:
            meta = self._meta.get(data_id)
            if meta is None:
                return None
            path = meta.get("file_path")
            if not path or not os.path.exists(path):
                return None
            return {
                "path": path,
                "size": int(meta.get("file_size", 0)),
                "sha256": meta.get("file_sha256", ""),
                "dtype": meta.get("dtype", "float64"),
                "shape": list(meta.get("shape", [])),
                "nbytes": int(meta.get("nbytes", 0)),
            }

    def count(self):
        with self._lock:
            return len(self._values)
