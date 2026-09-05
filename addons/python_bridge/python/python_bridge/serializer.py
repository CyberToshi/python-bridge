"""Transparente, typisierte Serialisierung  (Python <-> gewählte Darstellung).

Konvention:
  Skalare (None/bool/int/float/str) bleiben JSON-Werte.
  Strukturierte Werte werden als getaggte Objekte {"$pb": "<tag>", ...} kodiert.
  Große Blobs (bytes, numpy.ndarray, Bilder) wandern in den Binary-Chunk-Stream.
"""
import base64
from collections.abc import Mapping, Sequence

TAG = "$pb"
INLINE_LIMIT = 512

# NumPy ist optional und wird genau einmal pro Prozess geprüft (lazy,
# gecacht). Vorher wurde der Import pro Wert ausgelöst - bei großen,
# elementweise serialisierten Datenstrukturen ein messbarer Overhead.
_NUMPY = None
_NUMPY_CHECKED = False


def _try_numpy():
    global _NUMPY, _NUMPY_CHECKED
    if not _NUMPY_CHECKED:
        _NUMPY_CHECKED = True
        try:
            import numpy as _numpy_impl
            _NUMPY = _numpy_impl
        except Exception:  # pragma: no cover - numpy fehlt
            _NUMPY = None
    return _NUMPY


def _blob(blob: bytes, chunks: list) -> dict:
    if len(blob) <= INLINE_LIMIT:
        return {"b": base64.b64encode(blob).decode("ascii")}
    chunks.append(blob)
    return {"chunk": len(chunks) - 1}


def encode_obj(value, chunks: list):
    """Python-Wert -> JSON-serialisierbarer Subbaum (+ evtl. Chunks)."""
    if value is None:
        return {TAG: "null"}
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return value
    if isinstance(value, str):
        return value

    # NumPy ist optional (Import-Ergebnis wird gecacht, siehe _try_numpy).
    np = _try_numpy()
    if np is not None:
        if isinstance(value, np.ndarray):
            arr = np.ascontiguousarray(value)
            desc = {TAG: "ndarray", "dtype": str(arr.dtype),
                    "shape": list(arr.shape), "order": "C", "nbytes": int(arr.nbytes)}
            desc.update(_blob(arr.tobytes(order="C"), chunks))
            return desc
        if isinstance(value, np.integer):
            return int(value)
        if isinstance(value, np.floating):
            return float(value)

    if isinstance(value, (bytes, bytearray)):
        return dict({TAG: "bytes"}, **_blob(bytes(value), chunks))
    if isinstance(value, tuple):
        return {TAG: "tuple", "v": [encode_obj(x, chunks) for x in value]}
    if isinstance(value, (set, frozenset)):
        return {TAG: "set", "v": [encode_obj(x, chunks) for x in value]}
    if isinstance(value, Mapping):
        out = {}
        for k, v in value.items():
            if not isinstance(k, (str, int, float, bool)):
                raise TypeError(
                    "Dict-Schlüssel müssen str/int/float/bool sein, war %r" % (k,))
            out[str(k)] = encode_obj(v, chunks)
        return {TAG: "dict", "v": out}
    if isinstance(value, Sequence):
        return {TAG: "arr", "v": [encode_obj(x, chunks) for x in value]}

    # Transparenter Fallback statt Absturz.
    return {TAG: "pyobject", "type": type(value).__name__, "text": repr(value)}


def decode_obj(value, chunks: list):
    """JSON-serialisierbarer Subbaum -> Python-Wert."""
    if isinstance(value, dict):
        if TAG in value:
            t = value[TAG]
            if t == "null":
                return None
            if t in ("vec2", "vec3", "vec4", "color", "transform3d"):
                return value["v"]
            if t == "bytes":
                return _blob_from(value, chunks)
            if t == "arr":
                return [decode_obj(x, chunks) for x in value["v"]]
            if t == "tuple":
                return tuple(decode_obj(x, chunks) for x in value["v"])
            if t == "set":
                return set(decode_obj(x, chunks) for x in value["v"])
            if t == "dict":
                return {k: decode_obj(v, chunks) for k, v in value["v"].items()}
            if t == "pyobject":
                return value.get("text", "")
            if t == "image":
                return _blob_from(value, chunks)
            if t == "ndarray":
                return decode_ndarray(value, chunks)
            # Numerische Godot-PackedArrays: kleine kommen als JSON-Zahlenliste
            # ("v"), grosse als Little-Endian-Rohbytes im Chunk-Stream. Mit
            # NumPy werden grosse Chunks zu ndarray materialisiert, sonst
            # bleiben sie raw bytes (transparenter, dokumentierter Fallback).
            if t in _NUMERIC_TAGS:
                if "v" in value:
                    return list(value["v"])
                return _decode_numeric(value, chunks)
            return None
        return {k: decode_obj(v, chunks) for k, v in value.items()}
    if isinstance(value, list):
        return [decode_obj(x, chunks) for x in value]
    return value


def _blob_from(v: dict, chunks: list):
    if "chunk" in v:
        return chunks[int(v["chunk"])]
    return base64.b64decode(v.get("b", "").encode("ascii"))


# Numerische Tags, die als Godot-PackedArray eintreffen koennen.
_NUMERIC_TAGS = ("i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64",
                 "f32", "f64")

# Tag -> numpy dtype Name fuer die Chunk-Materialisierung.
_NUMERIC_DTYPES = {"f32": "float32", "f64": "float64", "i32": "int32",
                    "i64": "int64", "i16": "int16", "u16": "uint16",
                    "i8": "int8", "u8": "uint8"}


def _decode_numeric(value: dict, chunks: list):
    """Chunk-Form eines numerischen Tags -> numpy-Array (falls verfuegbar)
    bzw. raw bytes. Fuer i8/u8 bleibt es bei bytes (Byte-Blob-Semantik)."""
    blob = _blob_from(value, chunks)
    declared = value.get("nbytes")
    if declared is not None and int(declared) != len(blob):
        return blob  # Descriptor-Mismatch: raw fallback, keine stille Garbage
    tag = value.get(TAG, "")
    if tag in ("i8", "u8"):
        return blob
    np = _try_numpy()
    if np is not None:
        dtype = _NUMERIC_DTYPES.get(tag)
        if dtype is not None:
            try:
                return np.frombuffer(blob, dtype=np.dtype(dtype))
            except Exception:  # pragma: no cover - defensive
                pass
    return blob


def decode_ndarray(v: dict, chunks: list):
    """ndarray-Tag -> numpy-Array (falls verfügbar) bzw. raw bytes."""
    dtype = v.get("dtype", "float64")
    shape = list(v.get("shape", []))
    raw = _blob_from(v, chunks)
    np = _try_numpy()
    if np is not None:
        try:
            # nbytes-Validierung: deklarierte Groesse muss zur Chunk-Groesse
            # passen (Korruptionserkennung, bevor reshape materialisiert).
            declared = v.get("nbytes")
            if declared is not None and int(declared) != len(raw):
                raise ValueError(
                    "ndarray descriptor mismatch: declared %d bytes, got %d"
                    % (int(declared), len(raw)))
            arr = np.frombuffer(raw, dtype=np.dtype(dtype))
            if shape:
                arr = arr.reshape(shape)
            return arr
        except Exception:
            pass
    return raw
