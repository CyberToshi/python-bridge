"""Skript-Kontexte: persistente Namespaces pro context_id.

Jeder `context_id` gehört ein eigener Namespace. So können mehrere Skripte
(Funktionen, Imports, Zwischenzustände) dauerhaft in derselben Instanz leben,
ohne sich zu überschreiben.

Konventionen (Kompatibilität zu v0.1.0):
  run    - Führt die Quelle mit der Variable `input` aus; Ergebnis kommt aus
           `result`. Wird bei jedem Aufruf neu ausgeführt.
  call   - Definiert die Quelle genau dann neu, wenn sich ihr Inhalt geändert
           hat (Source-Hash), ruft dann die benannte Funktion auf. Modul-Level
           State bleibt zwischen Aufrufen erhalten.
  define - Führt die Quelle aus, ohne eine Funktion aufzurufen.

Fehler werden strukturiert gemeldet ({code, type, message, traceback}); der
Prozess bleibt am Leben. stdout/stderr des Nutzer-Codes werden pro Aufruf
erfasst und in der Antwort zurückgegeben.
"""

import hashlib
import io
import traceback
from contextlib import redirect_stderr, redirect_stdout

from . import protocol

SYNTAX_FILENAME_PREFIX = "<bridge:"

# Default output caps (bytes). Godot uebergibt die konfigurierten Werte beim
# Prozessstart (siehe bridge_instance.gd); diese Defaults gelten fuer den
# Standalone-Betrieb und die Tests.
DEFAULT_MAX_STDOUT_BYTES = 1024 * 1024
DEFAULT_MAX_STDERR_BYTES = 1024 * 1024


class _CappedWriter(io.TextIOBase):
    """Text-Writer, der nach `limit` Bytes keine weiteren Daten mehr haelt.

    Verhindert unbegrenztes stdout/stderr-Wachstum durch haengengebliebene
    oder sehr gespraechige Tasks. `overflowed` wird gesetzt, sobald Daten
    verworfen wurden; der Aufrufer kann das als `truncated`-Flag melden.
    """

    def __init__(self, limit):
        super().__init__()
        self._limit = max(limit, 0)
        self._buf = io.StringIO()
        self._written = 0
        self.overflowed = False

    def write(self, s):
        if not s:
            return 0
        text = str(s)
        if self._written >= self._limit:
            self.overflowed = True
            return len(text)
        room = self._limit - self._written
        if len(text) > room:
            self._buf.write(text[:room])
            self._written += room
            self.overflowed = True
            return len(text)
        self._buf.write(text)
        self._written += len(text)
        return len(text)

    def getvalue(self):
        return self._buf.getvalue()



class ScriptContext:
    __slots__ = ("namespace", "source_hash")

    def __init__(self):
        self.namespace = {"__name__": "__pybridge__", "input": None}
        self.source_hash = None


def _hash(source):
    return hashlib.sha256(source.encode("utf-8")).hexdigest()


def _error(exc_type, exc, code=protocol.CATEGORY_PYTHON_EXCEPTION):
    return {
        "code": code,
        "type": exc_type,
        "message": str(exc),
        "traceback": traceback.format_exc(),
    }


class ScriptHost:
    """One per Python instance. All methods run in the instance's single
    worker thread (see server.py), so no locking is required."""

    def __init__(self, max_stdout_bytes=DEFAULT_MAX_STDOUT_BYTES,
                 max_stderr_bytes=DEFAULT_MAX_STDERR_BYTES):
        self.contexts = {}
        self.max_stdout_bytes = max_stdout_bytes
        self.max_stderr_bytes = max_stderr_bytes
        # Set of task ids the client asked to cancel. Checked at job start;
        # a running task cannot be interrupted safely (documented).
        self.cancelled = set()

    def configure(self, max_stdout_bytes=None, max_stderr_bytes=None):
        """Updates the capture caps (called from the server when the client
        announces its configured limits in HELLO)."""
        if max_stdout_bytes is not None:
            self.max_stdout_bytes = int(max_stdout_bytes)
        if max_stderr_bytes is not None:
            self.max_stderr_bytes = int(max_stderr_bytes)

    def _context(self, context_id):
        ctx = self.contexts.get(context_id)
        if ctx is None:
            ctx = ScriptContext()
            self.contexts[context_id] = ctx
        return ctx

    # ------------------------------------------------------------------ API
    def define(self, context_id, source):
        """Compiles and executes `source` in the context. Returns (result,
        error); result is None for define."""
        ctx = self._context(context_id)
        ns = ctx.namespace
        try:
            code = compile(source, SYNTAX_FILENAME_PREFIX + context_id + ">", "exec")
        except SyntaxError as exc:
            return None, _error("SyntaxError", exc)
        try:
            exec(code, ns)
        except Exception as exc:  # noqa: BLE001 - Nutzer-Code, strukturiert melden
            return None, _error(type(exc).__name__, exc)
        ctx.source_hash = _hash(source)
        return None, None

    def run(self, context_id, source, input_data):
        """Führt source aus (input/result-Konvention), immer frisch."""
        ctx = self._context(context_id)
        ns = ctx.namespace
        ns["input"] = input_data
        try:
            code = compile(source, SYNTAX_FILENAME_PREFIX + context_id + ">", "exec")
        except SyntaxError as exc:
            return None, _error("SyntaxError", exc)
        try:
            exec(code, ns)
        except Exception as exc:  # noqa: BLE001
            return None, _error(type(exc).__name__, exc)
        ctx.source_hash = _hash(source)
        return ns.get("result"), None

    def call(self, context_id, source, function, args, kwargs):
        """Definiert nur bei geändertem Source neu, ruft dann die Funktion."""
        ctx = self._context(context_id)
        if ctx.source_hash != _hash(source):
            _, err = self.define(context_id, source)
            if err is not None:
                return None, err
        ns = ctx.namespace
        fn = ns.get(function)
        if fn is None:
            return None, _error(
                "AttributeError",
                "Function '%s' is not defined in script context '%s'" % (function, context_id))
        try:
            result = fn(*args, **kwargs)
        except Exception as exc:  # noqa: BLE001
            return None, _error(type(exc).__name__, exc)
        return result, None

    def reload_context(self, context_id, source):
        """Invalidates the source hash and re-defines the context. Used by
        hot reload; other contexts and the process stay alive."""
        ctx = self._context(context_id)
        ctx.source_hash = None
        return self.define(context_id, source)

    # ------------------------------------------------------------------ Jobs
    def execute_job(self, message):
        """Executes one task message. Returns a response body dict:
        {status: "ok"|"error"|"cancelled", data?, error?, stdout, stderr, ms}
        Runs in the worker thread; never touches asyncio objects."""
        start_ms = _now_ms()
        msg_id = str(message.get("id", ""))
        if self.consume_cancelled(msg_id):
            return {
                "status": "cancelled",
                "error": {"code": protocol.CATEGORY_TASK_ERROR,
                          "type": "CancelledError",
                          "message": "Task cancelled", "traceback": ""},
                "stdout": "", "stderr": "", "ms": _now_ms() - start_ms,
            }

        command = message.get("command", protocol.CMD_RUN)
        context_id = str(message.get("context", "anon"))
        source = str(message.get("source", ""))
        data = message.get("data") or {}

        stdout_buf, stderr_buf = _CappedWriter(self.max_stdout_bytes), \
            _CappedWriter(self.max_stderr_bytes)
        try:
            with redirect_stdout(stdout_buf), redirect_stderr(stderr_buf):
                if command == protocol.CMD_CALL:
                    from . import serializer
                    args = [serializer.decode_obj(x, []) for x in data.get("args", [])]
                    kwargs = {k: serializer.decode_obj(v, [])
                              for k, v in (data.get("kwargs") or {}).items()}
                    result, err = self.call(
                        context_id, source, str(message.get("function", "")), args, kwargs)
                elif command == protocol.CMD_DEFINE:
                    result, err = self.define(context_id, source)
                else:  # CMD_RUN
                    from . import serializer
                    input_data = serializer.decode_obj(data.get("input"), [])
                    result, err = self.run(context_id, source, input_data)
        except Exception as exc:  # noqa: BLE001 - Infrastruktur-Fehler
            result, err = None, _error(type(exc).__name__, exc)

        body = {
            "status": "ok" if err is None else "error",
            "stdout": stdout_buf.getvalue(),
            "stderr": stderr_buf.getvalue(),
            "stdout_truncated": stdout_buf.overflowed,
            "stderr_truncated": stderr_buf.overflowed,
            "ms": _now_ms() - start_ms,
        }
        if err is not None:
            body["error"] = err
        else:
            body["data"] = result
        return body

    def consume_cancelled(self, task_id):
        if task_id in self.cancelled:
            self.cancelled.discard(task_id)
            return True
        return False

    def mark_cancelled(self, task_id):
        self.cancelled.add(task_id)


def _now_ms():
    import time
    return int(time.time() * 1000)