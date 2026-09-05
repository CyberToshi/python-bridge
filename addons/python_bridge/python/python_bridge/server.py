"""WebSocket server, one instance = one process = one ScriptHost.

Godot reads port+pid from a tmp file, connects and sends messages. The
asyncio loop stays responsive during long-running user code: control
messages (ping, hello, cancel, reload, introspect, shutdown) are handled
inline by the reader task, while task/batch messages are executed in a
single worker thread (one job at a time per instance) so contexts stay
sequential and race-free.

Timeout semantics: `timeout_ms` per task/batch is enforced with
asyncio.wait_for. A timed-out task keeps running in the worker thread
(it cannot be killed safely) but its result is discarded; the client-side
TaskManager already marked the task TIMEOUT.
"""

import asyncio
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from functools import partial

import websockets

from . import protocol, executor, introspection
from .serializer import encode_obj

VERSION = "0.2.0"

# Resultat-Groessenlimit (Bytes). Godot uebergibt den konfigurierten Wert
# beim Prozessstart; dieser Default gilt fuer Standalone-Betrieb/Tests.
DEFAULT_MAX_RESULT_BYTES = 256 * 1024 * 1024


def _frame_size(head_json, chunks):
    """Gesamtgroesse einer zu sendenden Nachricht in Bytes."""
    total = 4 + len(head_json.encode("utf-8"))
    for chunk in chunks:
        total += 4 + len(chunk)
    return total


async def _send_text(ws, lock, message):
    async with lock:
        await ws.send(protocol.build_text(message))


async def _send_frame(ws, lock, frame):
    async with lock:
        await ws.send(frame)


def _task_error_body(msg_id, code, message, ms=0):
    return protocol.build_response(
        protocol.MSG_TASK_ERROR, msg_id, "error",
        error={"code": code, "type": code, "message": message, "traceback": ""},
        ms=ms)


def _encode_with_chunks(value, chunks):
    """Encodes a value into JSON-compatible form, appending binary chunks."""
    return encode_obj(value, chunks)


async def _handle_connection(ws, state):
    """Reader task: control messages inline, task/batch enqueued."""
    caps = state.get("caps") or {}
    host = executor.ScriptHost(
        max_stdout_bytes=caps.get("max_stdout_bytes", executor.DEFAULT_MAX_STDOUT_BYTES),
        max_stderr_bytes=caps.get("max_stderr_bytes", executor.DEFAULT_MAX_STDERR_BYTES))
    max_result_bytes = int(caps.get("max_result_bytes", DEFAULT_MAX_RESULT_BYTES))
    executor_pool = ThreadPoolExecutor(max_workers=1)
    job_queue = asyncio.Queue()
    send_lock = asyncio.Lock()
    loop = asyncio.get_running_loop()

    state["connections"] += 1
    try:
        # Worker task: consumes the job queue, runs user code, responds.
        async def _worker():
            while True:
                message = await job_queue.get()
                if state["shutdown"]:
                    return
                await _run_job(ws, send_lock, loop, executor_pool, host, message,
                               max_result_bytes)

        worker_task = asyncio.create_task(_worker())

        try:
            async for raw in ws:
                message, data = protocol.parse(raw)
                if not isinstance(message, dict) or message.get("type") == "malformed":
                    continue
                mtype = message.get("type")
                msg_id = message.get("id", "")

                if mtype == protocol.MSG_PING:
                    await _send_text(ws, send_lock, {
                        "v": protocol.PROTOCOL_VERSION,
                        "type": protocol.MSG_PONG,
                        "id": msg_id,
                    })
                elif mtype == protocol.MSG_HELLO:
                    await _send_text(ws, send_lock, {
                        "v": protocol.PROTOCOL_VERSION,
                        "type": protocol.MSG_HELLO_ACK,
                        "id": msg_id,
                        "pid": os.getpid(),
                        "bridge_version": VERSION,
                    })
                elif mtype == protocol.MSG_CANCEL:
                    host.mark_cancelled(str(message.get("target_id", "")))
                    await _send_text(ws, send_lock, {
                        "v": protocol.PROTOCOL_VERSION,
                        "type": protocol.MSG_CANCEL_ACK,
                        "id": msg_id,
                        "target_id": message.get("target_id", ""),
                    })
                elif mtype == protocol.MSG_RELOAD:
                    context = str(message.get("context", "anon"))
                    source = str(message.get("source", ""))
                    result, err = host.reload_context(context, source)
                    if err is None:
                        await _send_text(ws, send_lock, {
                            "v": protocol.PROTOCOL_VERSION,
                            "type": protocol.MSG_RELOAD_ACK,
                            "id": msg_id,
                            "status": "ok",
                        })
                    else:
                        await _send_text(ws, send_lock, protocol.build_response(
                            protocol.MSG_RELOAD_ACK, msg_id, "error", error=err))
                elif mtype == protocol.MSG_INTROSPECT:
                    await _handle_introspect(ws, send_lock, message, msg_id)
                elif mtype == protocol.MSG_SHUTDOWN:
                    await _send_text(ws, send_lock, {
                        "v": protocol.PROTOCOL_VERSION,
                        "type": protocol.MSG_SHUTDOWN_ACK,
                        "id": msg_id,
                        "status": "ok",
                    })
                    state["shutdown"] = True
                    await ws.close()
                    return
                elif mtype in (protocol.MSG_TASK, protocol.MSG_BATCH):
                    await job_queue.put(message)
                else:
                    await _send_text(ws, send_lock, protocol.build_response(
                        protocol.MSG_TASK_ERROR, msg_id, "error",
                        error={"code": protocol.CATEGORY_PROTOCOL_ERROR,
                               "type": "ProtocolError",
                               "message": "Unknown message type: %s" % mtype,
                               "traceback": ""}))
        finally:
            worker_task.cancel()
            try:
                await worker_task
            except asyncio.CancelledError:
                pass
            executor_pool.shutdown(wait=False, cancel_futures=True)
    finally:
        state["connections"] -= 1


async def _run_job(ws, send_lock, loop, executor_pool, host, message, max_result_bytes):
    """Runs one task or batch message in the worker thread and responds."""
    msg_id = str(message.get("id", ""))
    timeout_ms = int(message.get("timeout_ms", 0) or 0)
    timeout = timeout_ms / 1000.0 if timeout_ms > 0 else None

    if message.get("type") == protocol.MSG_BATCH:
        items = message.get(protocol.FIELD_ITEMS, [])
        try:
            bodies = await asyncio.wait_for(
                loop.run_in_executor(
                    executor_pool,
                    lambda: [host.execute_job(item) for item in items]),
                timeout)
        except asyncio.TimeoutError:
            await _send_text(ws, send_lock, _task_error_body(
                msg_id, protocol.CATEGORY_TIMEOUT_ERROR,
                "Batch timeout after %d ms" % timeout_ms))
            return
        chunks = []
        out_items = []
        oversized = False
        for item, body in zip(items, bodies):
            item_id = str(item.get("id", ""))
            entry = {"id": item_id, "ms": body["ms"],
                     "stdout": body.get("stdout", ""), "stderr": body.get("stderr", ""),
                     "stdout_truncated": bool(body.get("stdout_truncated", False)),
                     "stderr_truncated": bool(body.get("stderr_truncated", False))}
            if body["status"] == "ok":
                entry["status"] = "ok"
                entry["data"] = _encode_with_chunks(body["data"], chunks)
            else:
                entry["status"] = "error"
                entry["error"] = body.get("error") or {
                    "code": protocol.CATEGORY_TASK_ERROR,
                    "type": "Error", "message": "unknown", "traceback": ""}
            out_items.append(entry)
        head = {"v": protocol.PROTOCOL_VERSION, "type": protocol.MSG_BATCH_RESULT,
                "id": msg_id, "items": out_items}
        if _frame_size(json.dumps(head), chunks) > max_result_bytes:
            await _send_text(ws, send_lock, _task_error_body(
                msg_id, protocol.CATEGORY_SERIALIZATION_ERROR,
                "Batch result exceeds max_result_bytes (%d)" % max_result_bytes))
            return
        if chunks:
            await _send_frame(ws, send_lock, protocol.build_binary(
                json.dumps(head), chunks))
        else:
            await _send_text(ws, send_lock, head)
        return

    # Single task
    try:
        body = await asyncio.wait_for(
            loop.run_in_executor(executor_pool, host.execute_job, message),
            timeout)
    except asyncio.TimeoutError:
        await _send_text(ws, send_lock, _task_error_body(
            msg_id, protocol.CATEGORY_TIMEOUT_ERROR,
            "Task timeout after %d ms" % timeout_ms))
        return

    if body["status"] == "ok":
        chunks = []
        encoded = _encode_with_chunks(body["data"], chunks)
        head = protocol.build_response(
            protocol.MSG_TASK_RESULT, msg_id, "ok", data=encoded, ms=body["ms"])
        head["stdout"] = body.get("stdout", "")
        head["stderr"] = body.get("stderr", "")
        head["stdout_truncated"] = bool(body.get("stdout_truncated", False))
        head["stderr_truncated"] = bool(body.get("stderr_truncated", False))
        if _frame_size(json.dumps(head), chunks) > max_result_bytes:
            await _send_text(ws, send_lock, _task_error_body(
                msg_id, protocol.CATEGORY_SERIALIZATION_ERROR,
                "Task result exceeds max_result_bytes (%d)" % max_result_bytes))
            return
        if chunks:
            await _send_frame(ws, send_lock, protocol.build_binary(
                json.dumps(head), chunks))
        else:
            await _send_text(ws, send_lock, head)
    else:
        head = protocol.build_response(
            protocol.MSG_TASK_ERROR, msg_id, "error",
            error=body.get("error") or {
                "code": protocol.CATEGORY_TASK_ERROR,
                "type": "Error", "message": "unknown", "traceback": ""},
            ms=body["ms"])
        head["stdout"] = body.get("stdout", "")
        head["stderr"] = body.get("stderr", "")
        head["stdout_truncated"] = bool(body.get("stdout_truncated", False))
        head["stderr_truncated"] = bool(body.get("stderr_truncated", False))
        await _send_text(ws, send_lock, head)


async def _handle_introspect(ws, send_lock, message, msg_id):
    source = str(message.get("source", ""))
    try:
        schema = introspection.analyze(source)
        await _send_text(ws, send_lock, {
            "v": protocol.PROTOCOL_VERSION,
            "type": protocol.MSG_INTROSPECT_RESULT,
            "id": msg_id,
            "status": "ok",
            "functions": schema["functions"],
        })
    except SyntaxError as exc:
        await _send_text(ws, send_lock, {
            "v": protocol.PROTOCOL_VERSION,
            "type": protocol.MSG_INTROSPECT_RESULT,
            "id": msg_id,
            "status": "error",
            "error": {"code": protocol.CATEGORY_PYTHON_EXCEPTION,
                      "type": "SyntaxError", "message": str(exc),
                      "traceback": ""},
        })
    except Exception as exc:  # noqa: BLE001
        await _send_text(ws, send_lock, {
            "v": protocol.PROTOCOL_VERSION,
            "type": protocol.MSG_INTROSPECT_RESULT,
            "id": msg_id,
            "status": "error",
            "error": {"code": protocol.CATEGORY_PYTHON_EXCEPTION,
                      "type": type(exc).__name__, "message": str(exc),
                      "traceback": ""},
        })


async def run(host, port, tmpdir, tag, caps=None):
    """Bind, write port+pid tmp file, serve; exit when shutdown requested or
    after the connection dropped (no zombies). `caps` ist ein optionales
    Dict mit max_stdout_bytes / max_stderr_bytes / max_result_bytes."""
    state = {"shutdown": False, "connections": 0, "caps": caps or {}}

    async def _serve():
        server = await websockets.serve(
            partial(_handle_connection, state=state),
            host, port,
            max_size=512 * 1024 * 1024,
            subprotocols=["pybridge-v%d" % protocol.PROTOCOL_VERSION])
        real_port = server.sockets[0].getsockname()[1]
        _write_tmp(tmpdir, tag, real_port, os.getpid())
        print("[python_bridge] %s listens on ws://127.0.0.1:%d (pid=%d)" %
              (tag, real_port, os.getpid()), flush=True)

        # Grace period before exiting after the connection drops: the client
        # may reconnect (transient blip). Only exit for good when no new
        # connection arrived within the grace period - prevents zombies after
        # a Godot crash without killing legitimate reconnects.
        grace_seconds = 5.0
        disconnected_at = None
        while not state["shutdown"]:
            await asyncio.sleep(0.1)
            if state["connections"] > 0:
                disconnected_at = None
            elif disconnected_at is None:
                disconnected_at = asyncio.get_running_loop().time()
            elif asyncio.get_running_loop().time() - disconnected_at > grace_seconds:
                break
        server.close()
        await server.wait_closed()

    try:
        await _serve()
    except (SystemExit, KeyboardInterrupt):
        pass
    finally:
        # Force-exit: guarantees no lingering process even if a worker
        # thread is stuck in user code (which cannot be killed safely).
        os._exit(0)


def _write_tmp(tmpdir, tag, port, pid):
    os.makedirs(tmpdir, exist_ok=True)
    path = os.path.join(tmpdir, "%s.json" % tag)
    with open(path, "w") as f:
        json.dump({"port": port, "pid": pid}, f)