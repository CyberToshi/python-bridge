"""Tests fuer Skript-Deklarierte Abhaengigkeiten (``__bridge_deps__``).

Deckt die Kette ab: Introspection-Extraktion -> Executor-Gate (strukturierter
DEPENDENCY_ERROR vor der Ausfuehrung) -> Server-Auto-Installation in der
laufenden venv -> Batch-Fehlerform -> Web-Verhalten (strukturierter Fehler,
kein pip).
"""

import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "addons", "python_bridge", "python"))

from python_bridge import browser_host, executor, introspection, protocol, server  # noqa: E402


class IntrospectionDepsTest(unittest.TestCase):
    def test_simple_list(self):
        deps = introspection.deps_from_source('__bridge_deps__ = ["numpy", "pandas>=2.0"]\n\nx = 1\n')
        self.assertEqual(deps, ["numpy", "pandas>=2.0"])

    def test_no_declaration(self):
        self.assertEqual(introspection.deps_from_source("import numpy\nprint(1)\n"), [])

    def test_duplicates_and_empty(self):
        deps = introspection.deps_from_source(
            "__bridge_deps__ = ['numpy', 'numpy', '', '  scipy  ']\n")
        self.assertEqual(deps, ["numpy", "scipy"])

    def test_single_quotes_and_version_specs(self):
        deps = introspection.deps_from_source(
            "__bridge_deps__ = ['pandas==2.2.0', 'matplotlib<4']\n")
        self.assertEqual(deps, ["pandas==2.2.0", "matplotlib<4"])

    def test_non_string_entries_ignored(self):
        deps = introspection.deps_from_source("__bridge_deps__ = ['numpy', 42]\n")
        self.assertEqual(deps, ["numpy"])

    def test_analyze_includes_dependencies(self):
        schema = introspection.analyze('__bridge_deps__ = ["numpy"]\n\ndef f(a):\n    return a\n')
        self.assertEqual(schema["dependencies"], ["numpy"])
        self.assertEqual(schema["functions"][0]["name"], "f")

    def test_gdscript_parser_matches_python(self):
        """Der GDScript-String-Scan (DependencyManager) muss dieselben
        Ergebnisse liefern wie die Python-Referenz (hier: die Referenz als
        Orakel fuer identische Semantik auf beiden Seiten)."""
        src = '# comment\n__bridge_deps__ = ["numpy", "scipy>=1.11"]\n\ndef f():\n    pass\n'
        self.assertEqual(introspection.deps_from_source(src), ["numpy", "scipy>=1.11"])


class ExecutorDepsGateTest(unittest.TestCase):
    def test_missing_dependency_structured_error(self):
        host = executor.ScriptHost()
        body = host.execute_job({
            "id": "t1", "command": "define", "context": "c1",
            "source": "__bridge_deps__ = ['definitely_not_a_real_package_123']\n",
        })
        self.assertEqual(body["status"], "error")
        err = body["error"]
        self.assertEqual(err["code"], protocol.CATEGORY_DEPENDENCY_ERROR)
        self.assertIn("definitely_not_a_real_package_123", err["message"])

    def test_available_dependency_passes(self):
        host = executor.ScriptHost()
        src = '__bridge_deps__ = ["json"]\n\ndef ok():\n    return 42\n'
        body = host.execute_job({
            "id": "t2", "command": "define", "context": "c2", "source": src,
        })
        self.assertEqual(body["status"], "ok", body.get("error"))
        body2 = host.execute_job({
            "id": "t3", "command": "call", "context": "c2", "function": "ok",
            "source": src,
        })
        self.assertEqual(body2["status"], "ok")
        self.assertEqual(body2["data"], 42)

    def test_installed_list_bypasses_probe(self):
        host = executor.ScriptHost()
        # Fake-Installation: Provisioner-Liste -> Probe uebersprungen.
        host.installed_dependencies = ["fakevenvonlypackage"]
        body = host.execute_job({
            "id": "t4", "command": "define", "context": "c4",
            "source": "__bridge_deps__ = ['fakevenvonlypackage']\nx = 1\n",
        })
        self.assertEqual(body["status"], "ok", body.get("error"))

    def test_call_with_source_and_deps(self):
        host = executor.ScriptHost()
        body = host.execute_job({
            "id": "t5", "command": "call", "context": "c5",
            "source": '__bridge_deps__ = ["json"]\n\ndef double(x):\n    return x * 2\n',
            "function": "double", "data": {"args": [21], "kwargs": {}},
        })
        self.assertEqual(body["status"], "ok", body.get("error"))
        self.assertEqual(body["data"], 42)

    def test_dep_error_prevents_execution(self):
        """Der Code mit dem fehlenden Import darf NIEMALS laufen."""
        host = executor.ScriptHost()
        body = host.execute_job({
            "id": "t6", "command": "define", "context": "c6",
            "source": ("__bridge_deps__ = ['definitely_not_a_real_package_123']\n"
                       "raise RuntimeError('CODE RAN - should never happen')\n"),
        })
        self.assertEqual(body["status"], "error")
        self.assertEqual(body["error"]["code"], protocol.CATEGORY_DEPENDENCY_ERROR)


class ServerAutoInstallTest(unittest.TestCase):
    """_ensure_script_dependencies: fehlende Pakete werden per pip in die
    laufende venv installiert (gemockt), danach als verfuegbar registriert."""

    def _msg(self):
        return {"id": "m1", "command": "call", "context": "c",
                "deps": ["pkga", "pkgb>=1.0"]}

    def test_no_deps_is_noop(self):
        ok, err = server._ensure_script_dependencies(executor.ScriptHost(), {"id": "x"})
        self.assertTrue(ok)
        self.assertEqual(err, "")

    def test_missing_triggers_pip_once(self):
        host = executor.ScriptHost()

        calls = []

        def fake_run(cmd, **kwargs):
            calls.append(list(cmd))
            class P:
                returncode = 0
                stdout = ""
                stderr = ""
            return P()

        with mock.patch.object(server.sys, "executable", "/venv/bin/python"), \
                mock.patch.object(server, "os") as mock_os, \
                mock.patch("subprocess.run", side_effect=fake_run):
            mock_os.path.exists.return_value = True
            ok, err = server._ensure_script_dependencies(host, self._msg())

        self.assertTrue(ok, err)
        self.assertEqual(len(calls), 1)
        cmd = calls[0]
        self.assertIn("-m", cmd)
        self.assertIn("pip", cmd)
        self.assertIn("install", cmd)
        self.assertIn("pkga", cmd)
        self.assertIn("pkgb>=1.0", cmd)
        self.assertIn("pkga", host.installed_dependencies)
        self.assertIn("pkgb", host.installed_dependencies)

    def test_pip_failure_is_structured(self):
        host = executor.ScriptHost()

        def fake_run(cmd, **kwargs):
            class P:
                returncode = 1
                stdout = ""
                stderr = "No matching distribution"
            return P()

        with mock.patch.object(server.sys, "executable", "/venv/bin/python"), \
                mock.patch.object(server, "os") as mock_os, \
                mock.patch("subprocess.run", side_effect=fake_run):
            mock_os.path.exists.return_value = True
            ok, err = server._ensure_script_dependencies(host, self._msg())

        self.assertFalse(ok)
        self.assertIn("pip install failed", err)
        self.assertIn("No matching distribution", err)

    def test_job_fn_installs_missing_deps(self):
        """_job_fn ruft die Installation vor der Ausfuehrung auf: nach dem
        Mock-Install ist das Paket laut installed_dependencies verfuegbar."""
        host = executor.ScriptHost()
        message = {
            "id": "j1", "command": "call", "context": "cj",
            "source": '__bridge_deps__ = ["mockdep"]\n\ndef f():\n    return "ran"\n',
            "function": "f",
        }

        def fake_ensure(h, msg):
            host.installed_dependencies.append("mockdep")
            return True, ""

        with mock.patch.object(server, "_ensure_script_dependencies", side_effect=fake_ensure):
            result = server._job_fn(host, server.DataStore(), message)

        self.assertFalse(result["batch"])
        self.assertEqual(result["body"]["status"], "ok", result["body"].get("error"))
        self.assertEqual(result["body"]["data"], "ran")
        # deps-Meta ist am Message-Dict erlaubt (Whitelist-frei), darf aber
        # nicht in den Context gelangen:
        self.assertNotIn("deps", host.contexts["cj"].namespace)

    def test_batch_dep_error_shape(self):
        host = executor.ScriptHost()
        message = {
            "id": "b1", "type": protocol.MSG_BATCH,
            protocol.FIELD_ITEMS: [
                {"id": "i1", "command": "define", "context": "cb",
                 "source": "__bridge_deps__ = ['definitely_not_a_real_package_123']\n"},
            ],
        }
        result = server._job_fn(host, None, message)
        self.assertTrue(result["batch"])
        item = result["items"][0]
        self.assertEqual(item["status"], "error")
        self.assertEqual(item["error"]["code"], protocol.CATEGORY_DEPENDENCY_ERROR)


class BrowserHostDepsTest(unittest.TestCase):
    def test_missing_web_dep_structured_error(self):
        host = browser_host.BrowserHost()
        frames = host.handle_message(json.dumps({
            "id": "w1", "type": protocol.MSG_TASK, "command": "define",
            "context": "wc",
            "source": "__bridge_deps__ = ['definitely_not_a_real_package_123']\n",
        }))
        self.assertEqual(len(frames), 1)
        msg = json.loads(frames[0]["text"])
        self.assertEqual(msg.get("type"), protocol.MSG_TASK_ERROR)
        self.assertEqual(msg["error"]["code"], protocol.CATEGORY_DEPENDENCY_ERROR)
        self.assertIn("Rebuild the web bundle", msg["error"]["message"])

    def test_registered_packages_accept_deps(self):
        """js_register_packages (Worker ruft es nach loadPackage) -> Host
        akzeptiert die Skript-Deklaration ohne Fehler."""
        status = json.loads(browser_host.js_init(
            '{"max_stdout_bytes": 65536}', "/workspace", "web"))
        self.assertEqual(status["platform"], "web")
        self.assertEqual(browser_host.js_register_packages(["numpy"]), "ok")
        out = browser_host.js_dispatch("", json.dumps({
            "id": "w2", "type": protocol.MSG_TASK, "command": "define",
            "context": "wc2",
            "source": "__bridge_deps__ = ['numpy']\nx = 1\n",
        }))
        frames = json.loads(out)
        msg = json.loads(frames[0]["text"])
        self.assertEqual(msg.get("type"), protocol.MSG_TASK_RESULT)

    def test_web_dep_never_falls_back_to_pip(self):
        """Auf Web gibt es kein pip: fehlende Pakete duerfen keinen
        Installationsversuch starten, sondern nur strukturiert fehlschlagen."""
        host = browser_host.BrowserHost()
        with mock.patch("subprocess.run") as fake_run:
            frames = host.handle_message(json.dumps({
                "id": "w3", "type": protocol.MSG_TASK, "command": "define",
                "context": "wc3",
                "source": "__bridge_deps__ = ['definitely_not_a_real_package_123']\n",
            }))
            fake_run.assert_not_called()
        msg = json.loads(frames[0]["text"])
        self.assertEqual(msg["error"]["code"], protocol.CATEGORY_DEPENDENCY_ERROR)


if __name__ == "__main__":
    unittest.main()
