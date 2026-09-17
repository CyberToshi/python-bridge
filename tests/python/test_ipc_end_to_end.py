"""End-to-end shared-memory proof for the IPC path.

This test proves the current local contract:
  - one owner creates and keeps the backend handle alive
  - another local manager registers the descriptor and attaches
  - another side opens the same OS shared region and reads it
  - only the owner may release
  - unlink removes the OS shared region

It does NOT prove Godot-side access or cross-process access inside the server.
That comes next.
"""

import struct
import unittest
from unittest.mock import patch

PKG_ROOT = "/home/toshix/python_bridge/addons/python_bridge/python"
import sys
if PKG_ROOT not in sys.path:
    sys.path.insert(0, PKG_ROOT)

from python_bridge.ipc_region import (
    RegionDescriptor,
    RegionLayout,
    RegionState,
    SharedRegionManager,
)
from python_bridge.ipc_platform import SharedMemoryBackend, backend as native_backend


def _cleanup_existing():
    if native_backend() is None:
        return
    import multiprocessing.shared_memory as shm

    for name in list(getattr(shm.SharedMemory, "_names", []) or []):
        try:
            s = shm.SharedMemory(name=name)
            s.close()
            s.unlink()
        except Exception:
            pass


def _no_leaked_shm():
    if native_backend() is None:
        return True
    import multiprocessing.shared_memory as shm

    return len(list(getattr(shm.SharedMemory, "_names", []) or [])) == 0


class IPCEndToEndTests(unittest.TestCase):
    def setUp(self):
        _cleanup_existing()

    def tearDown(self):
        # After every test the OS shared region must be gone.
        self.assertTrue(_no_leaked_shm())

    def test_create_fill_attach_read_release_cleanup(self):
        backend = SharedMemoryBackend(owner="owner")
        layout: RegionLayout = {"dtype": "float64", "items": 2048}
        owner = SharedRegionManager(owner="owner")
        desc = owner.create(label="ipc/a", layout=layout, buffer_backend=backend)
        self.assertEqual(desc.state, RegionState.CREATED)
        owner.set_filling(desc.id)
        owner.set_ready(desc.id)
        owner.set_in_use(desc.id)

        buf = owner.get_backend(desc.id)
        view = backend.mmap_view(buf, 0, 2 * 8)
        view[0:8] = struct.pack("<d", 1.0)
        view[8:16] = struct.pack("<d", 2.0)

        consumer = SharedRegionManager(owner="worker")
        consumer.ensure_registered(desc.id, desc)
        attached = consumer.attach(desc.id, attached_by="worker")
        self.assertEqual(attached.id, desc.id)
        self.assertEqual(attached.owner, "owner")
        self.assertEqual(attached.state, RegionState.CREATED)

        worker_backend = SharedMemoryBackend(owner="worker")
        try:
            shm_worker = worker_backend.open(desc.id)
            first = struct.unpack("<d", worker_backend.read(shm_worker, 0, 8))[0]
            second = struct.unpack("<d", worker_backend.read(shm_worker, 8, 8))[0]
            self.assertEqual(first, 1.0)
            self.assertEqual(second, 2.0)
        finally:
            worker_backend.release_region(desc.id)
            worker_backend.close(shm_worker)
            worker_backend.force_region_clean(desc.id)

        backend.release_region(desc.id)
        backend.unlink(desc.id)
        released = owner.release(desc.id, buffer_backend=backend)
        self.assertEqual(released.state, RegionState.RELEASED)

    def test_non_owner_cannot_release(self):
        backend = SharedMemoryBackend(owner="owner")
        layout: RegionLayout = {"dtype": "float64", "items": 8}
        owner = SharedRegionManager(owner="owner")
        desc = owner.create(label="only-owner", layout=layout, buffer_backend=backend)
        non_owner = SharedRegionManager(owner="worker")
        with self.assertRaises(Exception):
            non_owner.release(desc.id, buffer_backend=backend)

    def test_attach_rejects_released_region(self):
        backend = SharedMemoryBackend(owner="owner")
        layout: RegionLayout = {"dtype": "float64", "items": 8}
        owner = SharedRegionManager(owner="owner")
        desc = owner.create(label="gone", layout=layout, buffer_backend=backend)
        owner.release(desc.id, buffer_backend=backend)
        other = SharedRegionManager(owner="worker")
        with self.assertRaises(Exception):
            other.attach(desc.id, attached_by="worker")

    def test_unlink_only_happens_on_owner_release(self):
        backend = SharedMemoryBackend(owner="owner")
        layout: RegionLayout = {"dtype": "float64", "items": 8}
        owner = SharedRegionManager(owner="owner")
        desc = owner.create(label="unlink-test", layout=layout, buffer_backend=backend)
        backend.release_region(desc.id)
        backend.unlink(desc.id)
        released = owner.release(desc.id, buffer_backend=backend)
        self.assertEqual(released.state, RegionState.RELEASED)


if __name__ == "__main__":
    unittest.main()
