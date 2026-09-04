@tool
extends EditorPlugin
## Einstiegspunkt des "Python Bridge"-Add-ons.
##
## Registriert die zentrale "PythonBridge"-Klasse als Autoload-Singleton.
## Dadurch sind alle API-Methoden INSTANZ-Methoden und duerfen `await`
## verwenden (im Gegensatz zu `static`-Funktionen, die keine Koroutinen
## sein duerfen). Aufruf z. B.:  `await PythonBridge.start_instance("default")`

const AUTOLOAD_NAME := "PythonBridge"

func _enter_tree() -> void:
	# Nur registrieren, falls noch nicht vorhanden (Plugin kann sich
	# mehrfach ein-/ausschalten). Der Pfad wird ueber get_plugin_path()
	# abgeleitet, damit das Add-on in JEDEM Unterordner funktioniert
	# (z. B. res://PythonBridge_v0.1.0/addons/python_bridge/).
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		# Add-on-Verzeichnis aus dem Skript-Pfad ableiten, damit das Plugin
		# in JEDEM Unterordner funktioniert (z. B. res://PythonBridge_v0.1.0/...).
		var plugin_dir: String = get_script().resource_path.get_base_dir()
		add_autoload_singleton(AUTOLOAD_NAME, plugin_dir + "/core/python_bridge.gd")

func _exit_tree() -> void:
	# Sauberer Shutdown aller Python-Instanzen, danach Autoload entfernen.
	var pb := get_node_or_null("/root/" + AUTOLOAD_NAME)
	if pb:
		pb.call("shutdown")
	if ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		remove_autoload_singleton(AUTOLOAD_NAME)

# Treibt die Polling-Schleife zusaetzlich aus dem Editor, damit Instanzen
# auch dann zuverlaessig ticken, wenn der Autoload im Editor-Kontext nicht
# selbst _process bekommen wuerde.
func _process(_delta: float) -> void:
	var pb := get_node_or_null("/root/" + AUTOLOAD_NAME)
	if pb:
		pb.poll()