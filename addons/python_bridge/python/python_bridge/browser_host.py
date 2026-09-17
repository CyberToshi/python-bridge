"""Browser host for the Pyodide/WebAssembly runtime.

This module is the web counterpart of ``server.py``. It intentionally reuses
the exact same building blocks as the desktop transport:

  - ``executor.ScriptHost``  (persistent contexts, source hashes, cooperative
    cancellation, stdout/stderr caps)
  - ``protocol``             (Protocol v2: text JSON + binary chunk frames)
  - ``serializer``           (type tags, binary chunks)
  - ``introspection``        (AST analysis for wrapper generation)
  - ``data_registry.DataStore`` (DataRef handles for large results)

Differences to the desktop server (by design, browser constraints):

  - No asyncio and no WebSocket: the JS Web Worker calls
    ``handle_message(raw)`` synchronously and sends the returned frames back
    over ``postMessage``.
  - No worker thread pool: Pyodide runs single-threaded, so exactly one job
    runs at a time. Long-running user code blocks the worker until it
    finishes; cooperative cancellation via ``__bridge__.checkpoint()``
    is checked BETWEEN messages (a checkpoint inside the running code still
    works - the flag is set by a preceding CANCEL message).
  - No per-task wall-clock timeout / watchdog: a blocking task cannot be
    interrupted by the host. Use cooperative cancellation checkpoints in
    long-running loops (same API as on desktop).
  - No file-backed DataRefs: ``DataStore`` runs memory-only (no FileAccess
    into the worker's MEMFS from the outside). Materialization always uses
    the regular binary-chunk transfer.
  - ``shutdown`` returns the ack and marks the host stopped; the JS worker
    decides what to do (typically nothing - terminating a Pyodide worker is
    cheap because the runtime is recreated on next start).

The message semantics, envelope shapes and error taxonomy are byte-compatible
with the desktop server, so the Godot side needs no protocol changes.
"""

import base64
import json
import os
import sys

from . import protocol, executor, introspection
from .data_registry import DataStore
from .serializer import encode_obj

VERSION = "0.2.0-web.1"
PLATFORM = "web"


def _task_error_body(msg_id, code, message, ms=0):
    return protocol.build_response(
        protocol.MSG_TASK_ERROR, msg_id, "error",
        error={"code": code, "type": code, "message": message, "traceback": ""},
        ms=ms)


class BrowserHost:
    """One per Pyodide worker = one ScriptHost, mirroring one desktop process."""

    def __init__(self, caps=None, workspace_root="/workspace", tag="web"):
        caps = caps or {}
        self.tag = str(tag)
        self.workspace_root = str(workspace_root)
        self.host = executor.ScriptHost(
            max_stdout_bytes=int(caps.get("max_stdout_bytes",
                                          executor.DEFAULT_MAX_STDOUT_BYTES)),
            max_stderr_bytes=int(caps.get("max_stderr_bytes",
                                          executor.DEFAULT_MAX_STDERR_BYTES)))
        self.max_result_bytes = int(caps.get("max_result_bytes", 0)) or 64 * 1024 * 1024
        # Memory-only store: browser cannot expose worker-internal files to
        # Godot, so file-backed DataRefs are a desktop-only feature.
        self.data_store = DataStore(int(caps.get("data_ref_threshold_bytes", 0) or 0))
        self.shutdown_requested = False
        self.started_ms = _now_ms()

    # ------------------------------------------------------------- bootstrap
    def bootstrap(self):
        """Runs once after the runtime is up: makes the workspace importable.

        Python code stays platform-independent: ``import modules.calculations``
        works identically on desktop (workspace on disk) and in the browser
        (workspace in MEMFS). plugins/ and packages/ are importable too, so a
        workspace laid out like

            python/  main.py  modules/  plugins/

        behaves like a normal Python installation. Returns a status dict for
        the worker log.
        """
        root = self.workspace_root
        for path in (root, root + "/modules", root + "/plugins",
                     root + "/packages", root + "/bridge"):
            if path and path not in sys.path:
                sys.path.insert(0, path)
        return {
            "platform": PLATFORM,
            "version": VERSION,
            "python": sys.version.split()[0],
            "workspace": self.workspace_root,
        }

    # ------------------------------------------------------------- dispatch
    def handle_message(self, raw):
        """Parses one incoming frame and returns a list of outgoing frames.

        Each outgoing frame is ``{"text": str}`` or ``{"binary": bytes}``,
        exactly the shapes ``protocol.parse`` produces/consumes on the other
        side of the JS boundary.
        """
        try:
            message, _data = protocol.parse(raw)
        except Exception as exc:  # noqa: BLE001 - never crash the worker
            return [{"text": json.dumps(_task_error_body(
                "", protocol.CATEGORY_PROTOCOL_ERROR,
                "Frame parse failed: %s" % exc))}]

        if not isinstance(message, dict) or message.get("type") == "malformed":
            return [{"text": json.dumps(_task_error_body(
                "", protocol.CATEGORY_PROTOCOL_ERROR, "Malformed message"))}]

        mtype = message.get("type")
        msg_id = str(message.get("id", ""))

        if mtype == protocol.MSG_PING:
            return [self._text({
                "v": protocol.PROTOCOL_VERSION,
                "type": protocol.MSG_PONG,
                "id": msg_id,
            })]

        if mtype == protocol.MSG_HELLO:
            return [self._text({
                "v": protocol.PROTOCOL_VERSION,
                "type": protocol.MSG_HELLO_ACK,
                "id": msg_id,
                "pid": os.getpid(),
                "bridge_version": VERSION,
                "platform": PLATFORM,
            })]

        if mtype == protocol.MSG_CANCEL:
            self.host.mark_cancelled(str(message.get("target_id", "")))
            return [self._text({
                "v": protocol.PROTOCOL_VERSION,
                "type": protocol.MSG_CANCEL_ACK,
                "id": msg_id,
                "target_id": message.get("target_id", ""),
            })]

        if mtype == protocol.MSG_RELOAD:
            context = str(message.get("context", "anon"))
            source = str(message.get("source", ""))
            _result, err = self.host.reload_context(context, source)
            if err is None:
                return [self._text({
                    "v": protocol.PROTOCOL_VERSION,
                    "type": protocol.MSG_RELOAD_ACK,
                    "id": msg_id,
                    "status": "ok",
                })]
            return [{"text": json.dumps(protocol.build_response(
                protocol.MSG_RELOAD_ACK, msg_id, "error", error=err))}]

        if mtype == protocol.MSG_INTROSPECT:
            return self._handle_introspect(message, msg_id)

        if mtype == protocol.MSG_DATA_GET:
            return self._handle_data_get(message, msg_id)

        if mtype == protocol.MSG_DATA_RELEASE:
            freed = self.data_store.release(str(message.get("ref_id", "")))
            return [self._text({
                "v": protocol.PROTOCOL_VERSION,
                "type": protocol.MSG_DATA_ACK,
                "id": msg_id,
                "ref_id": message.get("ref_id", ""),
                "status": "ok",
                "freed": freed,
            })]

        if mtype == protocol.MSG_SHUTDOWN:
            self.shutdown_requested = True
            return [self._text({
                "v": protocol.PROTOCOL_VERSION,
                "type": protocol.MSG_SHUTDOWN_ACK,
                "id": msg_id,
                "status": "ok",
            })]

        if mtype in (protocol.MSG_TASK, protocol.MSG_BATCH):
            return self._handle_job(message, msg_id)

        return [{"text": json.dumps(_task_error_body(
            msg_id, protocol.CATEGORY_PROTOCOL_ERROR,
            "Unknown message type: %s" % mtype))}]

    # ------------------------------------------------------------- jobs
    def _handle_job(self, message, msg_id):
        # Single-threaded: context locks are unnecessary here, ScriptHost's
        # per-job bookkeeping (thread-local) works fine without threads.
        if message.get("type") == protocol.MSG_BATCH:
            chunks = []
            out_items = []
            for item in message.get(protocol.FIELD_ITEMS, []):
                body = self.host.execute_job(item)
                entry = {
                    "id": str(item.get("id", "")),
                    "ms": body["ms"],
                    "stdout": body.get("stdout", ""),
                    "stderr": body.get("stderr", ""),
                    "stdout_truncated": bool(body.get("stdout_truncated", False)),
                    "stderr_truncated": bool(body.get("stderr_truncated", False)),
                }
                if body["status"] == "ok":
                    entry["status"] = "ok"
                    entry["data"] = self._ref_or_encode(body.get("data"), chunks)
                else:
                    entry["status"] = "error"
                    entry["error"] = body.get("error") or {
                        "code": protocol.CATEGORY_TASK_ERROR,
                        "type": "Error", "message": "unknown", "traceback": ""}
                out_items.append(entry)
            head = {"v": protocol.PROTOCOL_VERSION,
                    "type": protocol.MSG_BATCH_RESULT,
                    "id": msg_id, "items": out_items}
        else:
            body = self.host.execute_job(message)
            chunks = []
            if body["status"] == "ok":
                body["data"] = self._ref_or_encode(body.get("data"), chunks)
            if body["status"] == "ok":
                head = protocol.build_response(
                    protocol.MSG_TASK_RESULT, msg_id, "ok",
                    data=body.get("data"), ms=body["ms"])
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

        return self._frames(head, chunks)

    def _ref_or_encode(self, value, chunks):
        """Same auto-DataRef decision as the desktop server."""
        ref = self.data_store.maybe_ref(value)
        if ref is not None:
            return ref
        return encode_obj(value, chunks)

    # ------------------------------------------------------------- data plane
    def _handle_data_get(self, message, msg_id):
        """Materializes a DataRef handle. Memory-only in the browser: the
        ``want == "file"`` hint is ignored (no shared filesystem), the value
        always travels as a regular binary-chunk frame."""
        ref_id = str(message.get("ref_id", ""))
        value, _meta = self.data_store.get(ref_id)
        if value is None:
            return [{"text": json.dumps({
                "v": protocol.PROTOCOL_VERSION,
                "type": protocol.MSG_DATA_RESULT,
                "id": msg_id,
                "ref_id": ref_id,
                "status": "error",
                "error": {"code": protocol.CATEGORY_TASK_ERROR,
                          "type": "DataHandleError",
                          "message": "Data handle '%s' is stale or was "
                                     "released" % ref_id,
                          "traceback": ""},
            })}]
        chunks = []
        encoded = encode_obj(value, chunks)
        head = {
            "v": protocol.PROTOCOL_VERSION,
            "type": protocol.MSG_DATA_RESULT,
            "id": msg_id,
            "ref_id": ref_id,
            "status": "ok",
            "data": encoded,
        }
        return self._frames(head, chunks)

    # ------------------------------------------------------------- introspect
    def _handle_introspect(self, message, msg_id):
        source = str(message.get("source", ""))
        try:
            schema = introspection.analyze(source)
            return [self._text({
                "v": protocol.PROTOCOL_VERSION,
                "type": protocol.MSG_INTROSPECT_RESULT,
                "id": msg_id,
                "status": "ok",
                "functions": schema["functions"],
            })]
        except SyntaxError as exc:
            return [self._text({
                "v": protocol.PROTOCOL_VERSION,
                "type": protocol.MSG_INTROSPECT_RESULT,
                "id": msg_id,
                "status": "error",
                "error": {"code": protocol.CATEGORY_PYTHON_EXCEPTION,
                          "type": "SyntaxError", "message": str(exc),
                          "traceback": ""},
            })]
        except Exception as exc:  # noqa: BLE001
            return [self._text({
                "v": protocol.PROTOCOL_VERSION,
                "type": protocol.MSG_INTROSPECT_RESULT,
                "id": msg_id,
                "status": "error",
                "error": {"code": protocol.CATEGORY_PYTHON_EXCEPTION,
                          "type": type(exc).__name__, "message": str(exc),
                          "traceback": ""},
            })]

    # ------------------------------------------------------------- framing
    def _text(self, msg):
        return {"text": json.dumps(msg)}

    def _frames(self, head, chunks):
        if chunks:
            return [{"binary": protocol.build_binary(json.dumps(head), chunks)}]
        return [{"text": json.dumps(head)}]


def _now_ms():
    import time
    return int(time.time() * 1000)


# ------------------------------------------------------------------ JS bridge
# Thin string-based entry points called from the JS Web Worker (and from the
# Node-based test harness). Everything crossing the JS<->WASM boundary is a
# plain string: requests come in as text or base64, frames go out as a JSON
# list of {"text": str} / {"b64": str} entries. Binary efficiency can be
# improved later via direct TypedArray exchange without touching semantics.

_HOST = None  # type: BrowserHost|None


def js_init(caps_json="{}", workspace_root="/workspace", tag="web"):
    """Creates the module-level BrowserHost. Called once by the worker after
    the runtime and the bridge package are in place. Returns the bootstrap
    status dict as JSON."""
    global _HOST
    caps = json.loads(caps_json) if isinstance(caps_json, str) else (caps_json or {})
    _HOST = BrowserHost(caps, workspace_root=workspace_root, tag=tag)
    return json.dumps(_HOST.bootstrap())


def js_dispatch(raw_b64="", raw_text=""):
    """Dispatches one incoming frame and returns the outgoing frames as a
    JSON string. Never raises: internal failures become task_error frames."""
    if _HOST is None:
        return json.dumps([{"b64": base64.b64encode(json.dumps(
            _task_error_body("", protocol.CATEGORY_BRIDGE_ERROR,
                             "BrowserHost not initialized")).encode("utf-8")
        ).decode("ascii")}])
    raw = base64.b64decode(raw_b64) if raw_b64 else raw_text
    out = []
    for frame in _HOST.handle_message(raw):
        if "text" in frame:
            out.append({"text": frame["text"]})
        else:
            out.append({"b64": base64.b64encode(frame["binary"]).decode("ascii")})
    return json.dumps(out)


def js_cancel_flag(task_id, flag=True):
    """Optional pre-arrival cancel registration (cooperative cancel works
    through the normal CANCEL message; this is only a convenience hook)."""
    if _HOST is not None:
        _HOST.host.mark_cancelled(task_id)
    return "ok"
