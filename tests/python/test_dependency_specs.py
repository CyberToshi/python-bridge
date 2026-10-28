"""Tests fuer die Requirement-Auswertung im Executor.

Der Gate `_dependency_available` entscheidet zur Laufzeit, ob ein per
``__bridge_deps__`` deklariertes Paket vorhanden ist. Er muss dieselben
Schreibweisen akzeptieren wie pip — sonst schlaegt ein korrekt installiertes
Paket als "fehlt" fehl (frueher u. a. bei ``~=``-Pins, Extras und URLs).
"""

import unittest

from python_bridge import executor


class DependencySpecTest(unittest.TestCase):
    def test_plain_name_installed(self):
        self.assertTrue(executor._dependency_available("websockets"))

    def test_version_pin_installed(self):
        self.assertTrue(executor._dependency_available("websockets>=11"))

    def test_compatible_release_pin_uses_installed_list(self):
        # beautifulsoup4 installiert als "bs4" - der Distributionsname kommt
        # aus dem Provisioner, nicht aus find_spec().
        self.assertTrue(
            executor._dependency_available("beautifulsoup4~=4.12", ["beautifulsoup4"]))

    def test_extras_are_stripped(self):
        self.assertTrue(executor._dependency_available("websockets[test]>=11"))

    def test_pip_option_is_ignored(self):
        self.assertTrue(
            executor._dependency_available("--extra-index-url https://example.com"))

    def test_vcs_url_is_not_checkable(self):
        self.assertTrue(
            executor._dependency_available("git+https://github.com/a/b.git@main"))

    def test_direct_url_with_name(self):
        self.assertTrue(
            executor._dependency_available(
                "mypkg @ https://example.com/mypkg-1.0.whl", ["mypkg"]))

    def test_missing_package_still_detected(self):
        self.assertFalse(executor._dependency_available("gibt_es_nicht_xyz>=1.0"))


if __name__ == "__main__":
    unittest.main()
