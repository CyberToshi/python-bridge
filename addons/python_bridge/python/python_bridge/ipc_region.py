"""Local shared-memory IPC coordination for large Python Bridge data.

Only compact metadata crosses the WebSocket control channel. The actual buffer
is owned by a local process backend and is addressed by a stable region id.
"""
from __future__ import annotations

import hashlib
from enum import Enum
from typing import Any, Dict, List, Optional


def region_id_from_label(label: str) -> str:
    return "pbshm_" + hashlib.sha256(label.encode("utf-8")).hexdigest()[:16]


class Endianness(str, Enum):
    LITTLE = "little"
    BIG = "big"


NUMERIC_DTYPES = {
    "int8": {"size": 1, "fmt": "b"}, "uint8": {"size": 1, "fmt": "B"},
    "int16": {"size": 2, "fmt": "h"}, "uint16": {"size": 2, "fmt": "H"},
    "int32": {"size": 4, "fmt": "i"}, "uint32": {"size": 4, "fmt": "I"},
    "int64": {"size": 8, "fmt": "q"}, "uint64": {"size": 8, "fmt": "Q"},
    "float32": {"size": 4, "fmt": "f"}, "float64": {"size": 8, "fmt": "d"},
}
RegionLayout = Dict[str, Any]


def layout_bytes(layout: RegionLayout) -> int:
    info = NUMERIC_DTYPES.get(layout.get("dtype", "float64"))
    if info is None:
        raise ValueError(f"Unsupported dtype: {layout.get('dtype')!r}")
    return info["size"] * int(layout.get("items", 0))


class RegionState(str, Enum):
    CREATED = "created"
    FILLING = "filling"
    READY = "ready"
    IN_USE = "in_use"
    FINISHED = "finished"
    RELEASED = "released"
    ERROR = "error"


class RegionDescriptor:
    __slots__ = ("id", "label", "owner", "size", "layout", "state", "readonly", "created_at_ms", "error")

    def __init__(self, *, id: str, label: str, owner: str, size: int,
                 layout: RegionLayout, state: RegionState = RegionState.CREATED,
                 readonly: bool = False, created_at_ms: Optional[int] = None,
                 error: Optional[str] = None):
        self.id, self.label, self.owner = id, label, owner
        self.size, self.layout = int(size), dict(layout)
        self.state = RegionState(state)
        self.readonly, self.created_at_ms = bool(readonly), int(created_at_ms or 0)
        self.error = error

    def to_control_message(self) -> Dict[str, Any]:
        return {"type": "pb_region_meta", "id": self.id, "label": self.label,
                "owner": self.owner, "size": self.size, "layout": self.layout,
                "state": self.state.value, "readonly": self.readonly,
                "created_at_ms": self.created_at_ms, "error": self.error}

    @classmethod
    def from_control_message(cls, msg: Dict[str, Any]) -> "RegionDescriptor":
        return cls(id=msg.get("id", ""), label=msg.get("label", ""),
                   owner=msg.get("owner", ""), size=int(msg.get("size", 0)),
                   layout=msg.get("layout", {}), state=msg.get("state", "created"),
                   readonly=bool(msg.get("readonly", False)),
                   created_at_ms=int(msg.get("created_at_ms", 0)), error=msg.get("error"))

    def is_valid(self) -> bool:
        return bool(self.id) and self.size >= 0 and bool(self.layout)


class RegionError(Exception):
    pass


def control_error(code: str, message: str, region_id: str = "") -> Dict[str, Any]:
    result = {"type": "pb_region_error", "code": code, "message": message}
    if region_id:
        result["id"] = region_id
    return result


class SharedRegionManager:
    def __init__(self, owner: str = "unknown"):
        self._owner = owner
        self._regions: Dict[str, Dict[str, Any]] = {}

    @property
    def owner(self) -> str:
        return self._owner

    def create(self, label: str, layout: RegionLayout, *, owner: Optional[str] = None,
               created_at_ms: Optional[int] = None, buffer_backend: Any = None) -> RegionDescriptor:
        rid = region_id_from_label(label)
        if rid in self._regions:
            raise RegionError(f"Region already exists: {rid}")
        size = layout_bytes(layout)
        if size <= 0:
            raise RegionError(f"Invalid layout size for {label!r}")
        meta = {"label": label, "owner": owner or self._owner, "layout": dict(layout),
                "size": size, "state": RegionState.CREATED, "readonly": False,
                "created_at_ms": int(created_at_ms or 0), "error": None,
                "buffer": None, "attached_by": []}
        if buffer_backend is not None and buffer_backend.available:
            try:
                meta["buffer"] = buffer_backend.create(rid, size, layout)
            except Exception as exc:
                raise RegionError(f"Backend create failed for {rid!r}: {exc}") from exc
        self._regions[rid] = meta
        return self._descriptor(rid)

    def attach(self, region_id: str, attached_by: str = "client") -> RegionDescriptor:
        meta = self._require(region_id)
        if meta["state"] in (RegionState.RELEASED, RegionState.ERROR):
            raise RegionError(f"Region not attachable: {region_id}")
        if attached_by not in meta["attached_by"]:
            meta["attached_by"].append(attached_by)
        return self._descriptor(region_id)

    def ensure_registered(self, region_id: str, descriptor: RegionDescriptor) -> RegionDescriptor:
        if region_id not in self._regions:
            self._regions[region_id] = {"label": descriptor.label, "owner": descriptor.owner,
                "layout": dict(descriptor.layout), "size": descriptor.size,
                "state": descriptor.state, "readonly": descriptor.readonly,
                "created_at_ms": descriptor.created_at_ms, "error": descriptor.error,
                "buffer": None, "attached_by": [descriptor.owner]}
        return self._descriptor(region_id)

    def get_backend(self, region_id: str):
        return self._require(region_id).get("buffer")

    def _transition(self, region_id: str, allowed, target: RegionState) -> RegionDescriptor:
        meta = self._require(region_id)
        if meta["state"] not in allowed:
            raise RegionError(f"Cannot set {target.value} from {meta['state'].value} on {region_id}")
        meta["state"] = target
        return self._descriptor(region_id)

    def set_filling(self, region_id): return self._transition(region_id, (RegionState.CREATED,), RegionState.FILLING)
    def set_ready(self, region_id): return self._transition(region_id, (RegionState.FILLING,), RegionState.READY)
    def set_in_use(self, region_id): return self._transition(region_id, (RegionState.READY, RegionState.IN_USE), RegionState.IN_USE)
    def set_finished(self, region_id): return self._transition(region_id, (RegionState.IN_USE, RegionState.READY), RegionState.FINISHED)

    def set_error(self, region_id: str, error: str) -> RegionDescriptor:
        meta = self._require(region_id)
        meta["state"], meta["error"] = RegionState.ERROR, str(error)
        return self._descriptor(region_id)

    def release(self, region_id: str, *, detach_attached: bool = True, buffer_backend: Any = None) -> RegionDescriptor:
        meta = self._require(region_id)
        if meta["owner"] != self._owner:
            raise RegionError(f"Only the owner may release {region_id}")
        if meta["state"] in (RegionState.RELEASED, RegionState.ERROR):
            return self._descriptor(region_id)
        if meta.get("buffer") is not None and buffer_backend is not None and buffer_backend.available:
            buffer_backend.release_region(region_id)
            meta["buffer"] = None
        meta["state"] = RegionState.RELEASED
        if detach_attached:
            meta["attached_by"] = []
        return self._descriptor(region_id)

    def cleanup(self, region_id: str) -> RegionDescriptor:
        meta = self._require(region_id)
        meta["state"], meta["error"] = RegionState.RELEASED, "cleaned_up"
        self._regions.pop(region_id)
        return self._descriptor_from_meta(region_id, meta)

    def descriptor(self, region_id): return self._descriptor(region_id)
    def list_descriptors(self) -> List[RegionDescriptor]: return [self._descriptor(rid) for rid in sorted(self._regions)]
    def _require(self, region_id):
        if region_id not in self._regions:
            raise RegionError(f"Unknown region: {region_id}")
        return self._regions[region_id]
    def _descriptor(self, region_id): return self._descriptor_from_meta(region_id, self._regions[region_id])
    @staticmethod
    def _descriptor_from_meta(region_id, meta):
        return RegionDescriptor(id=region_id, label=meta["label"], owner=meta["owner"],
            size=meta["size"], layout=meta["layout"], state=meta["state"],
            readonly=meta.get("readonly", False), created_at_ms=meta.get("created_at_ms", 0),
            error=meta.get("error"))
