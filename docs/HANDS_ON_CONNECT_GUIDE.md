# HANDS-ON: Connecting Your GDScript to Python (Copy-Paste Guide)

This guide shows the **exact manual steps**: which node gets which script,
the complete working code for **both sides**, and how data flows between them.

After this guide you will have:

- A GDScript node that opens the bridge, sends `"Hello Python"` and receives
  `"Hello Godot"` — printed in the Godot console.
- A normal Python file that answers the call.

**Important fact up front:** You do **not** start Python yourself in a
terminal. The GDScript call `PythonBridge.start_instance()` launches the
Python process (venv + server) automatically and connects to it via
WebSocket. Your `.py` file is just a file — it never runs standalone.

---

## 0. One-time project setup (if not done yet)

1. Copy `addons/python_bridge/` into your project folder.
2. Open your project in Godot.
3. **Project → Project Settings → Plugins** → enable *Python Bridge*.
   This registers the autoload `PythonBridge` (the singleton your scripts
   call) and the editor dock.
4. Verify: **Project → Project Settings → Autoload** shows
   `PythonBridge → res://addons/python_bridge/core/python_bridge.gd`.

---

## 1. Create the Python side (the counterpart)

In the Godot editor:

1. Open the **Python Bridge** dock (top-right dock area).
2. Click **New script** → name it `hello` (this creates
   `res://python_bridge/scripts/hello.py` — a normal `.py` file).
3. Paste this code and click **Save**:

```python
"""Minimal counterpart for the Godot bridge demo.

Conventions:
  call_script:  Godot calls a function; the return value goes back to Godot.
  execute_script: `input` holds the data sent from Godot, `result` holds
                  what Godot receives back.
"""


def say_hello(message: str) -> str:
    """Answers a hello from Godot."""
    return "Hello Godot (from Python, received: %s)" % message


def echo(input_data) -> dict:
    """Returns whatever Godot sent, plus a marker."""
    return {"python_says": "Hello Godot", "received": input_data}


# Only used by execute_script: Godot sets `input`, we set `result`.
result = None
if input:
    result = echo(input)
```

That is the whole Python side. No server code, no sockets, no asyncio —
the bridge injects all of that. The file stays a normal `.py` you can
import and test outside Godot.

---

## 2. Create the GDScript side (the interface)

Create a script `res://scripts/hello_bridge.gd` with this **complete,
working code**:

```gdscript
extends Node
## Complete interface between Godot and Python via the Python Bridge.
## Attach this to any Node in your scene. It starts the Python process,
## sends "Hello Python", receives the answer and prints it.

const SCRIPT_ID := "hello"          # -> res://python_bridge/scripts/hello.py
const INSTANCE_NAME := "default"    # instance managed by the bridge

var _ready_to_call := false

func _ready() -> void:
    # --- 1) Start Python (venv, server, WebSocket) and wait until READY.
    #        You do NOT start Python yourself - this call does everything.
    var start: PythonBridgeResult = await PythonBridge.start_instance(INSTANCE_NAME)
    if start.is_error():
        push_error("Python-Start fehlgeschlagen: " + start.error_message())
        return

    # --- 2) Minimal example: send "Hello Python", receive "Hello Godot".
    await _send_hello()

    # --- 3) Register the periodic call in the game loop.
    _ready_to_call = true


func _send_hello() -> void:
    # SEND: the first arguments go TO Python.
    # RECEIVE: `await` returns a PythonBridgeResult with .value / .error.
    var r: PythonBridgeResult = await PythonBridge.call_script(
        SCRIPT_ID,          # which .py file
        "say_hello",        # which function in that file
        ["Hello Python"],   # positional args  -> def say_hello(message)
        {})                 # keyword args     -> e.g. {"extra": 42}
    if r.is_ok():
        # r.value holds whatever the Python function returned.
        print("[GDScript] Python antwortet: ", r.value)
    else:
        print("[GDScript] Fehler: ", r.error_code(), " - ", r.error_message())


func _process(delta: float) -> void:
    # Called every frame by the engine. Python results NEVER block this
    # loop: calls are awaited (async), and the bridge dispatches answers
    # into the main thread in controlled batches per frame.
    if not _ready_to_call:
        return
    _frame_count += 1
    if _frame_count % 60 == 0:      # once per second at 60 FPS
        _tick_python()


var _frame_count := 0


func _tick_python() -> void:
    # Periodic call: shows the game loop <-> Python round trip.
    var payload := {"frame": _frame_count, "time": Time.get_ticks_msec() / 1000.0}
    var r: PythonBridgeResult = await PythonBridge.call_script(
        SCRIPT_ID, "echo", [], {"input_data": payload})
    if r.is_ok():
        var answer: Dictionary = r.value
        print("[GDScript] frame ", _frame_count,
              " -> Python: ", answer.get("python_says", "?"),
              " | gesendet: ", answer.get("received", {}))


func _exit_tree() -> void:
    # Clean shutdown when the scene closes (kills the Python process).
    PythonBridge.shutdown()
```

---

## 3. Which node gets the script? (click-by-click)

1. Open (or create) your scene, e.g. `main.tscn`.
2. Select **any Node** in the scene tree. For a hello test the root
   `Node` is fine:
   - 2D game → `Node2D` works the same way
   - UI → `Control` works the same way

   The bridge is **not** tied to a node type. It is an **autoload
   singleton** (`PythonBridge`) that lives outside your scene — the node
   below is only the *caller*.
3. In the inspector click **Attach Script** (scroll icon) →
   **Load** `res://scripts/hello_bridge.gd`.
4. Press **F5** (run project) or **F6** (run this scene).

Optional alternative: make it an **Autoload** instead
(Project Settings → Autoload → add `hello_bridge.gd`) if you want the
connection in every scene without attaching anything.

---

## 4. What happens when you press F5

```
Step 1  _ready()
        └─ PythonBridge.start_instance("default")
             ├─ finds/creates venv (res://python_bridge/venv)
             ├─ starts the Python server as a subprocess   <-- Python starts HERE
             ├─ connects via WebSocket (localhost)
             └─ handshake  ->  READY

Step 2  _send_hello()
        ├─ sends  {func: "say_hello", args: ["Hello Python"]}
        └─ awaits result
             └─ print: [GDScript] Python antwortet: Hello Godot (from Python,
                       received: Hello Python)

Step 3  _process(delta)  (every frame, non-blocking)
        └─ once per second: echo round trip with a Dictionary payload
             └─ print: [GDScript] frame 120 -> Python: Hello Godot | gesendet: {...}

Step 4  scene closes / Godot quits
        └─ PythonBridge.shutdown()  -> WebSocket closed, process terminated,
           no zombie processes left
```

Expected console output:

```
[GDScript] Python antwortet: Hello Godot (from Python, received: Hello Python)
[GDScript] frame 60 -> Python: Hello Godot | gesendet: { "frame": 60, ... }
[GDScript] frame 120 -> Python: Hello Godot | gesendet: { "frame": 120, ... }
...
```

---

## 5. How data flows (send / receive in GDScript)

| Direction | GDScript | Python |
|---|---|---|
| **Send** | `call_script(id, fn, args, kwargs)` — `args` is an `Array`, `kwargs` a `Dictionary` | `def fn(*args, **kwargs)` receives them converted |
| **Receive** | `var r := await PythonBridge.call_script(...)` → `r.value` | `return <value>` in the Python function |
| **Run whole file** | `execute_script(id, input)` → `r.value` | module-level `result = ...` built from `input` |
| **Types** | `int/float/String/bool/Array/Dictionary/PackedByteArray` | `int/float/str/bool/list/dict/bytes` |

Rules of thumb:

- Everything you pass must be JSON-serializable (or `PackedByteArray`,
  which travels as a binary frame).
- The call is **async**: use `await`. Your `_process` keeps running;
  Python never blocks a frame.
- Errors come back structured, never as a crash:

```gdscript
if r.is_error():
    print(r.error_code())                 # e.g. "PYTHON_EXCEPTION"
    print(r.error.get("type"))            # e.g. "ValueError"
    print(r.error.get("message"))         # the exception message
    print(r.error.get("traceback"))       # the Python traceback
```

---

## 6. Troubleshooting the first run

| Symptom | Cause / Fix |
|---|---|
| `Start fehlgeschlagen: python not found` | Install Python 3.8+, or set it explicitly once: `PythonBridge.configure({"python_executable": "/usr/bin/python3"})` (Windows: `"C:/Python312/python.exe"`). |
| `status = "not_ready"` | You called before `await start_instance(...)` finished. Always await it first. |
| First start takes ~a minute | The venv is being created + `websockets` installed. This happens only once; log is in `res://python_bridge/tmp/pip.log`. |
| `Script not found: hello` | The `.py` file is not in `res://python_bridge/scripts/`. Check the name (id = filename without `.py`). |
| Flatpak Godot cannot start Python | Sandbox restriction of the Flatpak build; use a native Godot build for the runtime. |

---

## 7. Where to go from here

- **Batching / Task-API / multi-instance / crash restart:** open and run
  `example/demo_scene.tscn` (F6) — each button is a commented demo.
- **API reference:** `docs/API.md`
- **Full documentation:** `docs/PythonBridge_Dokumentation.pdf`
- **Step-by-step deep dive:** `docs/PRAXIS.md`
