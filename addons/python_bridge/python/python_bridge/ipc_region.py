"""Shared-memory region coordination for the IPC high-performance path.

Design goals:
  - keep ownership explicit and stable
  - keep data in shared RAM, not transported repeatedly over WebSocket
  - keep only small metadata on the control channel
  - make the model local-first, but portable enough for later cluster routing

The region model is intentionally simple:
  - one region = one named shared-memory buffer
  - one owner coordinates creation, filling, readiness, release, cleanup
  - other sides attach by id and read/write under the owner's coordination
  - metadata travels as small structured data; big data does not

This module does **not** assume distributed orchestration. It only defines the
shared-memory contract and local operations. Higher-level distribution,
for example Docker-based scheduling, is an external concern and may use this
contract as its data-sharing interface.
"""

from __future__ import annotations

import hashlib
from enum import Enum
from typing import Any, Dict, List, Optional


def region_id_from_label(label: str) -> str:
    """Stable, safe region id derived from a human label."""
    digest = hashlib.sha256(label.encode("utf-8")).hexdigest()
    return "pbshm_" + digest[:16]


class Endianness(str, Enum):
    LITTLE = "little"
    BIG = "big"


NUMERIC_DTYPES: Dict[str, Dict[str, Any]] = {
    "int8": {"size": 1, "fmt": "b"},
    "uint8": {"size": 1, "fmt": "B"},
    "int16": {"size": 2, "fmt": "h"},
    "uint16": {"size": 2, "fmt": "H"},
    "int32": {"size": 4, "fmt": "i"},
    "uint32": {"size": 4, "fmt": "I"},
    "int64": {"size": 8, "fmt": "q"},
    "uint64": {"size": 8, "fmt": "Q"},
    "float32": {"size": 4, "fmt": "f"},
    "float64": {"size": 8, "fmt": "d"},
}


RegionLayout = Dict[str, Any]


def layout_bytes(layout: RegionLayout) -> int:
    """Total bytes required for a homogeneous numeric layout."""
    dtype = layout.get("dtype", "float64")
    items = layout.get("items", 0)
    info = NUMERIC_DTYPES.get(dtype)
    if info is None:
        raise ValueError(f"Unsupported dtype: {dtype!r}")
    return info["size"] * int(items)


class RegionState(str, Enum):
    CREATED = "created"
    FILLING = "filling"
    READY = "ready"
    IN_USE = "in_use"
    FINISHED = "finished"
    RELEASED = "released"
    ERROR = "error"


class RegionDescriptor:
    """Small metadata for a shared region. This is what travels over the
    control channel, not the data itself."""

    __slots__ = (
        "id",
        "label",
        "owner",
        "size",
        "layout",
        "state",
        "readonly",
        "created_at_ms",
        "error",
    )

    def __init__(
        self,
        *,
        id: str,
        label: str,
        owner: str,
        size: int,
        layout: RegionLayout,
        state: RegionState = RegionState.CREATED,
        readonly: bool = False,
        created_at_ms: Optional[int] = None,
        error: Optional[str] = None,
    ) -> None:
        self.id = id
        self.label = label
        self.owner = owner
        self.size = int(size)
        self.layout = dict(layout)
        self.state = state
        self.readonly = bool(readonly)
        self.created_at_ms = int(created_at_ms or 0)
        self.error = error

    def to_control_message(self) -> Dict[str, Any]:
        """Minimal control-message shape for metadata exchange."""
        return {
            "type": "pb_region_meta",
            "id": self.id,
            "label": self.label,
            "owner": self.owner,
            "size": self.size,
            "layout": self.layout,
            "state": self.state.value,
            "readonly": self.readonly,
            "created_at_ms": self.created_at_ms,
            "error": self.error,
        }

    @classmethod
    def from_control_message(cls, msg: Dict[str, Any]) -> "RegionDescriptor":
        """Reconstruct from a control message."""
        return cls(
            id=msg.get("id", ""),
            label=msg.get("label", ""),
            owner=msg.get("owner", ""),
            size=int(msg.get("size", 0)),
            layout=msg.get("layout", {}),
            state=RegionState(msg.get("state", RegionState.CREATED.value)),
            readonly=bool(msg.get("readonly", False)),
            created_at_ms=int(msg.get("created_at_ms", 0)),
            error=msg.get("error"),
        )

    def is_valid(self) -> bool:
        return bool(self.id) and self.size >= 0 and bool(self.layout)

    def __repr__(self) -> str:
        return (
            f"<RegionDescriptor id={self.id!r} owner={self.owner!r} "
            f"bytes={self.size} state={self.state.value} error={self.error!r}>"
        )


class RegionError(Exception):
    """Public region coordination error."""


def control_error(code: str, message: str, region_id: str = "") -> Dict[str, Any]:
    """Small structured error for control-channel exchange."""
    out: Dict[str, Any] = {
        "type": "pb_region_error",
        "code": code,
        "message": message,
    }
    if region_id:
        out["id"] = region_id
    return out


class SharedRegionManager:
    """Local coordinator for shared-memory regions.

    Responsibilities:
      - create named regions with an explicit owner
      - expose descriptors for control-channel exchange
      - attach to existing regions by id when allowed
      - read/write under the current state rules
      - release and cleanup owned regions

    This is a *coordinator*, not an open concurrent shared buffer. Stability
    comes from explicit state and clear ownership.
    """

    def __init__(self, owner: str = "unknown") -> None:
        self._owner = owner
        self._regions: Dict[str, Dict[str, Any]] = {}

    @property
    def owner(self) -> str:
        return self._owner

    def create(
        self,
        label: str,
        layout: RegionLayout,
        *,
        owner: Optional[str] = None,
        created_at_ms: Optional[int] = None,
        buffer_backend: Optional[SharedMemoryBackend] = None,
    ) -> RegionDescriptor:
        owner = owner or self._owner
        rid = region_id_from_label(label)
        if rid in self._regions:
            raise RegionError(f"Region already exists: {rid}")
        size = layout_bytes(layout)
        if size <= 0:
            raise RegionError(f"Invalid layout size for {label!r}")
        meta: Dict[str, Any] = {
            "label": label,
            "owner": owner,
            "layout": dict(layout),
            "size": size,
            "state": RegionState.CREATED,
            "readonly": False,
            "created_at_ms": int(created_at_ms or 0),
            "error": None,
            "buffer": None,
            "attached_by": [],
        }
        if buffer_backend is not None and buffer_backend.available:
            try:
                meta["buffer"] = buffer_backend.create(rid, size, layout)
            except RegionError:
                raise
            except Exception as exc:  # noqa: BLE001
                raise RegionError(f"Backend create failed for {rid!r}: {exc}") from exc
        self._regions[rid] = meta
        return self._descriptor(rid)

    def attach(self, region_id: str, attached_by: str = "client") -> RegionDescriptor:
        meta = self._regions.get(region_id)
        if meta is None:
            raise RegionError(f"Unknown region: {region_id}")
        if meta["state"] in (RegionState.RELEASED, RegionState.ERROR):
            raise RegionError(f"Region not attachable: {region_id}")
        if attached_by not in meta["attached_by"]:
            meta["attached_by"].append(attached_by)
        return self._descriptor(region_id)

    def ensure_registered(self, region_id: str, descriptor: RegionDescriptor) -> RegionDescriptor:
        """Register a remote descriptor locally so this manager can attach.

        This is the bookkeeping bridge for cross-manager attach in the local
        prototype: one manager creates the region, another manager learns it
        via the descriptor from the control channel and registers it here.
        """
        if region_id in self._regions:
            return self._descriptor(region_id)
        meta: Dict[str, Any] = {
            "label": descriptor.label,
            "owner": descriptor.owner,
            "layout": dict(descriptor.layout),
            "size": descriptor.size,
            "state": descriptor.state,
            "readonly": descriptor.readonly,
            "created_at_ms": descriptor.created_at_ms,
            "error": descriptor.error,
            "buffer": None,
            "attached_by": [descriptor.owner],
        }
        self._regions[region_id] = meta
        return self._descriptor(region_id)

    def get_backend(self, region_id: str):
        """Access the backend handle owned by this manager, if any.

        In the local prototype a region is created by one manager and its
        shared-memory handle is stored in that manager's metadata. Other
        managers reach the same region through the actual backend name/backend,
        not through the coordinator's registry.
        """
        meta = self._regions.get(region_id)
        if meta is None:
            raise RegionError(f"Unknown region: {region_id}")
        return meta.get("buffer", None)

    def set_filling(self, region_id: str) -> RegionDescriptor:
        meta = self._require(region_id)
        if meta["state"] not in (RegionState.CREATED,):
            raise RegionError(
                f"Cannot set filling from {meta['state'].value} on {region_id}"
            )
        meta["state"] = RegionState.FILLING
        return self._descriptor(region_id)

    def set_ready(self, region_id: str) -> RegionDescriptor:
        meta = self._require(region_id)
        if meta["state"] not in (RegionState.FILLING,):
            raise RegionError(
                f"Cannot set ready from {meta['state'].value} on {region_id}"
            )
        meta["state"] = RegionState.READY
        return self._descriptor(region_id)

    def set_in_use(self, region_id: str) -> RegionDescriptor:
        meta = self._require(region_id)
        if meta["state"] not in (RegionState.READY, RegionState.IN_USE):
            raise RegionError(
                f"Cannot set in_use from {meta['state'].value} on {region_id}"
            )
        meta["state"] = RegionState.IN_USE
        return self._descriptor(region_id)

    def set_finished(self, region_id: str) -> RegionDescriptor:
        meta = self._require(region_id)
        if meta["state"] not in (RegionState.IN_USE, RegionState.READY):
            raise RegionError(
                f"Cannot set finished from {meta['state'].value} on {region_id}"
            )
        meta["state"] = RegionState.FINISHED
        return self._descriptor(region_id)

    def set_error(self, region_id: str, error: str) -> RegionDescriptor:
        meta = self._require(region_id)
        meta["state"] = RegionState.ERROR
        meta["error"] = str(error)
        return self._descriptor(region_id)

    def release(self, region_id: str, *, detach_attached: bool = True, buffer_backend: Optional[SharedMemoryBackend] = None) -> RegionDescriptor:
        meta = self._require(region_id)
        if meta["owner"] != self._owner:
            raise RegionError(f"Only the owner may release {region_id}")
        if meta["state"] in (RegionState.RELEASED, RegionState.ERROR):
            return self._descriptor(region_id)
        buf = meta.get("buffer")
        if buf is not None and buffer_backend is not None and buffer_backend.available:
            try:
                buffer_backend.release_region(region_id)
            except Exception:  # noqa: BLE001
                pass
            try:
                buffer_backend.unlink(region_id)
            except Exception:  # noqa: BLE001
                pass
            meta["buffer"] = None
        meta["state"] = RegionState.RELEASED
        if detach_attached:
            meta["attached_by"] = []
        return self._descriptor(region_id)

    def cleanup(self, region_id: str) -> RegionDescriptor:
        meta = self._regions.pop(region_id, None)
        if meta is None:
            raise RegionError(f"Cannot cleanup unknown region: {region_id}")
        meta["state"] = RegionState.RELEASED
        meta["error"] = "cleaned_up"
        return self._descriptor(region_id)

    def descriptor(self, region_id: str) -> RegionDescriptor:
        meta = self._regions.get(region_id)
        if meta is None:
            raise RegionError(f"Unknown region: {region_id}")
        return self._descriptor(region_id)

    def list_descriptors(self) -> List[RegionDescriptor]:
        return [self._descriptor(rid) for rid in sorted(self._regions)]

    def _require(self, region_id: str) -> Dict[str, Any]:
        meta = self._regions.get(region_id)
        if meta is None:
            raise RegionError(f"Unknown region: {region_id}")
        return meta

    def _descriptor(self, region_id: str) -> RegionDescriptor:
        meta = self._regions[region_id]
        created = meta.get("created_at_ms")
        return RegionDescriptor(
            id=region_id,
            label=meta["label"],
            owner=meta["owner"],
            size=meta["size"],
            layout=meta["layout"],
            state=RegionState(meta["state"].value),
            readonly=meta.get("readonly", False),
            created_at_ms=created if created is not None else 0,
            error=meta.get("error"),
        )
