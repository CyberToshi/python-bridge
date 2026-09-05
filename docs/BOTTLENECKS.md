# Bottlenecks

This chapter lists the concrete performance, latency, throughput, and reliability bottlenecks of the Python Bridge. It is the companion to the troubleshooting chapter: where troubleshooting explains what to do when something goes wrong, this chapter explains what limits the bridge under normal operation and where the costs come from.

This document lists the concrete performance, latency, throughput, and reliability bottlenecks of the Python Bridge. It is written against the actual implementation (core GDScript modules, Python server/executor, serializer, config defaults) so the numbers and file locations are real.

It is intended to be used in two ways: as an honest chapter in the documentation, and as a checklist for any performance or reliability work.

## Reading this document

Each entry has the **mechanism** (what happens), the **default bounds** (config values where relevant), and the **code location** (file:line). Entries are grouped so a reader can find the hot path that affects the workload they care about.

Severity here is about *impact in real use*, not how hard an entry is to fix. The top entries are the ones that become visible first when the bridge is actually used.

---

## A. Structural bottlenecks (hit almost every workload)

### A1. One Python instance executes strictly serially — one task at a time, end to end.

**Mechanism.** The Python side runs a single `ThreadPoolExecutor(max_workers=1)` behind one `asyncio.Queue` (`server.py`). Only one task or batch job executes at a time per instance. On the Godot side, `max_inflight_per_instance = 1` (`config.gd`) means at most one dispatched unit may be outstanding per instance; the scheduler does not send the next unit until the previous result is processed and the in-flight unit is pruned (`scheduler.gd` `_record_unit`, `_prune_units`).

**Impact.** Throughput per instance is bounded by the execution time of a single task. There is no pipelining inside an instance. To get more parallelism you need multiple processes, each carrying a full interpreter, a WebSocket server, and its own workspace cost.

**Relevant files:** `server.py` (executor pool + queue), `executor.py` (single worker thread), `config.gd` (`max_inflight_per_instance`), `scheduler.gd` (`_in_flight_count`, `_prune_units`), `task_manager.gd`.

### A2. A single runaway task wedges the instance permanently — the worst availability bottleneck.

**Mechanism.** A task timeout is enforced with `asyncio.wait_for` on the *result*, not on the user code. When the timeout fires, the response is discarded but the user code keeps running in the one worker thread (`server.py` `_run_job`). Because there is exactly one worker thread for the instance, every later task queues behind the stuck one forever.

Cancel cannot help here: `executor.py` only reads the cancelled-set at job *start* ("a running task cannot be interrupted safely"). The instance is only recoverable by killing the process, and the process leak takes time to detect (up to ~15 s via health, then restart).

**Impact.** One infinite loop, one blocked C extension holding the GIL, or one unresponsive call freezes the entire instance until restart. All queued and auto-routed tasks for that instance fail as `TIMEOUT` (see A8) or wait indefinitely behind the wedge.

**Relevant files:** `server.py` (`_run_job`, `asyncio.wait_for`), `executor.py` (`consume_cancelled`, job start only), `health_monitor.gd`, `config.gd` (`health_check_interval_ms`, `health_missed_pong_limit`).

### A3. The whole script source is re-read, re-sent, and re-hashed on every single call.

**Mechanism.**
- Godot side: `call_script`, `execute_script`, and `define_script` all call `get_script_source()`, which does a full `FileAccess.open` + `FileAccess.get_as_text()` on every call (`python_bridge.gd`).
- The entire script source travels inside the task message (`task_manager.gd` `_build_task_msg`), is `JSON.stringify`'d, sent over the WebSocket, and parsed again on the Python side.
- Python side: `executor.py` `call()` compares `ctx.source_hash != _hash(source)` by sha256-hashing the **whole source on every call**, even when nothing changed.

**Impact.** A 1 MB script called at 60 Hz is ~60 MB/s of JSON per call direction, 60 full sha256 hashes per second, plus per-call disk I/O on the Godot side — all for zero redefinition when the file is unchanged. This is hidden per-call tax that grows with script size and call frequency.

**Relevant files:** `python_bridge.gd` (`get_script_source`, `resolve_script_path`), `task_manager.gd` (`_build_task_msg`), `executor.py` (hash + `define`/`call`).

### A4. `run` / `execute` recompiles the Python source on every execution.

**Mechanism.** `executor.py` `run()` calls `compile(source, ...)` unconditionally. There is no compiled-code cache. Only the `call` path caches via the source hash (and still re-hashes every call, see A3). Any hot loop that uses `execute_script` pays Python's compiler each execution.

**Impact.** Calls that re-execute the same source repeatedly pay compile cost again. For short scripts called very often this is a small per-call waste; for larger scripts it becomes noticeable.

**Relevant files:** `executor.py` (`run`), `executor.py` (`define` / `call` for the caching path that exists).

### A5. Decoding happens on the main thread with no per-frame byte budget.

**Mechanism.** `connection_manager.gd` `drain()` runs inside `BridgeInstance.tick()` → `poll()` → `_process`. Each drained frame does UTF-8 decode, `JSON.parse_string`, and the full recursive `PythonBridgeSerializer.decode`. The only budget is a per-frame *message count*: `max_results_per_frame = 64`. There is no byte or time budget per frame.

Backpressure throttles *dispatch* when the inbox reaches `max_inbox_size = 512`, but it never throttles *decode*. A single large result can still stall a frame.

**Impact.** A large single result stalls the main thread for the decode time in one frame. There is no result-size cap on the Godot side — only *requests* are capped at `max_payload_bytes = 64 MB`, and both WebSocket buffers are configured at 512 MB. Bigger payloads wait inside the websocket buffers, not inside a safety limit.

**Relevant files:** `connection_manager.gd` (`drain`), `bridge_instance.gd` (`tick`, `poll`, `_handle_message`), `scheduler.gd` (`_process_inbox`, `max_results_per_frame`, `max_inbox_size`), `config.gd` (`max_payload_bytes`, `max_inbox_size`).

### A6. Numeric typed arrays bypass the binary path entirely.

**Mechanism.** `serializer.gd` encodes `PackedInt32Array`, `PackedInt64Array`, `PackedFloat32Array`, `PackedFloat64Array` as plain JSON arrays of numbers (`{"$pb":"i32","v":[...]}` and similar). The Python side (`serializer.py`) does the same for lists (`"arr"`). Binary chunks are only used for `PackedByteArray`, numpy `ndarray`, and `Image`.

**Impact.** Common game numeric data (point clouds, meshes, matrices, histograms) travels as JSON text and is parsed element-by-element on the main thread instead of as a binary blob. This is the biggest data-path bottleneck for the most common numeric case, and it undercuts the "efficient binary transfer" story for numbers.

**Relevant files:** `serializer.gd` (typed-array encode), `serializer.gd` (typed-array decode), `serializer.py` (list/`"arr"` path), `protocol.gd`/`protocol.py` (chunk path used by `bytes`/`ndarray`/`image`).

### A7. Per-element serialization overhead on both sides.

**Mechanism.**
- Python `encode_obj` is a recursive `isinstance` chain that calls `_try_numpy()` (an `import numpy` check) on potentially every element, and wraps every dict/array node in `{"$pb": ...}` tags (`serializer.py`).
- Godot `decode` recursively allocates a new `Array` or `Dictionary` per node (`serializer.gd`).
- Blobs under the `INLINE_LIMIT = 512` bytes go through base64, adding ~33 % size and CPU for small blobs.

**Impact.** A 1 M-element result triggers ~1 M Python element checks + 1 M tagged dict allocations + JSON + 1 M Godot allocations. It is the constant overhead around every message, not just the large ones.

**Relevant files:** `serializer.py` (`encode_obj`, `_try_numpy`), `serializer.gd` (`encode`, `decode`), `serializer.gd` (`INLINE_LIMIT`, `_encode_blob`).

### A8. Queue-wait time counts toward the task timeout.

**Mechanism.** `task_manager.gd` `check_timeouts` uses `now_ms - task.created_at_ms > timeout_ms`, measured from *submission*, not from dispatch. The default task timeout is `task_timeout_ms = 30000` (`config.gd`).

**Impact.** Tasks waiting behind a busy or stuck worker time out before they ever run. Combined with A1/A2, this means a backlog plus a wedge produces a wave of `TIMEOUT` results even for tasks that never touched Python. This is the wrong failure for "task never got a slot".

**Relevant files:** `task_manager.gd` (`check_timeouts`, `task_timeout_ms`), `config.gd`.

### A9. Auto-assigned tasks can ping-pong across instances and lose module state.

**Mechanism.** Tasks with empty `instance_id` are assigned to any ready instance (`task_manager.gd` `_pop_front_for`). Contexts (namespaces, source hashes) are **per instance** (`executor.py` `ScriptHost.contexts`). There is no sticky routing.

**Impact.** With several instances, consecutive calls can land on different processes. Hash misses force redefinition every call (doubling A3's cost), and module-level Python state is silently partitioned across instances. If you rely on persistent module state, auto-routing is the wrong default and becomes a correctness bug, not just a performance one.

**Relevant files:** `task_manager.gd` (`_pop_front_for`, `_targets`), `executor.py` (`ScriptHost.contexts`), `python_bridge.gd` (`_submit_task_with_instance`).

---

## B. Startup and lifecycle

### B1. Cold start takes minutes.

**Mechanism.** On first start the provisioner poll-runs `venv` creation (120 s timeout), then `pip install` (300 s timeout), then the instance launches the Python server, writes a port file, polls for it (up to `PORT_PROBE_MAX = 1800` frames), connects to the WebSocket, and completes the hello handshake (`provisioner.gd`, `bridge_instance.gd`).

**Impact.** `start_instance` blocks the caller (via `await`) for the whole sequence. First start is seconds to minutes depending on the machine and whether Python is already present.

**Relevant files:** `provisioner.gd` (VENV/PIP phases, timeouts), `bridge_instance.gd` (`start`, `_probe_temp_file`), `config.gd` (`provision_venv_timeout_ms`, `provision_pip_timeout_ms`).

### B2. Blocking `OS.execute` calls happen on the main thread during startup and crash handling.

**Mechanism.**
- `_detect_python` can run `sh -lc "command -v python3"` (`_which_unix`) or `where python` (`_which_windows`).
- `_check_version` runs the Python interpreter once.
- `_verify_imports` launches **one Python subprocess per configured dependency** to test `import` — each one pays interpreter startup (~100–300 ms).
- `process_manager.kill()` runs `kill -9` / `taskkill` synchronously.

**Impact.** Several configured dependencies make the first-start sequencing visibly slower on the editor main thread. Crash recovery pays a synchronous kill.

**Relevant files:** `provisioner.gd` (`_detect_python`, `_check_version`, `_verify_imports`, `_which_windows`, `_which_unix`), `process_manager.gd` (`kill`).

### B3. Restart pays the full startup cost after slow detection.

**Mechanism.** Crash detection has two paths: WebSocket close is immediate, but health-based failure is slow: `health_check_interval_ms = 5000` × `health_missed_pong_limit = 3` ≈ 15 s worst case (`config.gd`). After detection, the instance restarts with full venv-server-port-handshake cost (~1–3 s).

**Impact.** For intermittent or health-only failures, restart is not fast. The restart backoff (`restart_base_delay_ms = 500`, `restart_backoff_factor = 2`, `max_restart_attempts = 3`) adds further delay.

**Relevant files:** `health_monitor.gd`, `bridge_instance.gd` (`_tick_health`, `_on_crash`), `config.gd` (health + restart defaults).

### B4. Hot reload via instance restart is expensive.

**Mechanism.** `hot_reload_mode = "restart_instance"` stops and restarts every active instance (`python_bridge.gd` `hot_reload_script`). The default mode is `reload_context`, which is cheaper, but the restart path exists.

**Impact.** Reloading a script while keeping the mode `restart_instance` tears down all running work for that instance and pays full startup again for each. It is a heavy-handed reload strategy.

**Relevant files:** `python_bridge.gd` (`hot_reload_script`), `config.gd` (`hot_reload_mode`).

### B5. `res://`-based workspace is read-only in exported builds.

**Mechanism.** The default workspace directory is `res://python_bridge` (`config.gd` `DEFAULT_WORKSPACE_DIR`). The provisioner and `create_script` write into it (venv, `scripts/`, `tmp/`, `config/`). Exported Godot projects cannot write to `res://`.

**Impact.** The bridge is effectively an editor/development tool unless `workspace_dir` is remapped to a writable FS path and the target is actually writable on the deployment machine.

**Relevant files:** `python_bridge.gd` (`workspace_dir`, `script_path_for`, `create_script`), `provisioner.gd` (workspace writes), `config.gd` (`DEFAULT_WORKSPACE_DIR`).

---

## C. Throughput ceilings (frame sync)

### C1. Hard per-frame ceilings.

**Defaults:** `max_dispatch_per_frame = 16`, `max_results_per_frame = 64`, `max_inbox_size = 512`, `max_inflight_per_instance = 1`, `max_queued_tasks = 1000` (`config.gd`).

**Impact.**
- `max_queued_tasks = 1000` rejects new tasks outright with "Task queue full" — the task is never queued, never retried.
- At 60 fps, the ceilings bound dispatch to ≤ 960 units/s and result processing to ≤ 3 840 results/s, before the serial-worker constraint (A1) even applies.
- The inbox hard cap of 512 triggers a throttling path and a warning; dispatch stops until the inbox drains.

**Relevant files:** `config.gd`, `scheduler.gd` (`_dispatch`, `_process_inbox`, `pending_dispatch_count`), `task_manager.gd` (`submit`).

### C2. Batch windows add latency.

**Mechanism.** When ≥ 2 batchable same-priority tasks exist, a window is opened and dispatch is delayed by up to `max_batch_delay_ms = 32` (`task_manager.gd` `next_unit`). The window closes early only on size (`max_batch_size = 32`) or higher-priority preemption.

**Impact.** Batching trades latency for throughput. A task that could have been dispatched immediately may wait up to 32 ms for a window to close. Prefixes of 1-2 fast calls do not get batched and do not benefit.

**Relevant files:** `task_manager.gd` (`next_unit`, `_flush_window`, `_build_batch`), `config.gd` (`max_batch_size`, `max_batch_delay_ms`).

### C3. `Array.pop_front()` on the scheduler inbox is O(n).

**Mechanism.** `_process_inbox` pops `k` items from a list of size `n` each frame. The list is not a deque.

**Impact.** Fine at rest; under sustained overload the per-frame drain cost grows with the buffered size. Not the primary bottleneck, but visible when the inbox is repeatedly full.

**Relevant files:** `scheduler.gd` (`_process_inbox`).

### C4. Per-frame O(n) scans.

**Mechanism.**
- `check_timeouts` walks the task registry every frame. Terminal tasks are kept for a grace period (`prune_terminal`, `keep_ms = 60000`).
- `tick_windows` scans the whole queue for each open batch window instance.
- `_insert_sorted` uses `Array.insert` shifts, O(n) per submission.

**Impact.** Healthy for hundreds of tasks. Degrading into the thousands, especially with many open batch windows or long task histories.

**Relevant files:** `task_manager.gd` (`check_timeouts`, `tick_windows`, `_insert_sorted`, `prune_terminal`), `scheduler.gd` (`_check_timeouts`).

---

## D. Protocol and transport

### D1. Everything is JSON except blobs.

**Mechanism.** Every message is `JSON.stringify` → WebSocket → `json.loads` → recursive tag-decode on both sides. On localhost, WebSocket RTT is sub-millisecond, so the dominant cost per message is JSON + decode, which on the Godot side runs on the main thread (see A5).

**Impact.** Overhead is per-message, not per-byte. Short messages pay a fixed JSON cost. This is the protocol-level reason A5 matters.

**Relevant files:** `connection_manager.gd` (`send_message`, `drain`), `protocol.gd` (`build_frame`, `parse_frame`), `protocol.py` (`build_text`, `parse`), `serializer.gd`, `serializer.py`.

### D2. Python binary-frame assembly is quadratic with many chunks.

**Mechanism.** `protocol.py` `build_binary` does `out += struct.pack("<I", len) + chunk` in a loop over chunks. `bytes` concatenation copies the whole buffer on each append.

**Impact.** A batch with many small binary results assembles the frame in O(n²) for n chunks. Fine for a few chunks; bad for thousands of small binary pieces.

**Relevant files:** `protocol.py` (`build_binary`).

### D3. Redundant second decode of task args on the Python side.

**Mechanism.** `protocol.parse` already decodes `msg["data"]` with the real chunk stream. Then `executor.execute_job` decodes `data["args"]` and `data["kwargs"]` again with **empty** chunks.

**Impact.** The second decode is harmless (values are already decoded Python objects) but it is pure per-task waste.

**Relevant files:** `protocol.py` (`parse`), `executor.py` (`execute_job`).

### D4. Unbounded stdout/stderr capture and no result-size cap.

**Mechanism.** Captured `stdout`/`stderr` from user code is returned inside the response. There is no result-size cap on the Godot side (A5), and no cap on the Python side on captured output.

**Impact.** A user script that logs a lot or returns a huge structure can produce large responses and large main-thread decode cost.

**Relevant files:** `executor.py` (`execute_job`, `redirect_stdout`/`redirect_stderr`), `protocol.py` (response envelope).

---

## E. Long tail

- **Cancel is best-effort:** queued tasks cancel instantly; running tasks are only marked. Python computes to completion (A2).
- **Per-instance memory:** N instances means N interpreters, N asyncio servers, and N WebSocket buffers (512 MB configured each side). There is no process pooling or reuse.
- **Health pings are the only liveness signal.** A Python thread stuck in a C extension holding the GIL stops ponging and can trigger a spurious crash/restart cycle.
- **`_introspect_request`** busy-polls `process_frame` up to 30 s per introspection. Acceptable for wrapper generation, but it is a long-lived await on the facade.
- **Flatpak-sandboxed Godot:** the subprocess cannot reach the venv's site-packages (`ModuleNotFoundError: websockets`). Documented in `e2e_live.gd`. Native installs only.

---

## Ranked by practical impact

1. **A2** — one runaway task wedges the whole instance.
2. **A1** — serial execution + `max_inflight_per_instance = 1` is the hard per-instance throughput ceiling.
3. **A3** — per-call source re-read, re-send, re-hash is the hidden per-call tax that grows with script size.
4. **A5 + A6** — main-thread decode with no byte budget, and numeric arrays via JSON, are the main frame-stall and large-data paths.
5. **B1 + B2** — cold start minutes and blocking `OS.execute` calls shape the first-run and editor-freeze experience.
6. Everything else scales in severity with queue depth, batch windows, and result size.

---

## Where to look first

If the goal is **reliability**, start with A2 (interrupting or detecting a stuck worker faster) and A8 (timeout measured from dispatch, or a separate slot timeout).

If the goal is **throughput**, start with A1 (per-instance workers) and A3 (don't ship unchanged source every call).

If the goal is **frame stability and large data**, start with A5 (per-frame decode budget) and A6 (binary path for numeric arrays).

If the goal is **first-run and editor ergonomics**, start with B1/B2 (faster, non-blocking startup path) and B5 (writable workspace story for exports).
