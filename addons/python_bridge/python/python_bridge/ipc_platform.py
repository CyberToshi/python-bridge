"""Platform bindings for the shared-memory IPC path.

The coordinator in ipc_region.py handles metadata, ownership and state.
This module is the place where actual shared-memory allocation, mapping,
read/write, and cleanup are implemented.

Local contract:
  - one backend instance per side
  - one owner creates the shared region and keeps its handle alive
  - other sides open the same OS shared region by name
  - read/write/mmap_view operate directly on the shared buffer
  - release is owner-only; unlink is done by the owner at release time
  - a local alive set keeps the owner handle from being collected while views
    or readers may still exist
"""

from __future__ import annotations

import platform
from typing import Any, Dict, Optional



def backend_name() -> str:
    """Name of the best available local backend for this platform/runtime."""
    system = platform.system()
    if system == "Linux" and _has_multiprocessing_shm():
        return "multiprocessing_shared_memory"
    return "not_available"


def backend() -> Optional[Any]:
    """Best available backend object or None."""
    system = platform.system()
    if system == "Linux" and _has_multiprocessing_shm():
        import multiprocessing.shared_memory as _shm

        return _shm
    return None


def _has_multiprocessing_shm() -> bool:
    try:
        import multiprocessing.shared_memory as _shm  # noqa: F401
    except Exception:  # pragma: no cover
        return False
    return True


class SharedMemoryBackend:
    """Thin wrapper around the current local backend.

    This backend is the local transport underneath the coordinator.
    """

    def __init__(self, owner: str = "unknown") -> None:
        self._owner = owner
        self._native = backend()
        self._opened: Dict[str, Any] = {}
        self._keepalive: set = set()
        # Keep exported memoryviews associated with their owner handle so a
        # backend shutdown can release them before closing SharedMemory.
        self._views: Dict[int, list] = {}

    def _drop_keepalive(self, handle: Any) -> None:
        self._keepalive.discard(handle)

    def _release_views(self, handle: Any) -> None:
        views = self._views.pop(id(handle), [])
        for view in views:
            try:
                view.release()
            except Exception:  # pragma: no cover - best effort during cleanup
                pass

    @property
    def available(self) -> bool:
        return self._native is not None

    @property
    def name(self) -> str:
        return backend_name()

    def create(self, region_id: str, size_bytes: int, layout: Dict[str, Any]) -> Any:
        """Create a new shared region or re-create an orphaned one.

        Any previously opened handle for this region id on this backend is
        closed and unlinked first, and any existing OS shared region with the
        same name is also cleaned up so the new region starts from a clean
        namespace.
        """
        if not self.available:
            raise RuntimeError("No shared-memory backend available on this platform")
        import multiprocessing.shared_memory as shm

        old = self._opened.get(region_id, None)
        if old is not None:
            self._drop_keepalive(old)
            try:
                old.unlink()
            except Exception:  # noqa: S110
                pass
            self.close(old)
            del self._opened[region_id]

        try:
            existing = shm.SharedMemory(name=region_id)
            existing.close()
            existing.unlink()
        except Exception:  # noqa: S110
            pass

        handle = shm.SharedMemory(create=True, size=size_bytes, name=region_id)
        self._opened[region_id] = handle
        self._keepalive.add(handle)
        return handle

    def open(self, region_id: str, reopen: bool = False) -> Any:
        """Open an existing OS shared region by name.

        If this backend already holds an opened handle for this region id and
        reopen is False, return it. Otherwise close and replace the local
        handle so only one opened handle is tracked per region id on this
        backend.

        This method does not create or unlink the OS shared region. Creation
        and owner-side cleanup are handled by :meth:`create` and
        :meth:`release_region`.
        """
        if not self.available:
            raise RuntimeError("No shared-memory backend available on this platform")
        import multiprocessing.shared_memory as shm

        existing = self._opened.get(region_id, None)
        if existing is not None and not reopen:
            return existing

        if region_id in self._opened:
            old = self._opened[region_id]
            self._drop_keepalive(old)
            self.close(old)
            del self._opened[region_id]

        handle = shm.SharedMemory(name=region_id)
        self._opened[region_id] = handle
        self._keepalive.add(handle)
        return handle

    def close(self, handle: Any) -> None:
        """Close one local handle without unlinking the OS shared region.

        Any views created through :meth:`mmap_view` are released first. This
        makes backend shutdown deterministic instead of leaving Python's
        SharedMemory finalizer with exported pointers still alive.
        """
        if handle is None:
            return
        self._release_views(handle)
        self._drop_keepalive(handle)
        try:
            handle.close()
        except Exception:  # pragma: no cover
            pass

    def release_region(self, region_id: str) -> None:
        """Release the local opened handle for a region.

        If this backend opened the region, close and unlink it. If it only
        attached by name, close the local handle and remove it from tracking.
        """
        handle = self._opened.pop(region_id, None)
        if handle is not None:
            self._drop_keepalive(handle)
            try:
                handle.unlink()
            except Exception:  # noqa: S110
                pass
            self.close(handle)

    def unlink(self, region_id: str) -> None:
        """Unlink the OS shared region from this side."""
        if not self.available:
            return
        import multiprocessing.shared_memory as shm

        try:
            shm.SharedMemory(name=region_id)
        except Exception:  # noqa: S110
            return
        try:
            shm.SharedMemory.unlink(region_id)
        except TypeError:
            handle = shm.SharedMemory(name=region_id)
            try:
                handle.unlink()
            finally:
                try:
                    handle.close()
                except Exception:  # noqa: S110
                    pass
        except Exception:  # pragma: no cover
            pass

    def force_region_clean(self, region_id: str) -> None:
        """Best-effort cleanup for an existing OS shared region by name.

        This is used by tests and control paths that may encounter leftover
        shared-memory names from prior runs or prior backend instances.
        """
        if not self.available:
            return
        import multiprocessing.shared_memory as shm

        try:
            existing = shm.SharedMemory(name=region_id)
            existing.close()
            existing.unlink()
        except Exception:  # noqa: S110
            pass

    def write(self, handle: Any, offset: int, raw: bytes) -> int:
        """Write raw bytes into the shared buffer at offset."""
        buf = handle.buf
        buf[offset : offset + len(raw)] = raw
        return len(raw)

    def read(self, handle: Any, offset: int, size: int) -> bytes:
        """Read raw bytes from the shared buffer at offset."""
        buf = handle.buf
        return bytes(buf[offset : offset + size])

    def mmap_view(self, handle: Any, offset: int = 0, size: Optional[int] = None) -> Any:
        """Return a memoryview over a slice of the shared buffer.

        This is useful for zero-copy numeric access on the owner side.
        """
        buf = handle.buf
        if size is None:
            size = len(buf) - offset
        view = memoryview(buf)[offset : offset + size]
        self._views.setdefault(id(handle), []).append(view)
        return view
