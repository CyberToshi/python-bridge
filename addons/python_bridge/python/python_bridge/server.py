"""WebSocket-Server, eine Instanz = ein Prozess = eine ScriptHost.

Jede Python-Instanz führt einen eigenen Server aus. Godot liest Port+PID aus
einer Tmp-Datei, verbindet sich und sendet Requests (`execute`, `ping`,
`shutdown`). Antworten werden über dasselbe `id`-Feld zugeordnet.
"""
import asyncio
import json
import os
import sys
import traceback

import websockets

from . import protocol, executor

VERSION = "0.1.0"


def _result_message(msg_id, status, data=None, error=None, ms=0):
    msg = {"v": protocol.PROTOCOL_VERSION, "type": "response",
           "id": msg_id, "status": status, "ms": ms}
    if status == "ok":
        msg["data"] = data
    else:
        msg["error"] = error
    return msg


async def _route(ws, host, message, data):
    mtype = message.get("type")
    msg_id = message.get("id")

    if mtype == "ping":
        await ws.send(protocol.build_text(
            {"v": protocol.PROTOCOL_VERSION, "type": "pong", "id": msg_id}))
        return

    if mtype == "hello":
        await ws.send(protocol.build_text({
            "v": protocol.PROTOCOL_VERSION, "type": "hello_ack", "id": msg_id,
            "pid": os.getpid(), "bridge_version": VERSION}))
        return

    if mtype == "shutdown":
        await ws.send(protocol.build_text(
            _result_message(msg_id, "ok", data="bye")))
        raise SystemExit(0)

    if mtype == "execute":
        context_id = message.get("context", "anon")
        source = message.get("source", "")
        command = message.get("command", "run")
        try:
            from . import serializer

            if command == "call":
                args = [serializer.decode_obj(x, []) for x in message.get("args", [])]
                kwargs = {
                    k: serializer.decode_obj(v, [])
                    for k, v in (message.get("kwargs") or {}).items()
                }
                result, err = host.call(context_id, source,
                                        message.get("function", ""), args, kwargs)
            else:
                input_data = serializer.decode_obj(message.get("input"), [])
                result, err = host.run(context_id, source, input_data)
        except Exception as exc:  # Infrastruktur-Fehler (nicht Nutzer-Code)
            result, err = None, {
                "type": type(exc).__name__, "message": str(exc),
                "traceback": traceback.format_exc(),
            }

        if err is not None:
            await ws.send(protocol.build_text(_result_message(msg_id, "error", error=err)))
        else:
            chunks = []
            from . import serializer
            encoded = serializer.encode_obj(result, chunks)
            head = _result_message(msg_id, "ok", data=encoded, ms=0)
            if chunks:
                header = json.dumps(head)
                await ws.send(protocol.build_binary(header, chunks))
            else:
                await ws.send(protocol.build_text(head))
        return

    await ws.send(protocol.build_text(_result_message(
        msg_id, "error",
        error={"type": "ProtocolError",
               "message": "Unbekannter Typ: %s" % mtype, "traceback": ""})))


async def _handle_connection(ws):
    host = executor.ScriptHost()
    async for raw in ws:
        message, data = protocol.parse(raw)
        await _route(ws, host, message, data)


async def run(host, port, tmpdir, tag):
    """Bind, Port+PID in Tmp-Datei schreiben, serven."""
    async def _serve():
        # Der Godot-Client fordert den Sub-Protokoll-Header an
        # (WebSocketPeer.supported_protocols). Der Server muss ihn im
        # Handshake zurueckgeben, sonst bricht Godot die Verbindung ab.
        server = await websockets.serve(
            _handle_connection, host, port,
            max_size=512 * 1024 * 1024,
            subprotocols=["pybridge-v%d" % protocol.PROTOCOL_VERSION])
        real_port = server.sockets[0].getsockname()[1]
        _write_tmp(tmpdir, tag, real_port, os.getpid())
        print("[python_bridge] %s hört auf ws://127.0.0.1:%d (pid=%d)" %
              (tag, real_port, os.getpid()), flush=True)
        await server.wait_closed()

    try:
        await _serve()
    except (SystemExit, KeyboardInterrupt):
        pass
    finally:
        os._exit(0)


def _write_tmp(tmpdir, tag, port, pid):
    os.makedirs(tmpdir, exist_ok=True)
    path = os.path.join(tmpdir, "%s.json" % tag)
    with open(path, "w") as f:
        json.dump({"port": port, "pid": pid}, f)