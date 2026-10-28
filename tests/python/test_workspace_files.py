"""Tests fuer den ``file_op``-Kanal (Web-Spiegelung in den Pyodide-Workspace).

Warum das wichtig ist: im Browser sieht Python ein eigenes MEMFS. Ohne diesen
Kanal existiert ein zur Laufzeit angelegtes Skript dort nie - ``import x``
schlaegt fehl - und ein geloeschtes Skript bleibt importierbar. Die Tests
pruefen beide Operationen inklusive Pfad-Sicherheit und Bytecode-Aufraeumen.
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "addons", "python_bridge", "python"))

from python_bridge import workspace_files  # noqa: E402


class FileOpPathSafetyTest(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        os.makedirs(os.path.join(self.root, "scripts"), exist_ok=True)

    def tearDown(self):
        self._tmp.cleanup()

    def _apply(self, op, path, content=""):
        return workspace_files.apply_file_op(self.root, op, path, content)

    def test_write_creates_file_and_parents(self):
        res = self._apply("write", "scripts/sub/deep/mod.py", "x = 1\n")
        self.assertTrue(res["ok"], res)
        target = Path(self.root) / "scripts" / "sub" / "deep" / "mod.py"
        self.assertEqual(target.read_text("utf-8"), "x = 1\n")
        self.assertEqual(res["bytes"], 6)

    def test_write_is_atomic_without_tmp_leftover(self):
        self._apply("write", "scripts/a.py", "one\n")
        self._apply("write", "scripts/a.py", "two\n")
        files = sorted(p.name for p in (Path(self.root) / "scripts").iterdir())
        self.assertEqual(files, ["a.py"])

    def test_write_normalizes_backslashes(self):
        res = self._apply("write", "scripts\\win\\style.py", "y = 2\n")
        self.assertTrue(res["ok"], res)
        self.assertTrue((Path(self.root) / "scripts" / "win" / "style.py").is_file())

    def test_delete_removes_file(self):
        self._apply("write", "scripts/gone.py", "z = 3\n")
        res = self._apply("delete", "scripts/gone.py")
        self.assertTrue(res["ok"], res)
        self.assertFalse((Path(self.root) / "scripts" / "gone.py").exists())

    def test_delete_missing_file_is_not_an_error(self):
        res = self._apply("delete", "scripts/never_existed.py")
        self.assertTrue(res["ok"], res)

    def test_delete_drops_bytecode_cache(self):
        self._apply("write", "scripts/cached.py", "v = 1\n")
        pycache = Path(self.root) / "scripts" / "__pycache__"
        pycache.mkdir()
        (pycache / "cached.cpython-313.pyc").write_bytes(b"junk")
        (pycache / "other.cpython-313.pyc").write_bytes(b"keep")

        res = self._apply("delete", "scripts/cached.py")

        self.assertTrue(res["ok"], res)
        names = sorted(p.name for p in pycache.iterdir())
        self.assertEqual(names, ["other.cpython-313.pyc"])

    def test_rejects_path_traversal(self):
        res = self._apply("write", "scripts/../../evil.py", "x")
        self.assertFalse(res["ok"])
        self.assertIn("..", res["error"])
        self.assertFalse((Path(self.root).parent / "evil.py").exists())

    def test_rejects_absolute_paths(self):
        for path in ("/etc/passwd", "C:/Windows/evil.py"):
            res = self._apply("write", path, "x")
            self.assertFalse(res["ok"], path)

    def test_rejects_paths_outside_workspace_folders(self):
        res = self._apply("write", "venv/lib/x.py", "x")
        self.assertFalse(res["ok"])
        self.assertIn("scripts/", res["error"])

    def test_rejects_empty_path(self):
        self.assertFalse(self._apply("write", "", "x")["ok"])
        self.assertFalse(self._apply("write", "   ", "x")["ok"])

    def test_rejects_unknown_operation(self):
        res = self._apply("chmod", "scripts/a.py")
        self.assertFalse(res["ok"])
        self.assertIn("unbekannte Operation", res["error"])

    def test_rejects_oversized_content(self):
        res = self._apply("write", "scripts/big.py",
                          "x" * (workspace_files.MAX_CONTENT_BYTES + 1))
        self.assertFalse(res["ok"])
        self.assertIn("zu groß", res["error"])
        self.assertFalse((Path(self.root) / "scripts" / "big.py").exists())

    def test_missing_root_is_reported_not_created(self):
        missing = os.path.join(self.root, "nope")
        res = workspace_files.apply_file_op(missing, "write", "scripts/a.py", "x")
        self.assertFalse(res["ok"])
        self.assertFalse(os.path.exists(missing))

    def test_allowed_prefixes_cover_workspace_layout(self):
        for prefix in ("scripts", "modules", "plugins", "packages"):
            res = self._apply("write", prefix + "/ok.py", "v = 1\n")
            self.assertTrue(res["ok"], (prefix, res))


if __name__ == "__main__":
    unittest.main()
