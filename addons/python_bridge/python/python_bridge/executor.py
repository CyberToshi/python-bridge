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
import threading
import traceback
from contextlib import redirect_stderr, redirect_stdout

from . import protocol

SYNTAX_FILENAME_PREFIX = "<bridge:"

# Fehlercode, wenn ein Call ohne source ankommt, die Context-Version aber
# nicht zum angegebenen source_hash passt (ScriptRegistry-Desync). Der
# Client soll daraufhin die Quelle einmalig (neu) senden.
SCRIPT_NOT_DEFINED = "ScriptNotDefined"

# Default output caps (bytes). Godot uebergibt die konfigurierten Werte beim
# Prozessstart (siehe bridge_instance.gd); diese Defaults gelten fuer den
# Standalone-Betrieb und die Tests.
DEFAULT_MAX_STDOUT_BYTES = 1024 * 1024
DEFAULT_MAX_STDERR_BYTES = 1024 * 1024

# Thread-lokal: die Job-ID des gerade in diesem Worker-Thread laufenden
# Tasks. Wird von execute_job gesetzt und von der kooperativen
# Cancellation-API (__bridge__.cancel_requested / checkpoint) gelesen.
_local = threading.local()


class _BridgeCancelled(Exception):
    """Internes Signal: Nutzer-Code hat per __bridge__.checkpoint() die
    kooperative Cancellation akzeptiert. Wird von execute_job in einen
    strukturierten status="cancelled" umgewandelt."""


class _BridgeHelpers:
    """Wird als ``__bridge__`` in jeden Context-Namespace injiziert.

    Kooperative Cancellation (Phase 3): langer Nutzer-Code kann an eigenen
    Checkpoints abbrechen statt den Slot dauerhaft zu blockieren:

        while not __bridge__.cancel_requested():
            do_work()

    oder einfach

        __bridge__.checkpoint()

    ``checkpoint()`` wirft, sobald der Client CANCEL gesendet hat; der Task
    endet dann strukturiert mit status="cancelled". Ohne Aufruf hilft die
    API nicht - ein Thread darf nie als sicher unterbrechbar gelten (der
    Watchdog/Neustart bleibt die letzte Massnahme).
    """

    __slots__ = ("host",)

    def __init__(self, host):
        self.host = host

    def cancel_requested(self):
        return self.host.cancel_requested_for_current()

    def checkpoint(self):
        if self.host.cancel_requested_for_current():
            raise _BridgeCancelled()

    def __repr__(self):  # pragma: no cover - Debug-Hilfe
        return "<python_bridge.__bridge__ cooperative cancel helper>"


class _ContextLocks:
    """Kontext-Locks fuer mehrere Worker-Threads (Phase 3).

    Ein Context darf nie gleichzeitig in zwei Workern ausgefuehrt werden
    (geteilter Namespace). acquire() nimmt mehrere Contexts in sortierter
    Reihenfolge, damit sich Batch-Jobs mit mehreren Contexts nicht
    gegenseitig verklemmten.
    """

    def __init__(self):
        self._guard = threading.Lock()
        self._locks = {}

    def _lock_for(self, context_id):
        with self._guard:
            lock = self._locks.get(context_id)
            if lock is None:
                lock = threading.Lock()
                self._locks[context_id] = lock
            return lock

    def acquire(self, context_ids):
        """Contextmanager: sperrt `context_ids` (sortiert, Deadlock-frei) und
        gibt sie am Ende in umgekehrter Reihenfolge frei."""
        ordered = sorted(set(context_ids))
        locks = [self._lock_for(c) for c in ordered]
        for lock in locks:
            lock.acquire()

        class _Releaser:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                for lock in reversed(locks):
                    lock.release()
                return False

        return _Releaser()


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
    """Persistenter Kontext eines Skripts in einer Python-Instanz.

    `namespace`   - ausgefuehrter Modul-Namespace (Funktionen, State)
    `source_hash` - SHA-256 des zuletzt definierten Sources
    `code`        - kompiliertes Code-Objekt des zuletzt definierten Sources
                    (Compile-Cache: run() fuehrt es erneut aus statt neu zu
                    kompilieren - A4)
    """

    __slots__ = ("namespace", "source_hash", "code")

    def __init__(self):
        self.namespace = {"__name__": "__pybridge__", "input": None}
        self.source_hash = None
        self.code = None


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
    """One per Python instance. Jobs koennen mit mehreren Worker-Threads
    laufen (workers_per_instance); Kontext-Zugaenge werden ueber
    _ContextLocks serialisiert, geteilte Zustandsdicts sind damit racefrei.
    Direkte Methodenaufrufe aus Tests (ein Thread) brauchen keine Locks."""

    def __init__(self, max_stdout_bytes=DEFAULT_MAX_STDOUT_BYTES,
                 max_stderr_bytes=DEFAULT_MAX_STDERR_BYTES):
        self.contexts = {}
        self.max_stdout_bytes = max_stdout_bytes
        self.max_stderr_bytes = max_stderr_bytes
        # Task-Ids, die der Client zu cancellen gebeten hat. Wird am Job-
        # Start konsumiert und von der kooperativen __bridge__-API
        # (cancel_requested/checkpoint) waehrend der Laufzeit geprueft.
        self.cancelled = set()
        self._cancel_lock = threading.Lock()
        self.context_locks = _ContextLocks()
        self._bridge = _BridgeHelpers(self)

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
            # Kooperative Cancellation-API in jeden Context-Namespace injizieren.
            ctx.namespace.setdefault("__bridge__", self._bridge)
            self.contexts[context_id] = ctx
        return ctx

    # -------------------------------------------------- Context-Locks (Worker)
    def acquire_contexts(self, context_ids):
        """Contextmanager: sperrt die Contexts (sortiert) fuer einen Job."""
        return self.context_locks.acquire(context_ids)

    @staticmethod
    def unique_contexts(message):
        """Alle Context-Ids, die ein Task-/Batch-Message beruehrt."""
        contexts = []
        if isinstance(message, dict):
            if message.get("context"):
                contexts.append(str(message["context"]))
            for item in (message.get(protocol.FIELD_ITEMS) or []):
                if isinstance(item, dict) and item.get("context"):
                    contexts.append(str(item["context"]))
        return contexts

    def _compile(self, context_id, source):
        """Compiles `source`. Returns (code, None) or (None, err); SyntaxError
        wird strukturiert gemeldet."""
        try:
            code = compile(source, SYNTAX_FILENAME_PREFIX + context_id + ">", "exec")
            return code, None
        except SyntaxError as exc:
            return None, _error("SyntaxError", exc)

    def _prepare(self, ctx, context_id, source, source_hash):
        """Stellt sicher, dass der Context den aktuellen Source enthaelt.

        Kompiliert nur, wenn der Context den Hash noch nicht kennt (Compile-
        Cache ueber ctx.code). Beim Kompilieren wird der Hash einmal gegen
        den tatsaechlichen Source verifiziert (kostet nur bei Aenderung,
        nie auf dem heissen Pfad) - ein falscher Client-Hash kann so keine
        stillschweigend falsche Code-Version erzeugen.
        """
        if ctx.source_hash == source_hash and ctx.code is not None:
            return ctx.code, None
        actual = _hash(source)
        if source_hash and actual != source_hash:
            return None, _error(
                "ProtocolError",
                "Source hash mismatch: client sent %s, computed %s"
                % (source_hash[:12], actual[:12]),
                code=protocol.CATEGORY_PROTOCOL_ERROR)
        code, err = self._compile(context_id, source)
        if err is not None:
            return None, err
        ctx.code = code
        ctx.source_hash = actual
        return code, None

    def _not_defined_error(self, context_id, source_hash):
        return _error(
            "ScriptNotDefined",
            "Context '%s' is not defined with source hash %s - resend the source"
            % (context_id, (source_hash or "")[:12]),
            code=protocol.CATEGORY_TASK_ERROR)

    # ------------------------------------------------------------------ API
    def define(self, context_id, source, source_hash=None):
        """Compiles and executes `source` in the context. Returns (result,
        error); result is None for define. `source_hash` ist der vom Client
        berechnete SHA-256; fehlt er, wird er hier bestimmt.

        Ohne inline source (ScriptRegistry: Context ist bereits mit diesem
        Hash definiert) ist define ein No-Op."""
        if source_hash is None:
            source_hash = _hash(source) if source else ""
        ctx = self._context(context_id)
        if not source:
            if ctx.source_hash == source_hash and ctx.code is not None:
                return None, None
            return None, self._not_defined_error(context_id, source_hash)
        ns = ctx.namespace
        code, err = self._prepare(ctx, context_id, source, source_hash)
        if err is not None:
            return None, err
        try:
            exec(code, ns)
        except _BridgeCancelled:  # kooperative Cancellation propagieren
            raise
        except Exception as exc:  # noqa: BLE001 - Nutzer-Code, strukturiert melden
            return None, _error(type(exc).__name__, exc)
        return None, None

    def run(self, context_id, source, input_data, source_hash=None):
        """Führt source aus (input/result-Konvention). Bei unveraendertem
        Source wird das kompilierte Code-Objekt wiederverwendet (kein
        erneutes compile()); ohne source wird nur ausgefuehrt, wenn die
        Context-Version zum source_hash passt."""
        ctx = self._context(context_id)
        ns = ctx.namespace
        if source_hash is None:
            source_hash = _hash(source)
        if not source:
            if ctx.source_hash != source_hash or ctx.code is None:
                return None, self._not_defined_error(context_id, source_hash)
            code = ctx.code
        else:
            code, err = self._prepare(ctx, context_id, source, source_hash)
            if err is not None:
                return None, err
        ns["input"] = input_data
        try:
            exec(code, ns)
        except _BridgeCancelled:  # kooperative Cancellation propagieren
            raise
        except Exception as exc:  # noqa: BLE001
            return None, _error(type(exc).__name__, exc)
        return ns.get("result"), None

    def call(self, context_id, source, function, args, kwargs, source_hash=None):
        """Ruft eine Funktion im Context auf. Enthaelt die Nachricht einen
        source, wird nur bei veraendertem Hash neu definiert. Ohne source
        wird direkt aufgerufen, wenn die Context-Version zum source_hash
        passt (ScriptRegistry); sonst SCRIPT_NOT_DEFINED."""
        ctx = self._context(context_id)
        if source_hash is None:
            source_hash = _hash(source) if source else ""
        if source:
            if ctx.source_hash != source_hash:
                _, err = self.define(context_id, source, source_hash)
                if err is not None:
                    return None, err
        else:
            if ctx.source_hash != source_hash or ctx.code is None:
                return None, self._not_defined_error(context_id, source_hash)
        ns = ctx.namespace
        fn = ns.get(function)
        if fn is None:
            return None, _error(
                "AttributeError",
                "Function '%s' is not defined in script context '%s'" % (function, context_id))
        try:
            result = fn(*args, **kwargs)
        except _BridgeCancelled:  # kooperative Cancellation propagieren
            raise
        except Exception as exc:  # noqa: BLE001
            return None, _error(type(exc).__name__, exc)
        return result, None

    def reload_context(self, context_id, source):
        """Invalidates the source hash and re-defines the context. Used by
        hot reload; other contexts and the process stay alive."""
        ctx = self._context(context_id)
        ctx.source_hash = None
        ctx.code = None
        return self.define(context_id, source)

    # ------------------------------------------------------------------ Jobs
    def execute_job(self, message):
        """Executes one task message. Returns a response body dict:
        {status: "ok"|"error"|"cancelled", data?, error?, stdout, stderr, ms}
        Runs in a worker thread; never touches asyncio objects. Setzt die
        thread-lokale Job-ID, damit die __bridge__-Cancellation-API den
        richtigen Task prueft."""
        start_ms = _now_ms()
        msg_id = str(message.get("id", ""))
        if self.consume_cancelled(msg_id):
            return self._cancelled_body(start_ms)

        _local.job_id = msg_id
        try:
            command = message.get("command", protocol.CMD_RUN)
            context_id = str(message.get("context", "anon"))
            source = str(message.get("source", ""))
            source_hash = message.get("source_hash")
            data = message.get("data") or {}

            stdout_buf, stderr_buf = _CappedWriter(self.max_stdout_bytes), \
                _CappedWriter(self.max_stderr_bytes)
            cancelled = False
            result, err = None, None
            try:
                with redirect_stdout(stdout_buf), redirect_stderr(stderr_buf):
                    if command == protocol.CMD_CALL:
                        from . import serializer
                        args = [serializer.decode_obj(x, []) for x in data.get("args", [])]
                        kwargs = {k: serializer.decode_obj(v, [])
                                  for k, v in (data.get("kwargs") or {}).items()}
                        result, err = self.call(
                            context_id, source, str(message.get("function", "")), args,
                            kwargs, source_hash=source_hash)
                    elif command == protocol.CMD_DEFINE:
                        result, err = self.define(context_id, source, source_hash=source_hash)
                    else:  # CMD_RUN
                        from . import serializer
                        input_data = serializer.decode_obj(data.get("input"), [])
                        result, err = self.run(
                            context_id, source, input_data, source_hash=source_hash)
            except _BridgeCancelled:
                cancelled = True
            except Exception as exc:  # noqa: BLE001 - Infrastruktur-Fehler
                result, err = None, _error(type(exc).__name__, exc)

            body = {
                "status": "cancelled" if cancelled else ("ok" if err is None else "error"),
                "stdout": stdout_buf.getvalue(),
                "stderr": stderr_buf.getvalue(),
                "stdout_truncated": stdout_buf.overflowed,
                "stderr_truncated": stderr_buf.overflowed,
                "ms": _now_ms() - start_ms,
            }
            if cancelled:
                body["error"] = {"code": protocol.CATEGORY_TASK_ERROR,
                                 "type": "CancelledError",
                                 "message": "Task cancelled (cooperative checkpoint)",
                                 "traceback": ""}
            elif err is not None:
                body["error"] = err
            else:
                body["data"] = result
            return body
        finally:
            _local.job_id = None

    @staticmethod
    def _cancelled_body(start_ms):
        return {
            "status": "cancelled",
            "error": {"code": protocol.CATEGORY_TASK_ERROR,
                      "type": "CancelledError",
                      "message": "Task cancelled", "traceback": ""},
            "stdout": "", "stderr": "", "ms": _now_ms() - start_ms,
        }

    def cancel_requested_for_current(self):
        """Kooperative Cancellation: True, wenn fuer den im aktuellen Worker-
        Thread laufenden Job ein CANCEL eingegangen ist (einmalig konsumiert)."""
        jid = getattr(_local, "job_id", None)
        if jid is None:
            return False
        with self._cancel_lock:
            if jid in self.cancelled:
                self.cancelled.discard(jid)
                return True
        return False

    def consume_cancelled(self, task_id):
        with self._cancel_lock:
            if task_id in self.cancelled:
                self.cancelled.discard(task_id)
                return True
        return False

    def mark_cancelled(self, task_id):
        with self._cancel_lock:
            self.cancelled.add(task_id)


def _now_ms():
    import time
    return int(time.time() * 1000)