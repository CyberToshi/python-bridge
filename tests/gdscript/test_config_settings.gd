class_name PBTestConfigSettings
extends PBTests
## Tests fuer die Konfigurations-Kette (Defaults -> Projekt-Einstellungen ->
## config.json -> configure()). Bewusst ohne Editor: die Mapping-Logik ist
## reine Datenverarbeitung und muss auch im Export stimmen.

func test_defs_are_unique_and_namespaced() -> void:
	var defs := PythonBridgeConfig.project_setting_defs()
	assert_true(defs.size() >= 6, "mindestens die Kern-Einstellungen sind definiert")
	var paths := {}
	var keys := {}
	for def in defs:
		var path := str(def.get("path", ""))
		var key := str(def.get("key", ""))
		assert_true(path.begins_with(PythonBridgeConfig.SETTINGS_SECTION + "/"), "Pfad im Abschnitt: " + path)
		assert_false(paths.has(path), "Pfad eindeutig: " + path)
		assert_false(keys.has(key), "Key eindeutig: " + key)
		assert_true(def.has("default"), "Default vorhanden: " + key)
		assert_ne(str(def.get("label", "")), "", "Label vorhanden: " + key)
		paths[path] = true
		keys[key] = true

func test_defs_cover_the_important_knobs() -> void:
	var keys := {}
	for def in PythonBridgeConfig.project_setting_defs():
		keys[str(def["key"])] = true
	for expected in ["autostart", "workspace_dir", "python_executable", "dependencies",
			"hot_reload_mode", "web_packages"]:
		assert_true(keys.has(expected), "Einstellung vorhanden: " + expected)

func test_collect_without_sources_is_default() -> void:
	var cfg := PythonBridgeConfig.collect()
	var defaults := PythonBridgeConfig.defaults()
	for key in ["autostart", "workspace_dir", "hot_reload_mode", "workers_per_instance"]:
		assert_eq(str(cfg.get(key)), str(defaults.get(key)), "Default bleibt: " + key)

func test_project_values_override_defaults() -> void:
	var cfg := PythonBridgeConfig.collect({
		"python_bridge/general/autostart": true,
		"python_bridge/general/workspace_dir": "res://mein_python",
	})
	assert_true(bool(cfg.get("autostart")), "autostart aus Projekt-Einstellung")
	assert_eq(str(cfg.get("workspace_dir")), "res://mein_python")

func test_config_file_wins_over_project_settings() -> void:
	var cfg := PythonBridgeConfig.collect(
		{"python_bridge/general/workspace_dir": "res://aus_projekt"},
		{"workspace_dir": "res://aus_datei"})
	assert_eq(str(cfg.get("workspace_dir")), "res://aus_datei", "config.json gewinnt")

func test_unknown_keys_survive() -> void:
	var cfg := PythonBridgeConfig.collect({}, {"eigenes_feature": 7})
	assert_eq(int(cfg.get("eigenes_feature", 0)), 7, "Vorwaerts-Kompatibilitaet")

func test_dependency_string_is_split() -> void:
	var cfg := PythonBridgeConfig.collect({}, {"dependencies": "numpy, scipy>=1.10 ; pandas"})
	var deps: PackedStringArray = cfg.get("dependencies", PackedStringArray())
	assert_eq(deps.size(), 3, "drei Pakete: " + str(deps))
	assert_eq(deps[0], "numpy")
	assert_eq(deps[1], "scipy>=1.10")
	assert_eq(deps[2], "pandas")

func test_dependency_array_is_kept() -> void:
	var cfg := PythonBridgeConfig.collect({}, {"dependencies": ["numpy", "torch==2.0"]})
	var deps: PackedStringArray = cfg.get("dependencies", PackedStringArray())
	assert_eq(deps.size(), 2)
	assert_eq(deps[1], "torch==2.0")

func test_empty_dependency_string_is_empty_list() -> void:
	var cfg := PythonBridgeConfig.collect({}, {"dependencies": "   ,  , "})
	var deps: PackedStringArray = cfg.get("dependencies", PackedStringArray(["x"]))
	assert_eq(deps.size(), 0, "keine leeren Specs")

func test_project_values_maps_paths_to_keys() -> void:
	var values := PythonBridgeConfig.project_values({
		"python_bridge/general/autostart": true,
		"python_bridge/web/packages": "numpy",
		"unrelated/setting": 5,
	})
	assert_eq(values.size(), 2, "nur bekannte Pfade werden abgebildet")
	assert_true(bool(values.get("autostart", false)))
	assert_eq(str(values.get("web_packages", "")), "numpy")
	assert_false(values.has("unrelated"), "fremde Pfade ignoriert")

func test_split_list_handles_junk() -> void:
	assert_eq(PythonBridgeConfig.split_list("").size(), 0)
	assert_eq(PythonBridgeConfig.split_list(" , , ").size(), 0)
	var parts := PythonBridgeConfig.split_list("a,b;c")
	assert_eq(parts.size(), 3, "Komma und Semikolon: " + str(parts))
	assert_eq(parts[2], "c")

func test_empty_workspace_dir_falls_back_to_default() -> void:
	# Ein geleertes Feld im Einstellungs-Dialog darf die Skripte nicht in
	# "/scripts" (Laufwerkswurzel) schieben.
	for value in ["", "   "]:
		var cfg := PythonBridgeConfig.collect({}, {"workspace_dir": value})
		assert_eq(str(cfg.get("workspace_dir")), PythonBridgeConfig.DEFAULT_WORKSPACE_DIR,
			"leerer Workspace -> Default (war: %s)" % JSON.stringify(value))
	var padded := PythonBridgeConfig.collect({}, {"workspace_dir": "  res://mein_python  "})
	assert_eq(str(padded.get("workspace_dir")), "res://mein_python", "Whitespace wird getrimmt")

func test_hot_reload_value_stays_string() -> void:
	var cfg := PythonBridgeConfig.collect({}, {"hot_reload_mode": "restart_instance"})
	assert_eq(str(cfg.get("hot_reload_mode")), "restart_instance")
	assert_true(PythonBridgeConfig.is_valid_reload_mode(str(cfg.get("hot_reload_mode"))))
