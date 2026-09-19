"""Tests fuer den Cython-Sonderpfad.

Deckt die pure-Python-Teile ab (Hash-Change-Detection, Report-Form,
Compiler-Umgebung) sowie den Executor-Pfad fuer `cython:`-Kontexte
(Import eines vorkompilierten Moduls in den Kontext-Namespace).
Echte Compile-Laeufe sind Live-E2E (siehe tests/live_cython_build.py) -
in der Unit-Suite wird nur importiert, was schon als .so liegt.
"""

import json
import sys
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
BRIDGE = REPO / "addons" / "python_bridge" / "python"
sys.path.insert(0, str(BRIDGE))

from python_bridge import executor, protocol  # noqa: E402


class _FakeFile:
    """Minimaler Ersatz fuer die Report-Datei des Build-Tools."""

    def __init__(self, payload):
        self.payload = payload


class CythonBuildToolLogicTest(unittest.TestCase):
    """Die CLI des Tools ist Live-getestet; hier geht es um die Logik,
    die Change-Detection und Report-Form garantieren."""

    def _load_tool(self):
        import importlib.util
        tool = BRIDGE / "cython_build.py"
        spec = importlib.util.spec_from_file_location("cython_build_tool", tool)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_state_roundtrip(self):
        tool = self._load_tool()
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            build_dir = Path(td)
            self.assertEqual(tool._load_state(build_dir), {})
            tool._save_state(build_dir, {"mathx": "abc123"})
            self.assertEqual(tool._load_state(build_dir), {"mathx": "abc123"})
            # Atomarer Write: kein .tmp-Rest
            self.assertFalse((build_dir / (tool.STATE_FILE + ".tmp")).exists())

    def test_output_present(self):
        tool = self._load_tool()
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            self.assertFalse(tool._output_present(d, "mathx"))
            (d / "mathx.cpython-312-x86_64-linux-gnu.so").write_bytes(b"x")
            self.assertTrue(tool._output_present(d, "mathx"))

    def test_pyx_hash_stable_and_content_sensitive(self):
        tool = self._load_tool()
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "m.pyx"
            p.write_text("def f(): pass", "utf-8")
            h1 = tool._pyx_hash(p)
            p.write_text("def f(): return 1", "utf-8")
            h2 = tool._pyx_hash(p)
            self.assertEqual(tool._pyx_hash(p), h2)
            self.assertNotEqual(h1, h2)


class ExecutorCythonContextTest(unittest.TestCase):
    """`cython:`-Kontexte: statt Source wird das kompilierte Modul
    importiert; seine oeffentlichen Funktionen landen im Namespace."""

    def _host(self):
        return executor.ScriptHost()

    def test_cython_import_success(self):
        host = self._host()
        ctx = host._context("cython:/ws/scripts/mathx.pyx")
        fake = type("M", (), {"public_fn": staticmethod(lambda: 42)})()
        with mock.patch.object(executor.importlib, "import_module", return_value=fake) as mi:
            err = host._import_cython_module(ctx, "cython:/ws/scripts/mathx.pyx")
        self.assertIsNone(err)
        mi.assert_called_once_with("mathx")
        self.assertEqual(ctx.namespace["public_fn"](), 42)
        # Kontext gilt als definiert; privates/modulobjekt vorhanden
        self.assertEqual(ctx.source_hash, "cython:mathx")
        self.assertIn("mathx", ctx.namespace)

    def test_cython_import_missing_module(self):
        host = self._host()

        def _raise(name):
            raise ImportError("No module named '%s'" % name)

        with mock.patch.object(executor.importlib, "import_module", side_effect=_raise):
            err = host._import_cython_module(host._context("cython:/ws/scripts/ghost.pyx"),
                                             "cython:/ws/scripts/ghost.pyx")
        self.assertIsNotNone(err)
        self.assertEqual(err["type"], "CythonModuleNotFound")
        self.assertEqual(err["code"], protocol.CATEGORY_TASK_ERROR)
        self.assertIn("compile_cython", err["message"])

    def test_call_without_source_uses_import(self):
        host = self._host()
        fake = type("M", (), {"answer": staticmethod(lambda: 7)})()
        with mock.patch.object(executor.importlib, "import_module", return_value=fake):
            result, err = host.call("cython:/ws/scripts/thing.pyx", "", "answer", [], {})
        self.assertIsNone(err)
        self.assertEqual(result, 7)

    def test_call_error_when_not_built(self):
        host = self._host()
        with mock.patch.object(executor.importlib, "import_module",
                               side_effect=ImportError("missing")):
            result, err = host.call("cython:/ws/scripts/nothere.pyx", "", "f", [], {})
        self.assertIsNone(result)
        self.assertEqual(err["type"], "CythonModuleNotFound")


if __name__ == "__main__":
    unittest.main()
