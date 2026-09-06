---
sidebar_position: 8
title: Communication Paths
description: Exactly two ways between Godot and Python – WebSocket for control, Shared Memory/IPC for large data. Honest status, no invented paths.
---

# Communication Paths

There are exactly **two ways** between Godot and Python. Everything else
(GDScript2All, cluster) is either a tool or an outlook – not a third
transport path.

```text
Path 1 (verified)               Path 2 (concept, local)
GDScript ──WebSocket──> Python         GDScript ─[C++ shim]─ Shared Memory ─> Python
   control + small data                   large numerical data
   works across a network too             same machine only
```

| Path | Status |
|---|---|
| 1: WebSocket | **Implemented and verified end-to-end** (hello world, task, batch, error paths, DataRef lifecycle green) |
| 2: Shared Memory / IPC | **Concept + Python foundation**: a shared-memory registry exists and is tested in Python; the small C++ shim on the Godot side is still missing |

---

## 1. Why exactly two paths?

Data between two processes must cross a process boundary – via the kernel
(socket) or via a shared mapping (shared memory). That yields two
fundamentally different strengths:

- **WebSocket/JSON**: simple, isolated, works over a network. Costs per
  message: serialization + TCP round-trip. Ideal for control, tasks, and
  small structured data.
- **Shared memory**: the same physical RAM pages mapped into both address
  spaces – no copying on access. Ideal for large binary fields that are
  read repeatedly. Local only, needs synchronization.

**Important:** GDScript itself cannot call `mmap` and has no raw pointers –
there is no syscall API in the language. The shared-memory path therefore
needs a **small, hand-written GDExtension shim** on the Godot side (map
the region, check the header, fill a `PackedFloat32Array` once). That is
a narrow helper piece, **not** a language or path concept.

### Analogy: letters versus a bulletin board

```text
Path 1 = mail                      Path 2 = shared board
Godot ─(JSON, TCP)─► Python        ┌────────────────────────────┐
                                    │ header: id, dtype, nbytes │
                                    │ bytes: 0.0 0.5 1.0 …      │
                                    └────────────────────────────┘
                                    C++/Python see THE SAME
                                    pages → no data copy
```

The catch with the board: **no letter means no notification.** The writer
must report "ready" / "release" via WebSocket. That is why the two paths
complement each other: WebSocket stays the control channel, the board
carries the large data.

### Honest orders of magnitude (estimates, not measurements)

| | Path 1 (WebSocket) | Path 2 (shared memory) |
|---|---|---|
| Small call | ~0.2–2 ms | ~0.05–0.5 ms (handle + header check) |
| Large data | poor: bytes through JSON + TCP | very good: RAM mapping, no copy between C++ and Python |
| Dominant cost | serialization + allocation | synchronization + lifecycle |
| Over a network (cluster) | yes | no |

---

## 2. Path 1: WebSocket (verified)

### Data flow

```text
Godot main thread                    Python process
  await call/execute                  handler reads frame
   → TaskManager (queue)              → worker thread runs code
   → polled each frame                → serializer → response
   → send_text (TCP 127.0.0.1)  ────►│
   ◄─────────────────────────────────┘ drain(byte budget per frame)
   → task.done → PythonBridgeResult   (main thread protected)
```

- Python's compute stays fully usable; the overhead sits *around* the
  call (TCP + JSON both sides), not inside the computation.
- In return: clean process isolation, easy to debug, remote-capable.
- **When wrong:** when millions of numbers per second should flow and the
  result is only consumed as one large binary field – then see Path 2
  (or today already: DataRef handles with file transport).

### Setup in the editor (click by click)

1. **Project → Project Settings → Plugins**: enable Python Bridge.
2. Check the autoload `PythonBridge` (Project Settings → Autoload).
3. Top right: open the **Python Bridge** dock → **New script** → id `hello`.
4. In `res://python_bridge/scripts/hello.py`: add `say_hello(message)`.
5. Open `res://example/hello/hello_world.tscn` and press **F6**.
6. Console: `[hello] Python antwortet: Hello Godot! Python received: Hello Python`.
   First start creates the venv and installs `websockets` (1–3 min).

> Flatpak editor: the bridge detects the sandbox and starts Python on the
> host (`flatpak-spawn --host`). If the permission is missing, see
> [Troubleshooting](./fehlerbehebung).

### Code (complete, provably runs)

`res://example/hello/hello_bridge.gd` (short version):

```gdscript
extends Node
const PYTHON_SCRIPT := "hello"
const PYTHON_INSTANCE := "default"

func _ready() -> void:
    var started: PythonBridgeResult = await PythonBridge.start_instance(PYTHON_INSTANCE)
    if started.is_error():
        push_error("Start failed: " + started.error_message())
        return
    var result: PythonBridgeResult = await PythonBridge.call_script(
        PYTHON_SCRIPT, "say_hello", ["Hello Python"], {}, PYTHON_INSTANCE, 30.0)
    if result.is_ok():
        print("[Godot] Python says: ", result.value)
```

`res://python_bridge/scripts/hello.py`:

```python
def say_hello(message: str) -> str:
    """Ordinary Python function — no bridge-specific code needed."""
    return f"Hello Godot! Python received: {message}"
```

Line by line: `start_instance` launches Python and waits for READY;
`call_script` builds a task (function + arguments); `await` waits for
`task.done`; `result.value` is the answer.

---

## 3. Path 2: Shared Memory / IPC (concept)

### How it works at the OS level

1. One process calls `mmap` (or `shm_open` + `mmap`); the MMU maps the
   **same physical RAM pages** into both address spaces.
2. A **metadata header** at the start of the region describes the
   content: `magic, id, dtype, nbytes, state (created/filled/ready/
   free), checksum, owner`.
3. Reading/writing is a normal memory access; **synchronization is the
   real problem** (who writes when, who reads when).
4. Cleanup: the owner frees; orphaned regions are cleaned on server
   start (pattern already exists for the DataRef files).

```text
Godot/C++ shim                    physical RAM                Python
┌──────────────┐   mmap   ┌──────────────────┐   mmap   ┌──────────────┐
│ ptr → header │─────────►│ same pages       │◄─────────│ header ← ptr │
└──────────────┘          └──────────────────┘          └──────────────┘
```

### The uncomfortable truth about "zero copy"

Zero copy is achievable **between C++ and Python**. Not into a GDScript
variable: `PackedFloat32Array` is an engine-managed buffer — the shim
fills it **once** from the mapping. That single copy is unavoidable and
is the price the GDScript API costs.

### Project status and next step

- Python side: shared-memory registry (`ipc_region`) tested.
- Godot side: **still open** – the narrow GDExtension shim (concept
  sketch below). Until then, **DataRef handles with file transport**
  take over large-data duty (verified, 36/36 checks).

Concept sketch of the shim (not finished project code):

```cpp
// Map the region + check the header + copy once into a Godot buffer.
void* region = mmap(0, header.nbytes, PROT_READ, MAP_SHARED, fd, 0);
if (region->magic != PB_MAGIC || region->dtype != DT_F32) return ERR_INVALID_DATA;
PackedFloat32Array out;
out.resize(region->items);
memcpy(out.ptrw(), region->payload, region->nbytes);
```

---

## 4. What is deliberately NOT a path

- **GDScript2All / C++ translation:** not a communication path. It can
  accelerate Godot-side *compute* (the HP dock exists in the editor,
  experimental). It changes nothing about transport – WebSocket stays
  equally fast, and "translating" is not data transfer. Thinking of the
  two separately prevents the fallacy "I translate, therefore my
  transport is fast".
- **Cluster / Docker:** conceptually prepared
  (`docs/CLUSTER_INTEGRATION_PLAN.md`), deliberately not implemented yet.
  For a cluster shared memory is useless anyway (no shared RAM across
  machines) – there Path 1 over the network counts.

---

## 5. Core statements

1. WebSocket + JSON is right and verified for control and small data.
2. Shared memory removes the data copy between C++ and Python – for
   large local fields; the final copy into a GDScript array stays
   unavoidable.
3. GDScript2All speeds up compute, never transport – therefore it is not
   a third path.
4. Choose transport by data + size: control → WebSocket, large local
   data → shared memory (until then: DataRef/file), cluster → WebSocket.
