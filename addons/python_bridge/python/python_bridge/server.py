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
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from functools import partial

try:
    import websockets
except ImportError:  # Browser-Runtime (Pyodide): server.py wird dort durch
    websockets = None  # browser_host.py ersetzt; der Import darf nicht brechen.

from . import protocol, executor, introspection
from .data_registry import DataStore, cleanup_orphan_files
from .serializer import encode_obj

VERSION = "0.3.2"

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


def _server_log(message):
    """Lifecycle-/Fatal-Logging des Servers, direkt auf fd 2.

    Grund: Ein laufender Task redirectet sys.stdout UND sys.stderr
    PROZESSWEIT (contextlib.redirect_stdout/redirect_stderr in execute_job,
    Worker-Thread). Prints ueber die sys-Objekte landen dann im Capped-
    Buffer des Tasks und verschwinden - genau die Meldungen, die man beim
    Shutdown/Absturz braucht (Exit-Code, Watchdog, Fatal). os.write(2)
    umgeht alle Python-Objekt-Redirects (nur die Objekte, nie die FDs
    werden getauscht) und alle Puffer vor os._exit.
    """
    try:
        os.write(2, (str(message).rstrip("\n") + "\n").encode("utf-8", "replace"))
    except Exception:  # pragma: no cover - fd 2 kaputt: nichts zu retten
        pass


async def _drain_queue_for_shutdown(queue, send_fn):
    """4.2: Leert die Job-Queue nach dem Shutdown-Signal und antwortet jedem
    wartenden Task mit einer strukturierten task_error, statt Jobs still zu
    verwerfen (frueher: Antwort-Timeout auf Godot-Seite ohne Diagnose).

    send_fn(body) darf sync oder async sein; Ausnahmen (bereits geschlossene
    Verbindung) werden bewusst verschluckt - best effort, der Drain darf
    nie an der Verbindung scheitern. Als Modulfunktion statt Closure, damit
    das Verhalten unit-testbar ist.
    """
    while True:
        try:
            message = queue.get_nowait()
        except asyncio.QueueEmpty:
            return
        body = _task_error_body(
            str(message.get("id", "")),
            protocol.CATEGORY_CONNECTION_ERROR,
            "Bridge server is shutting down; task was not executed")
        try:
            result = send_fn(body)
            if asyncio.iscoroutine(result) or asyncio.isfuture(result):
                await result
        except Exception:
            pass


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
    # Phase 4: grosse Datenrefs zusaetzlich als Datei ablegen (Godot liest
    # sie chunkweise per FileAccess, ohne WebSocket-Transfer). Dateinamen
    # sind pro Instanz-Tag eindeutig; Verzeichnis liegt im Instanz-Tmpdir.
    file_dir = os.path.join(str(state.get("tmpdir", "")), "data")
    data_store = DataStore(
        int(caps.get("data_ref_threshold_bytes", 0) or 0),
        file_dir=file_dir if state.get("tmpdir") else None,
        tag=str(state.get("tag", "")))
    # Phase 3: mehrere Worker-Slots pro Instanz. Tasks unterschiedlicher
    # Contexts koennen parallel laufen (I/O, NumPy); gleiche Contexts werden
    # ueber Context-Locks serialisiert. Default 1 = bisherige Semantik.
    workers = max(1, int(caps.get("workers_per_instance", 1) or 1))
    runaway_grace_ms = max(0, int(caps.get("runaway_grace_ms", 10000) or 0))
    executor_pool = ThreadPoolExecutor(max_workers=workers)
    job_queue = asyncio.Queue()
    send_lock = asyncio.Lock()
    loop = asyncio.get_running_loop()
    # Watchdog: futures, deren Job per Timeout abgebrochen wurde, aber deren
    # Worker-Thread tatsaechlich weiterlaeuft (nicht killbar). Laeuft die
    # Frist (runaway_grace_ms) ab, wird der Prozess beendet - Godot startet
    # ihn ueber die bestehende Restart-Policy neu.
    stuck = {}  # future -> monotonic deadline

    state["connections"] += 1
    try:
        async def _consumer():
            """Ein Consumer pro Worker-Slot: holt Jobs aus der Queue, laesst
            sie (context-gesperrt) im Pool laufen und antwortet.

            Nach dem Shutdown-Signal werden verbleibende Queue-Jobs nicht
            mehr still verworfen (4.2): Jeder wartende Task bekommt sofort
            eine strukturierte task_error-Antwort, statt bis zum Godot-
            Timeout auf ein Ergebnis zu warten. Sends an eine bereits
            geschlossene Verbindung werden abgefangen (best effort) - die
            Antwort moeglichst rausschicken, aber nie crashen.
            """
            while True:
                if state["shutdown"]:
                    # 4.2: Geordnetes Leeren statt stummem Verwerfen - jede
                    # wartende Task bekommt eine sofortige, strukturierte
                    # Antwort (kein Timeout-Raten auf Godot-Seite).
                    await _drain_queue_for_shutdown(
                        job_queue, lambda body: _send_text(ws, send_lock, body))
                    return
                message = await job_queue.get()
                if state["shutdown"]:
                    # Deckt beide Reihenfolgen ab: shutdown vor dem get()
                    # (Message lag schon in der Queue) und shutdown, das
                    # zwischen put und get eintrifft. Antwort best effort,
                    # danach leert der Kopf der Schleife den Rest.
                    try:
                        await _send_text(ws, send_lock, _task_error_body(
                            str(message.get("id", "")),
                            protocol.CATEGORY_CONNECTION_ERROR,
                            "Bridge server is shutting down; "
                            "task was not executed"))
                    except Exception:
                        pass
                    continue
                if message.get("type") == protocol.MSG_DATA_GET:
                    await _run_data_get(ws, send_lock, loop, executor_pool,
                                        data_store, message, max_result_bytes)
                else:
                    await _run_job(ws, send_lock, loop, executor_pool, host,
                                   data_store, message, max_result_bytes,
                                   stuck, runaway_grace_ms)


        worker_tasks = [asyncio.create_task(_consumer()) for _ in range(workers)]

        async def _watchdog():
            """Beendet den Prozess, wenn ein per Timeout abgebrochener Job
            nach der Grace-Frist immer noch rechnet (Kill-on-Runaway)."""
            while not state["shutdown"]:
                await asyncio.sleep(0.2)
                now = loop.time()
                doomed = False
                for fut, deadline in list(stuck.items()):
                    if fut.done():
                        stuck.pop(fut, None)
                    elif now > deadline:
                        doomed = True
                if doomed:
                    _server_log("[python_bridge] runaway worker detected - "
                                "terminating process (restart via bridge policy)")
                    os._exit(1)

        watchdog_task = asyncio.create_task(_watchdog())

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
                    # Nachtrag zur Kapsel-Semantik: CONNECT-time Caps (state
                    #["caps"]) konfigurieren die Runtime final (DataStore,
                    # max_result_bytes, workers, runaway_grace_ms sind dort
                    # bereits an lokale Variablen gebunden). Im HELLO werden
                    # NUR installed_dependencies nachgezogen - alles andere
                    # hier wuerde stumm ignoriert. (CLI-Args sind die Quelle
                    # fuer Runtime-Tunables; HELLO-Caps nur fuer Dep-Listen.)
                    caps = message.get("caps") if isinstance(message.get("caps"), dict) else {}
                    installed = caps.get("installed_dependencies")
                    if isinstance(installed, list):
                        host.installed_dependencies = [
                            str(d).strip().lower() for d in installed if str(d).strip()]
                    await _send_text(ws, send_lock, {
                        "v": protocol.PROTOCOL_VERSION,
                        "type": protocol.MSG_HELLO_ACK,
                        "id": msg_id,
                        "pid": os.getpid(),
                        "bridge_version": VERSION,
                        "installed_dependencies": list(host.installed_dependencies),
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
                elif mtype == protocol.MSG_DATA_GET:
                    # Grosses Ergebnis: im Worker materialisieren (kein
                    # Blockieren des Event-Loops durch tobytes()/Chunks).
                    await job_queue.put(message)
                elif mtype == protocol.MSG_DATA_RELEASE:
                    freed = data_store.release(str(message.get("ref_id", "")))
                    await _send_text(ws, send_lock, {
                        "v": protocol.PROTOCOL_VERSION,
                        "type": protocol.MSG_DATA_ACK,
                        "id": msg_id,
                        "ref_id": message.get("ref_id", ""),
                        "status": "ok",
                        "freed": freed,
                    })
                elif mtype == protocol.MSG_SHUTDOWN:
                    await _send_text(ws, send_lock, {
                        "v": protocol.PROTOCOL_VERSION,
                        "type": protocol.MSG_SHUTDOWN_ACK,
                        "id": msg_id,
                        "status": "ok",
                    })
                    state["shutdown"] = True
                    # 4.2: Drain VOR dem ws.close() - nur so sind die
                    # Antworten auf wartende Tasks noch zustellbar. Nach dem
                    # Close wuerde jede Sendung ins Leere laufen (deshalb
                    # geschieht das bewusst hier, nicht im finally). In-flight
                    # Jobs koennen technisch nicht gewartet werden (kein kill-
                    # fähiger Thread); ihr Ergebnis nach dem Close ist
                    # verloren - dokumentierte Grenze.
                    await _drain_queue_for_shutdown(
                        job_queue, lambda body: _send_text(ws, send_lock, body))
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
            for task in worker_tasks:
                task.cancel()
            for task in worker_tasks:
                try:
                    await task
                except asyncio.CancelledError:
                    pass
                except Exception as exc:  # noqa: BLE001
                    # Ein Consumer, der nach dem Close noch senden wollte
                    # (in-flight Ergebnis), stirbt mit ConnectionClosed -
                    # das ist im Finally erwartbar und darf den Abbruch
                    # nicht maskieren. Sichtbar geloggt statt still.
                    print("[python_bridge] worker task ended: %s" % exc,
                          flush=True)
            watchdog_task.cancel()
            try:
                await watchdog_task
            except asyncio.CancelledError:
                pass
            executor_pool.shutdown(wait=False, cancel_futures=True)
    finally:
        # Verbindungsende: alle gehaltenen grossen Datensaetze freigeben
        # (Crash-/Zombie-Cleanup; der Prozess lebt nach der Grace-Periode
        # ohnehin nicht weiter, aber ein Reconnect-Fenster soll nicht die
        # Daten zweier Verbindungen stapeln).
        data_store.clear()
        state["connections"] -= 1


def _normalize_installed_dependencies(value):
    """Normalisiert die HELLO-Kappe `installed_dependencies` zu einer Liste
    kleingeschriebener Distributionsnamen (Desktop-Provisioner-Ergebnis)."""
    if not isinstance(value, list):
        return []
    return [str(d).strip().lower() for d in value if str(d).strip()]


def _deps_from_message(message):
    """Alle per ``__bridge_deps__`` deklarierten Pakete einer Task-/Batch-
    Message (aus dem.executor-Meta, das beim Compile ermittelt wurde)."""
    if not isinstance(message, dict):
        return []
    deps = []
    meta = message.get("deps")
    if isinstance(meta, list):
        deps.extend(str(d) for d in meta if str(d).strip())
    for item in (message.get(protocol.FIELD_ITEMS) or []):
        if isinstance(item, dict) and isinstance(item.get("deps"), list):
            deps.extend(str(d) for d in item["deps"] if str(d).strip())
    return deps


def _ensure_script_dependencies(host, message):
    """Installiert fehlende Skript-Dependencies in der laufenden venv.

    Wird pro Task-/Batch-Message im Worker-Thread aufgerufen. Ohne fehlende
    Pakete ist es ein No-Op (ein Set-Vergleich). Mit fehlenden Paketen
    laeuft ein einzelner `pip install` fuer alle fehlenden Specs gleichzeitig;
    schlaegt er fehl, entsteht ein strukturierter DependencyError.

    Returns (ok, error_message)."""
    declared = _deps_from_message(message)
    if not declared:
        return True, ""
    missing = []
    for spec in declared:
        if not executor._dependency_available(spec, host.installed_dependencies):
            missing.append(spec)
    if not missing:
        return True, ""
    venv_py = _venv_python_from_host(host)
    if venv_py == "":
        return False, (
            "Script requires missing packages: %s (no local Python process "
            "available to install them - on web use web_packages)."
            % ", ".join(missing))
    import subprocess
    cmd = [venv_py, "-m", "pip", "install", "--disable-pip-version-check",
           "--no-input", "-q", *missing]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout or "").strip()[-400:]
            return False, (
                "pip install failed for %s: %s"
                % (", ".join(missing), tail or "exit code %d" % proc.returncode))
    except subprocess.TimeoutExpired:
        return False, "pip install timed out for: %s" % ", ".join(missing)
    except OSError as exc:
        return False, "pip install failed to start: %s" % exc
    for spec in missing:
        name = str(spec).split("==")[0].split(">=")[0].split("<")[0].strip().lower()
        if name and name not in host.installed_dependencies:
            host.installed_dependencies.append(name)
    return True, ""


def _venv_python_from_host(host):
    """Python-Interpreter des laufenden Serverprozesses (der Server laeuft
    in der venv, sys.executable reicht also)."""
    exe = getattr(sys, "executable", "")
    return exe if exe and os.path.exists(exe) else ""


def _ref_or_encode(value, data_store, chunks, result_budget=None):
    """Wendet die Auto-DataRef-Schwelle an: grosse numpy-Ergebnisse werden
    als Handle abgelegt und der Descriptor gesendet, alles andere normal
    (und ggf. mit Binary-Chunks) kodiert.

    Budget-Check VOR dem Encoding (2.7): Eine billige Groessen-Schaetzung
    verhindert, dass ein uebergrosses Ergebnis erst komplett serialisiert
    (2-3x Speicherkopien) und erst danach abgelehnt wird - im Browser
    (WASM-Heap) ist genau dieser Moment OOM-Tod statt sauberer Fehler.
    Der nachgelagerte _frame_size-Check bleibt als Backstop.
    """
    ref = data_store.maybe_ref(value)
    if ref is not None:
        return ref
    if result_budget is not None and result_budget > 0:
        estimated = _estimated_size(value)
        if estimated > result_budget:
            raise ResultTooLargeError(
                "Task result (~%d bytes estimated) exceeds max_result_bytes "
                "(%d); refused before encoding" % (estimated, result_budget))
    return _encode_with_chunks(value, chunks)


# 2.7-Konstanten: Knoten-Budget begrenzt die Traversierung (Schutz vor
# Algorithmus-DOS durch riesige, tief verschachtelte Strukturen), der
# Basis-Overhead pro Objekt kompensiert, dass JSON kleine Objekte (Keys,
# Struktur) unterschaetzen wuerde.
_ESTIMATE_NODE_BUDGET = 100_000
_ESTIMATE_OVERHEAD_PER_NODE = 64


class ResultTooLargeError(Exception):
    """Ergebnis ueberschreitet max_result_bytes (vor dem Encoding erkannt)."""


def _estimated_size(value) -> int:
    """Billige obere Groessen-Schaetzung in Bytes, VOR dem Encoding.

    Exakt fuer ndarray (nbytes) und bytes; grob fuer Strukturen (len +
    Rekurs über Elemente). Iterativ mit Stack UND Knoten-Budget: Python-
    Dicts koennen Zyklen enthalten - eine naive Rekursion stuerzt mit
    RecursionError ab oder haengt. Budget erschöpft -> Teilbaum wird
    ignoriert (Unterschaetzung, der Backstop _frame_size bleibt).
    """
    total = 0
    budget = _ESTIMATE_NODE_BUDGET
    stack = [value]
    while stack:
        if budget <= 0:
            break
        budget -= 1
        cur = stack.pop()
        np = None
        if isinstance(cur, (list, tuple, set, frozenset, dict)):
            total += _ESTIMATE_OVERHEAD_PER_NODE + 8 * len(cur)
            if isinstance(cur, dict):
                stack.extend(cur.keys())
                stack.extend(cur.values())
            else:
                stack.extend(cur)
            continue
        if isinstance(cur, (bytes, bytearray)):
            total += len(cur) + _ESTIMATE_OVERHEAD_PER_NODE
            continue
        if isinstance(cur, str):
            # JSON/UTF-8: bis zu 4 Bytes pro Zeichen; wir schaetzen konservativ
            # grob (ASCII-Annahme). Unterschaetzung faengt der Backstop ab.
            total += len(cur) + _ESTIMATE_OVERHEAD_PER_NODE
            continue
        if isinstance(cur, (int, float, bool, type(None))):
            total += _ESTIMATE_OVERHEAD_PER_NODE
            continue
        np = _try_numpy()
        if np is not None and isinstance(cur, np.ndarray):
            # Exakt: das ist der teuerste Fall, den wir unbedingt VOR dem
            # Encoding erkennen wollen (tobytes()-Kopie).
            total += int(cur.nbytes) + _ESTIMATE_OVERHEAD_PER_NODE
            continue
        # Fremdes Objekt: keine Struktur-Analyse (zu teuer/unsicher).
        total += _ESTIMATE_OVERHEAD_PER_NODE
    return total



def _try_numpy():
    """NumPy optional & einmalig geprueft (siehe serializer._try_numpy)."""
    global _NUMPY_MOD, _NUMPY_CHECKED
    if not _NUMPY_CHECKED:
        _NUMPY_CHECKED = True
        try:
            import numpy as _np
            _NUMPY_MOD = _np
        except Exception:
            _NUMPY_MOD = None
    return _NUMPY_MOD


_NUMPY_MOD = None
_NUMPY_CHECKED = False


def _job_fn(host, data_store, message, max_result_bytes=0):
    """Fuehrt eine Task-/Batch-Message unter den Context-Locks aus UND kodiert
    das Ergebnis (inkl. Auto-DataRef-/Datei-Entscheidung) im Worker-Thread.
    Damit blockieren grosse tobytes()-/Datei-Schreibvorgaenge nie den
    Event-Loop (Phase 4).

    max_result_bytes: Budget-Vorab-Check vor dem Encoding (2.7). 0 = aus.
    """
    with host.acquire_contexts(host.unique_contexts(message)):
        # Script-declared dependencies (``__bridge_deps__ = [...]``): install
        # them in the running venv and retry once when they became available.
        # With up-to-date deps this is a no-op (empty missing set).
        deps_ok, deps_error = _ensure_script_dependencies(host, message)
        if not deps_ok:
            msg_id = str(message.get("id", ""))
            err = {"code": protocol.CATEGORY_DEPENDENCY_ERROR,
                   "type": "DependencyError", "message": deps_error,
                   "traceback": ""}
            if message.get("type") == protocol.MSG_BATCH:
                return {"batch": True, "msg_id": msg_id,
                        "items": [{"id": str(i.get("id", "")), "status": "error",
                                   "error": err} for i in message.get(protocol.FIELD_ITEMS, [])],
                        "chunks": []}
            return {"batch": False,
                    "body": {"status": "error", "error": err, "ms": 0,
                             "stdout": "", "stderr": ""},
                    "chunks": []}
        if message.get("type") == protocol.MSG_BATCH:
            chunks = []
            out_items = []
            for item in message.get(protocol.FIELD_ITEMS, []):
                body = host.execute_job(item)
                item_id = str(item.get("id", ""))
                entry = {"id": item_id, "ms": body["ms"],
                         "stdout": body.get("stdout", ""),
                         "stderr": body.get("stderr", ""),
                         "stdout_truncated": bool(body.get("stdout_truncated", False)),
                         "stderr_truncated": bool(body.get("stderr_truncated", False))}
                if body["status"] == "ok":
                    entry["status"] = "ok"
                    try:
                        entry["data"] = _ref_or_encode(
                            body["data"], data_store, chunks, result_budget=max_result_bytes)
                    except ResultTooLargeError as exc:
                        # Pro Item abfangen: ein uebergrosses Item soll nicht
                        # die ganze Batch verwerten.
                        entry["status"] = "error"
                        entry["error"] = {
                            "code": protocol.CATEGORY_SERIALIZATION_ERROR,
                            "type": "ResultTooLargeError",
                            "message": str(exc), "traceback": ""}
                else:
                    entry["status"] = "error"
                    entry["error"] = body.get("error") or {
                        "code": protocol.CATEGORY_TASK_ERROR,
                        "type": "Error", "message": "unknown", "traceback": ""}
                out_items.append(entry)
            return {"batch": True, "msg_id": str(message.get("id", "")),
                    "items": out_items, "chunks": chunks}
        body = host.execute_job(message)
        chunks = []
        if body["status"] == "ok":
            try:
                body["data"] = _ref_or_encode(
                    body["data"], data_store, chunks, result_budget=max_result_bytes)
            except ResultTooLargeError as exc:
                # Bewusst HIER gefangen (nicht im _run_job-Task): eine
                # unbehandelte Exception im Worker wuerde die Antwort komplett
                # verschwinden lassen - Godot laeuft ins Timeout. So kommt
                # eine sofortige strukturierte task_error.
                body = {"status": "error", "ms": body["ms"],
                        "stdout": body.get("stdout", ""),
                        "stderr": body.get("stderr", ""),
                        "stdout_truncated": bool(body.get("stdout_truncated", False)),
                        "stderr_truncated": bool(body.get("stderr_truncated", False)),
                        "error": {"code": protocol.CATEGORY_SERIALIZATION_ERROR,
                                  "type": "ResultTooLargeError",
                                  "message": str(exc), "traceback": ""}}
        return {"batch": False, "body": body, "chunks": chunks}


def _register_stuck(stuck, future, loop, runaway_grace_ms):
    """Merkt einen weiterlaufenden (nicht killbaren) Job fuer den Watchdog."""
    if runaway_grace_ms > 0 and not future.done():
        stuck[future] = loop.time() + runaway_grace_ms / 1000.0


async def _run_job(ws, send_lock, loop, executor_pool, host, data_store, message,
                   max_result_bytes, stuck, runaway_grace_ms):
    """Runs one task or batch message in the worker thread and responds.
    Das Ergebnis kommt bereits kodiert (data/chunks) aus dem Worker zurueck."""
    msg_id = str(message.get("id", ""))
    timeout_ms = int(message.get("timeout_ms", 0) or 0)
    timeout = timeout_ms / 1000.0 if timeout_ms > 0 else None

    future = loop.run_in_executor(executor_pool, _job_fn, host, data_store,
                                  message, max_result_bytes)
    try:
        # shield: wait_for darf das Future NICHT canceln - der Watchdog
        # muss den weiterlaufenden (nicht killbaren) Thread erkennen.
        result = await asyncio.wait_for(asyncio.shield(future), timeout)
    except asyncio.TimeoutError:
        _register_stuck(stuck, future, loop, runaway_grace_ms)
        await _send_text(ws, send_lock, _task_error_body(
            msg_id, protocol.CATEGORY_TIMEOUT_ERROR,
            "Task timeout after %d ms" % timeout_ms))
        return

    chunks = result.get("chunks", [])
    if result.get("batch"):
        head = {"v": protocol.PROTOCOL_VERSION, "type": protocol.MSG_BATCH_RESULT,
                "id": msg_id, "items": result["items"]}
    else:
        body = result["body"]
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


async def _run_data_get(ws, send_lock, loop, executor_pool, data_store, message,
                        max_result_bytes):
    """Materialisiert einen DataRef-Handle: holt den gespeicherten Wert aus
    dem Store und sendet ihn als normale (binär-chunked) Antwort. Die
    Auto-Ref-Schwelle gilt hier bewusst NICHT - Materialisieren muss immer
    die echten Daten liefern, nie einen weiteren Handle."""
    msg_id = str(message.get("id", ""))
    ref_id = str(message.get("ref_id", ""))

    def _prepare():
        value, _meta = data_store.get(ref_id)
        if value is None:
            return None, None
        # Phase 4 (file-backed): auf Wunsch nur den Datei-Descriptor senden -
        # Godot liest die Rohbytes chunkweise per FileAccess, ohne
        # WebSocket-Transfer. Fehlt die Datei, Fallback auf normalen Transfer.
        if message.get("want") == "file":
            info = data_store.file_info(ref_id)
            if info is not None:
                return {"transport": "file", "path": info["path"],
                        "nbytes": info["size"], "dtype": info["dtype"],
                        "shape": info["shape"], "sha256": info["sha256"]}, None
        chunks = []
        encoded = _encode_with_chunks(value, chunks)
        return encoded, chunks

    def _error_body(code, text):
        return {
            "v": protocol.PROTOCOL_VERSION,
            "type": protocol.MSG_DATA_RESULT,
            "id": msg_id,
            "ref_id": ref_id,
            "status": "error",
            "error": {"code": code, "type": "DataHandleError",
                      "message": text, "traceback": ""},
        }

    try:
        encoded, chunks = await asyncio.wait_for(
            loop.run_in_executor(executor_pool, _prepare), 60.0)
    except asyncio.TimeoutError:
        await _send_text(ws, send_lock, _error_body(
            protocol.CATEGORY_TIMEOUT_ERROR,
            "Data materialization timeout for %s" % ref_id))
        return
    if encoded is None:
        await _send_text(ws, send_lock, _error_body(
            protocol.CATEGORY_TASK_ERROR,
            "Data handle '%s' is stale or was released" % ref_id))
        return
    head = {
        "v": protocol.PROTOCOL_VERSION,
        "type": protocol.MSG_DATA_RESULT,
        "id": msg_id,
        "ref_id": ref_id,
        "status": "ok",
        "data": encoded,
    }
    # Datei-Modus: Descriptor ohne Chunks - direkt als Text senden.
    if chunks is None:
        await _send_text(ws, send_lock, head)
        return
    if _frame_size(json.dumps(head), chunks) > max_result_bytes:
        await _send_text(ws, send_lock, _error_body(
            protocol.CATEGORY_SERIALIZATION_ERROR,
            "Data result exceeds max_result_bytes (%d)" % max_result_bytes))
        return
    if chunks:
        await _send_frame(ws, send_lock, protocol.build_binary(
            json.dumps(head), chunks))
    else:
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


def _exit_code_for(exc) -> int:
    """4.3: Exit-Code der Server-Beendigung.

    SystemExit/KeyboardInterrupt/kein Fehler gelten als geordnete Beendigung
    (0); jede andere Exception ist ein echter Fehler (1) - Godots Restart-
    Policy kann darauf reagieren, statt einen defekten Server fuer 'gesund'
    zu halten. Eigene Funktion (statt Inline-Logik), damit sie unit-testbar
    ist - os._exit laesst sich im Test nicht auffangen.
    """
    if exc is None:
        return 0
    if isinstance(exc, (SystemExit, KeyboardInterrupt, asyncio.CancelledError)):
        return 0
    return 1


async def run(host, port, tmpdir, tag, caps=None):
    """Bind, write port+pid tmp file, serve; exit when shutdown requested or
    after the connection dropped (no zombies). `caps` ist ein optionales
    Dict mit max_stdout_bytes / max_stderr_bytes / max_result_bytes."""
    state = {"shutdown": False, "connections": 0, "caps": caps or {},
             "tmpdir": tmpdir, "tag": tag}
    # Crash-Cleanup: verwaiste Daten-Dateien dieser Instanz aus frueheren
    # Prozessen entfernen (Dateien bleiben sonst nach einem Crash liegen).
    removed = cleanup_orphan_files(os.path.join(tmpdir, "data"), tag)
    if removed:
        print("[python_bridge] cleaned up %d orphan data file(s)" % removed,
              flush=True)

    async def _serve():
        if websockets is None:
            raise RuntimeError(
                "Das Paket 'websockets' fehlt. Der Desktop-Server benoetigt es"
                " (pip install websockets). Im Browser laeuft stattdessen"
                " python_bridge.browser_host.")
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

    exit_code = 0
    try:
        await _serve()
    except (SystemExit, KeyboardInterrupt):
        pass
    except BaseException as exc:
        # 4.3: Server-Fehler duerfen nicht als sauberer Exit 0 verschwinden
        # (frueher: RuntimeError "websockets fehlt" sah aus wie geordnete
        # Beendigung). _server_log (fd 2) VOR dem os._exit: sys.stdout UND
        # sys.stderr koennen durch redirect_stdout/redirect_stderr eines
        # in-flight Tasks blockiert sein - fd 2 immer frei.
        _server_log(traceback.format_exc())
        _server_log("[python_bridge] server fatal: %s: %s"
                    % (type(exc).__name__, exc))
        exit_code = _exit_code_for(exc)
    finally:
        # Force-exit: guarantees no lingering process even if a worker
        # thread is stuck in user code (which cannot be killed safely).
        _server_log("[python_bridge] server exits (code=%d)" % exit_code)
        os._exit(exit_code)


def _write_tmp(tmpdir, tag, port, pid):
    """Port+PID atomar schreiben - Windows-hartening.

    os.replace kann auf Windows transiente PermissionError werfen, wenn der
    Leser (Godot STARTING-Poll) die Zieldatei genau im Replace-Moment offen
    hat (Sharing-Violation); POSIX ersetzt in dem Fall einfach. Deshalb:
    kurzer Retry mit Backoff, danach Fallback direkt in die Zieldatei
    (Kleinschreibvorgang; der Poll liest ohnehin erst nach der Port-
    Ausgabe - "listens on" kommt nach diesem Schreibvorgang)."""
    os.makedirs(tmpdir, exist_ok=True)
    path = os.path.join(tmpdir, "%s.json" % tag)
    tmp = path + ".tmp"
    payload = json.dumps({"port": port, "pid": pid})
    last_exc = None
    for attempt in range(5):
        with open(tmp, "w") as f:
            json.dump({"port": port, "pid": pid}, f)
        try:
            os.replace(tmp, path)
            return
        except PermissionError as exc:  # Windows Sharing-Violation
            last_exc = exc
            time.sleep(0.05 * (attempt + 1))
    # Fallback: direkt schreiben (klein, schnell; Risiko eines halben JSON
    # ist hier akzeptabel klein - Godot wiederholt den STARTING-Poll).
    try:
        with open(path, "w") as f:
            f.write(payload)
    except Exception:
        raise last_exc