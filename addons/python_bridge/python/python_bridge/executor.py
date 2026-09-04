"""Skript-Kontexte: persistente Namespaces pro context_id.

Jeder `context_id` gehört ein eigener Namespace. So können mehrere Skripte
(Funktionen, Imports, Zwischenzustände) dauerhaft in derselben Instanz leben,
ohne sich zu überschreiben. Temporäre Skripte verwenden Wegwerf-IDs.
"""
import traceback


class ScriptContext:
    __slots__ = ("namespace",)

    def __init__(self):
        # "input" und "result" sind die Konvention des Tools:
        # Godot legt Eingaben unter "input" ab, Ergebnis liest es aus "result".
        self.namespace = {"__name__": "__pybridge__", "input": None}


class ScriptHost:
    def __init__(self):
        self.contexts = {}

    def _context(self, context_id):
        ctx = self.contexts.get(context_id)
        if ctx is None:
            ctx = ScriptContext()
            self.contexts[context_id] = ctx
        return ctx

    def run(self, context_id, source, input_data):
        """Führt source im (persistenten) Kontext aus; liefert (result, error)."""
        ctx = self._context(context_id)
        ns = ctx.namespace
        ns["input"] = input_data
        try:
            code = compile(source, "<bridge:%s>" % context_id, "exec")
        except SyntaxError as exc:
            return None, _error("SyntaxError", exc)
        try:
            exec(code, ns)
        except Exception as exc:  # noqa: BLE001 - Nutzer-Code, strukturiert melden
            return None, _error(type(exc).__name__, exc)
        return ns.get("result"), None

    def call(self, context_id, source, function, args, kwargs):
        """Lädt den Kontext, ruft dann die benannte Funktion auf."""
        ctx = self._context(context_id)
        ns = ctx.namespace
        try:
            code = compile(source, "<bridge:%s>" % context_id, "exec")
            exec(code, ns)
        except Exception as exc:  # noqa: BLE001
            return None, _error(type(exc).__name__, exc)

        fn = ns.get(function)
        if fn is None:
            return None, _error(
                "AttributeError",
                "Funktion '%s' ist im Skript nicht definiert" % function)
        try:
            result = fn(*args, **kwargs)
        except Exception as exc:  # noqa: BLE001
            return None, _error(type(exc).__name__, exc)
        return result, None


def _error(exc_type, exc):
    return {
        "type": exc_type,
        "message": str(exc),
        "traceback": traceback.format_exc(),
    }