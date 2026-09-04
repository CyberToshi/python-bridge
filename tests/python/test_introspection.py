"""Unit tests: AST introspection (wrapper schema)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "addons", "python_bridge", "python"))

from python_bridge import introspection

SRC = '''
"""Module docstring."""
import math

def calculate(a: int, b: int = 2, *args, scale: float = 1.0, **kw) -> int:
    """Adds a and b, optionally scaled."""
    return int((a + b) * scale)

def no_hints(x, y):
    return x

async def fetch(url: str):
    return url

def posonly(a, b, /, c):
    return a + b + c
'''


class IntrospectionTest(unittest.TestCase):

    def test_schema_basics(self):
        schema = introspection.analyze(SRC)
        names = [f["name"] for f in schema["functions"]]
        self.assertEqual(names, ["calculate", "no_hints", "fetch", "posonly"])

    def test_param_kinds_and_defaults(self):
        schema = introspection.analyze(SRC)
        calc = schema["functions"][0]
        self.assertEqual(calc["returns"], "int")
        self.assertEqual(calc["docstring"], "Adds a and b, optionally scaled.")
        kinds = [(p["name"], p["kind"], p["has_default"]) for p in calc["params"]]
        self.assertIn(("a", "pos", False), kinds)
        self.assertIn(("b", "pos", True), kinds)
        self.assertIn(("args", "var", False), kinds)
        self.assertIn(("scale", "kwonly", True), kinds)
        self.assertIn(("kw", "kw", False), kinds)
        default_b = [p for p in calc["params"] if p["name"] == "b"][0]
        self.assertEqual(default_b["default"], "2")
        self.assertEqual(default_b["annotation"], "int")

    def test_posonly(self):
        schema = introspection.analyze(SRC)
        po = schema["functions"][3]
        kinds = [(p["name"], p["kind"]) for p in po["params"]]
        self.assertEqual(kinds, [("a", "posonly"), ("b", "posonly"), ("c", "pos")])

    def test_async_kind(self):
        schema = introspection.analyze(SRC)
        fetch = schema["functions"][2]
        self.assertEqual(fetch["kind"], "async_def")

    def test_syntax_error_raises(self):
        with self.assertRaises(SyntaxError):
            introspection.analyze("def broken(:\n")

    def test_deterministic(self):
        self.assertEqual(introspection.analyze(SRC), introspection.analyze(SRC))


if __name__ == "__main__":
    unittest.main()