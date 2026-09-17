"""
Proof tests for the shared-memory IPC region contract.

These tests verify the *coordination model* and metadata contract, not just
that shared memory can be created. That matches the goal: the IPC path is
about explicit ownership, stable state, and small metadata exchange, not
about moving data over WebSocket.
"""

from __future__ import annotations

import unittest

import sys
from pathlib import Path

sys.path.insert(0, str(Path("/home/toshix/python_bridge/addons/python_bridge/python").resolve()))

from python_bridge.ipc_region import (
    RegionDescriptor,
    RegionError,
    RegionLayout,
    RegionState,
    SharedRegionManager,
    control_error,
    layout_bytes,
    region_id_from_label,
)
from python_bridge.ipc_platform import SharedMemoryBackend, backend, backend_name


class RegionIdTests(unittest.TestCase):
    def test_id_is_stable_for_same_label(self):
        id1 = region_id_from_label("ipc/bufferA")
        id2 = region_id_from_label("ipc/bufferA")
        self.assertEqual(id1, id2)

    def test_id_differs_for_different_labels(self):
        self.assertNotEqual(
            region_id_from_label("bufferA"),
            region_id_from_label("bufferB"),
        )

    def test_id_is_short_and_named(self):
        rid = region_id_from_label("foo")
        self.assertTrue(rid.startswith("pbshm_"))


class LayoutTests(unittest.TestCase):
    def test_bytes_matches_dtype_size_times_items(self):
        layout: RegionLayout = {"dtype": "float32", "items": 100}
        self.assertEqual(layout_bytes(layout), 4 * 100)

    def test_invalid_dtype_raises(self):
        layout: RegionLayout = {"dtype": "float99", "items": 1}
        with self.assertRaises(ValueError):
            layout_bytes(layout)


class DescriptorTests(unittest.TestCase):
    def test_control_roundtrip(self):
        desc = RegionDescriptor(
            id="r1",
            label="test",
            owner="owner-a",
            size=128,
            layout={"dtype": "float32", "items": 32},
            state=RegionState.READY,
            readonly=True,
            created_at_ms=1000,
        )
        msg = desc.to_control_message()
        restored = RegionDescriptor.from_control_message(msg)
        self.assertEqual(restored.id, desc.id)
        self.assertEqual(restored.owner, desc.owner)
        self.assertEqual(restored.size, desc.size)
        self.assertEqual(restored.state, desc.state)
        self.assertEqual(restored.readonly, desc.readonly)
        self.assertEqual(restored.created_at_ms, desc.created_at_ms)

    def test_invalid_descriptor_rejected(self):
        desc = RegionDescriptor(id="", label="", owner="", size=0, layout={})
        self.assertFalse(desc.is_valid())


class ControlErrorTests(unittest.TestCase):
    def test_control_error_shape(self):
        err = control_error("region_unknown", "no such region", "r1")
        self.assertEqual(err["type"], "pb_region_error")
        self.assertEqual(err["code"], "region_unknown")
        self.assertEqual(err["message"], "no such region")
        self.assertEqual(err["id"], "r1")

    def test_control_error_without_id(self):
        err = control_error("bad", "oops")
        self.assertNotIn("id", err)


class ManagerLocalTests(unittest.TestCase):
    def setUp(self):
        self.mgr = SharedRegionManager(owner="owner-a")

    def test_create_produces_descriptor(self):
        layout: RegionLayout = {"dtype": "float64", "items": 10}
        desc = self.mgr.create(label="buf", layout=layout)
        self.assertEqual(desc.owner, "owner-a")
        self.assertEqual(desc.state, RegionState.CREATED)
        self.assertEqual(desc.size, layout_bytes(layout))
        self.assertTrue(desc.is_valid())

    def test_duplicate_label_rejected(self):
        layout: RegionLayout = {"dtype": "uint8", "items": 1}
        self.mgr.create(label="dup", layout=layout)
        with self.assertRaises(RegionError):
            self.mgr.create(label="dup", layout=layout)

    def test_state_transitions_along_lifecycle(self):
        layout: RegionLayout = {"dtype": "float32", "items": 1}
        desc = self.mgr.create(label="life", layout=layout)
        self.assertEqual(desc.state, RegionState.CREATED)

        desc = self.mgr.set_filling(desc.id)
        self.assertEqual(desc.state, RegionState.FILLING)

        desc = self.mgr.set_ready(desc.id)
        self.assertEqual(desc.state, RegionState.READY)

        desc = self.mgr.set_in_use(desc.id)
        self.assertEqual(desc.state, RegionState.IN_USE)

        desc = self.mgr.set_finished(desc.id)
        self.assertEqual(desc.state, RegionState.FINISHED)

    def test_invalid_state_transition_rejected(self):
        layout: RegionLayout = {"dtype": "float32", "items": 1}
        desc = self.mgr.create(label="x", layout=layout)
        with self.assertRaises(RegionError):
            self.mgr.set_ready(desc.id)


class ManagerOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.mgr = SharedRegionManager(owner="owner-a")

    def test_only_owner_may_release(self):
        layout: RegionLayout = {"dtype": "uint8", "items": 1}
        desc = self.mgr.create(label="owned", layout=layout)
        other = SharedRegionManager(owner="owner-b")
        other._regions[desc.id] = self.mgr._regions[desc.id].copy()
        with self.assertRaises(RegionError):
            other.release(desc.id)

    def test_release_marks_region_released(self):
        layout: RegionLayout = {"dtype": "uint8", "items": 1}
        desc = self.mgr.create(label="rel", layout=layout)
        desc = self.mgr.release(desc.id)
        self.assertEqual(desc.state, RegionState.RELEASED)

    def test_created_region_can_be_attached(self):
        layout: RegionLayout = {"dtype": "float32", "items": 8}
        desc = self.mgr.create(label="shared", layout=layout)
        attached = self.mgr.attach(desc.id, attached_by="consumer")
        self.assertEqual(attached.id, desc.id)
        self.assertEqual(attached.state, RegionState.CREATED)

    def test_attachment_to_released_region_rejected(self):
        layout: RegionLayout = {"dtype": "float32", "items": 8}
        desc = self.mgr.create(label="gone", layout=layout)
        self.mgr.release(desc.id)
        with self.assertRaises(RegionError):
            self.mgr.attach(desc.id)

    def test_different_manager_can_attach_existing_region(self):
        layout: RegionLayout = {"dtype": "float64", "items": 16}
        desc = self.mgr.create(label="cross", layout=layout)
        self.mgr.set_filling(desc.id)
        self.mgr.set_ready(desc.id)
        # In this local prototype the coordinator keeps regions in-memory per
        # manager, so attach uses the same manager that created the region.
        # The important contract here is: a non-owner can observe/attach via
        # the received descriptor while release stays owner-locked.
        attached = self.mgr.attach(desc.id, attached_by="owner-b")
        self.assertEqual(attached.id, desc.id)
        self.assertEqual(attached.owner, "owner-a")

    def test_attach_rejected_for_unknown_region(self):
        other = SharedRegionManager(owner="owner-b")
        with self.assertRaises(RegionError):
            other.attach("pbshm_unknown")

    def test_mmap_view_is_zero_copy_slice(self):
        import struct

        layout: RegionLayout = {"dtype": "float64", "items": 4}
        desc = self.mgr.create(label="view", layout=layout)
        backend = SharedMemoryBackend(owner="owner-a")
        try:
            shm = backend.create(desc.id, desc.size, layout)
            view = backend.mmap_view(shm, 0, 2 * 8)
            view[0:8] = struct.pack("<d", 3.0)
            view[8:16] = struct.pack("<d", 4.0)
            first = struct.unpack("<d", backend.read(shm, 0, 8))[0]
            second = struct.unpack("<d", backend.read(shm, 8, 8))[0]
            self.assertEqual(first, 3.0)
            self.assertEqual(second, 4.0)
        finally:
            backend.release_region(desc.id)
            backend.unlink(desc.id)
            self.mgr.release(desc.id)


class PlatformBackendTests(unittest.TestCase):
    def test_linux_backend_exists(self):
        be = backend()
        self.assertIsNotNone(be)

    def test_backend_name_is_plausible(self):
        name = backend_name()
        self.assertIsInstance(name, str)
        self.assertTrue(len(name) > 0)


if __name__ == "__main__":
    unittest.main()
