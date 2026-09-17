import tempfile
import unittest
from pathlib import Path

from tools.export_check import check_project


class ExportCheckTests(unittest.TestCase):
    def _project(self, presets=""):
        root = Path(tempfile.mkdtemp())
        (root / "addons/python_bridge/core").mkdir(parents=True)
        (root / "addons/python_bridge/python/python_bridge").mkdir(parents=True)
        (root / "addons/python_bridge/plugin.cfg").write_text("[plugin]\n", encoding="utf-8")
        for relative in (
            "addons/python_bridge/core/python_bridge.gd",
            "addons/python_bridge/python/run_server.py",
            "addons/python_bridge/python/python_bridge/server.py",
            "addons/python_bridge/python/requirements.txt",
        ):
            (root / relative).write_text("", encoding="utf-8")
        (root / "project.godot").write_text(
            '[autoload]\nPythonBridge="*res://addons/python_bridge/core/python_bridge.gd"\n'
            '[editor_plugins]\nenabled=PackedStringArray("res://addons/python_bridge/plugin.cfg")\n',
            encoding="utf-8",
        )
        if presets:
            (root / "export_presets.cfg").write_text(presets, encoding="utf-8")
        return root

    def test_web_pyodide_is_default_and_bundle_is_fixable(self):
        # Web braucht keinen externen Endpoint mehr: Pyodide ist der
        # Standard-Transport; ohne Bundle gibt es eine fixable Warnung.
        report = check_project(self._project('platform="Web"\n'), "web")
        web = [c for c in report.checks if c.name == "web.bundle"]
        self.assertEqual(len(web), 1)
        self.assertEqual(web[0].status, "warning")
        self.assertTrue(web[0].fixable)
        self.assertEqual(report.errors, 0)

    def test_web_accepts_secure_endpoint_as_alternative(self):
        report = check_project(self._project('platform="Web"\n'), "web", "wss://example.test/python")
        web = [c for c in report.checks if c.name == "web.websocket"]
        self.assertEqual(web[0].status, "pass")
        self.assertEqual(report.errors, 0)

    def test_fix_creates_workspace(self):
        root = self._project()
        self.assertFalse((root / "python_bridge/scripts").exists())
        check_project(root, "linux", fix=True)
        self.assertTrue((root / "python_bridge/scripts").is_dir())
        self.assertTrue((root / "python_bridge/venv/.gdignore").is_file())


if __name__ == "__main__":
    unittest.main()
