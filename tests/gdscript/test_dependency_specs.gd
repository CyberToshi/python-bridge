class_name PBTestDependencySpecs
extends PBTests
## Tests fuer die Requirement-Auswertung in PythonBridgeDependencyManager.
##
## Warum: Die Provisionierung prueft nach dem pip-Lauf, ob jedes Paket in
## site-packages liegt. Frueher wurden nur "==", ">=" und "<" abgeschnitten —
## ein voellig legitimes "beautifulsoup4~=4.12" blieb als Name stehen, galt
## damit als fehlend und der Start brach ab, obwohl pip erfolgreich war.
## Diese Suite pinnt die akzeptierten Schreibweisen.

func test_plain_name() -> void:
	assert_eq(PythonBridgeDependencyManager.requirement_name("numpy"), "numpy")

func test_greater_equal_pin() -> void:
	assert_eq(PythonBridgeDependencyManager.requirement_name("pandas>=2.0"), "pandas")

func test_compatible_release_pin() -> void:
	assert_eq(PythonBridgeDependencyManager.requirement_name("beautifulsoup4~=4.12"), "beautifulsoup4")

func test_exact_pin_and_extras() -> void:
	assert_eq(PythonBridgeDependencyManager.requirement_name("requests[socks]==2.32.3"), "requests")

func test_not_equal_and_marker() -> void:
	assert_eq(PythonBridgeDependencyManager.requirement_name("urllib3!=2.0; python_version>'3.8'"), "urllib3")

func test_direct_url_keeps_name() -> void:
	assert_eq(
		PythonBridgeDependencyManager.requirement_name("mypkg @ https://example.com/mypkg-1.0.whl"),
		"mypkg")

func test_pip_option_is_not_a_package() -> void:
	assert_eq(PythonBridgeDependencyManager.requirement_name("--extra-index-url https://example.com"), "")

func test_vcs_url_has_no_checkable_name() -> void:
	assert_eq(
		PythonBridgeDependencyManager.requirement_name("git+https://github.com/a/b.git@main"), "")

func test_normalize_dist_name() -> void:
	assert_eq(PythonBridgeDependencyManager.normalize_dist_name("scikit-learn"), "scikit_learn")
	assert_eq(PythonBridgeDependencyManager.normalize_dist_name("Pillow"), "pillow")
	assert_eq(PythonBridgeDependencyManager.normalize_dist_name("zope.interface"), "zope_interface")

func test_deps_from_source_keeps_full_spec() -> void:
	var specs := PythonBridgeDependencyManager.deps_from_source(
		"__bridge_deps__ = [\"numpy>=1.26\", \"beautifulsoup4~=4.12\"]\n")
	assert_eq(specs.size(), 2)
	assert_eq(specs[1], "beautifulsoup4~=4.12", "Spec bleibt fuer pip unveraendert")
