"""Primary Python package for the Python Bridge add-on.

This is the runtime package used by the Godot add-on. It exposes the same shared-
memory contract and control-message support as the legacy standalone tree, but this
tree is the source of truth for Godot integration.

Legacy standalone tree:
  python_bridge/bridge/python_bridge/  (standalone/legacy runtime entry points)
"""

import sys as _sys
from pathlib import Path as _Path

_PKG_DIR = _Path(__file__).resolve().parent

_SUBS = {
    "data_registry": None,
    "executor": None,
    "introspection": None,
    "ipc_platform": None,
    "ipc_region": None,
    "protocol": None,
    "serializer": None,
    "server": None,
}


def _load_module(name: str):
    fullname = "python_bridge." + name
    existing = _sys.modules.get(fullname)
    if existing is not None:
        return existing
    path = _PKG_DIR / (name + ".py")
    import importlib.util as _iu

    spec = _iu.spec_from_file_location(fullname, str(path))
    mod = _iu.module_from_spec(spec)
    spec.loader.exec_module(mod)
    _sys.modules[fullname] = mod
    return mod


ipc_region = _load_module("ipc_region")
ipc_platform = _load_module("ipc_platform")

RegionDescriptor = ipc_region.RegionDescriptor
RegionError = ipc_region.RegionError
RegionLayout = ipc_region.RegionLayout
RegionState = ipc_region.RegionState
SharedRegionManager = ipc_region.SharedRegionManager
control_error = ipc_region.control_error
region_id_from_label = ipc_region.region_id_from_label
layout_bytes = ipc_region.layout_bytes

SharedMemoryBackend = ipc_platform.SharedMemoryBackend
backend_name = ipc_platform.backend_name
backend = ipc_platform.backend

protocol = _load_module("protocol")
data_registry = _load_module("data_registry")
executor = _load_module("executor")
introspection = _load_module("introspection")
serializer = _load_module("serializer")
server = _load_module("server")

VERSION = "0.2.0"

__all__ = [
    "data_registry",
    "executor",
    "introspection",
    "ipc_platform",
    "ipc_region",
    "protocol",
    "serializer",
    "server",
    "RegionDescriptor",
    "RegionError",
    "RegionLayout",
    "RegionState",
    "SharedRegionManager",
    "control_error",
    "region_id_from_label",
    "layout_bytes",
    "SharedMemoryBackend",
    "backend_name",
    "backend",
    "VERSION",
    "read_region",
    "write_region",
]


class _LazyPackage(type(_sys)):
    """Behaves like a real package module but lazy-loads submodules on first
    attribute access, and exposes IPC convenience re-exports eagerly."""

    __file__ = str(_PKG_DIR / "__init__.py")
    __package__ = "python_bridge"
    __path__ = [_PKG_DIR]

    def __init__(self, name: str, docstring: str):
        super().__init__(name, docstring)
        self.__dict__.update({
            "VERSION": VERSION,
            "RegionDescriptor": RegionDescriptor,
            "RegionError": RegionError,
            "RegionLayout": RegionLayout,
            "RegionState": RegionState,
            "SharedRegionManager": SharedRegionManager,
            "control_error": control_error,
            "region_id_from_label": region_id_from_label,
            "layout_bytes": layout_bytes,
            "SharedMemoryBackend": SharedMemoryBackend,
            "backend_name": backend_name,
            "backend": backend,
            "ipc_region": ipc_region,
            "ipc_platform": ipc_platform,
            "protocol": protocol,
            "serializer": serializer,
            "executor": executor,
            "introspection": introspection,
            "server": server,
            "data_registry": data_registry,
            "__all__": __all__,
            "read_region": read_region,
            "write_region": write_region,
        })

    def __getattr__(self, name: str):
        if name in _SUBS:
            mod = _SUBS[name]
            if mod is None:
                mod = _load_module(name)
                _SUBS[name] = mod
            return mod
        if name in {"read_region", "write_region"}:
            return globals()[name]
        raise AttributeError(f"module {self.__name__!r} has no attribute {name!r}")

    def __dir__(self):
        return list(globals().keys()) + list(__all__)


def read_region(descriptor: RegionDescriptor, offset: int = 0, size: int = None):
    """Read raw bytes from an existing shared region by descriptor.

    This is a convenience around the current IPC backend and requires that the
    region already exists in the OS shared-memory backend. It does not create,
    attach, or release the region; it only reads from the existing shared buffer.
    """
    return backend().read(SharedMemoryBackend().open(descriptor.id), offset, size or descriptor.size)


def write_region(descriptor: RegionDescriptor, offset: int, raw: bytes):
    """Write raw bytes into an existing shared region by descriptor.

    This is a convenience around the current IPC backend and requires that the
    region already exists in the OS shared-memory backend. It does not create,
    attach, or release the region; it only writes to the existing shared buffer.
    """
    return backend().write(SharedMemoryBackend().open(descriptor.id), offset, raw)


_lazy = _LazyPackage(__name__, __doc__)
_lazy.__all__ = __all__
_sys.modules[__name__] = _lazy
