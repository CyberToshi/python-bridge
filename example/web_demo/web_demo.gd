extends Node
## Web-Demo der Python Bridge — läuft 1:1 auf Desktop (Windows/Linux) und
## im Browser (Pyodide). Der Plattform-Unterschied liegt komplett in der
## Bridge: `start_instance` wählt automatisch den Transport, der Python-Code
## und dieses Skript sind identisch.
##
## Desktop: einfach als Hauptszene starten.
## Web:     siehe example/web_demo/README.md (Bundle bauen + exportieren).

func _ready() -> void:
	_run()

func _run() -> void:
	var bridge := PythonBridge

	# Kleine Plattform-Info: die Bridge wählt den Transport automatisch.
	print("[demo] Plattform: ", OS.get_name(), " -> Transport: ",
		"Pyodide (Web)" if OS.has_feature("web") else "Python-Prozess (Desktop)")

	print("[demo] start_instance ...")
	var start: Variant = await bridge.start_instance("default")
	if start.is_error():
		print("[demo] FEHLER start_instance: ", start.error_message())
		return
	print("[demo] Instanz bereit (Transport: ",
		"Pyodide/Web" if OS.has_feature("web") else "Prozess/Desktop", ")")

	# 1) Skript anlegen und aufrufen
	bridge.create_script("demo", "def greet(name):\n    return 'Hello ' + str(name) + ' from Python!'\n")
	var r1: Variant = await bridge.call_script("demo", "greet", ["Godot"])
	if r1.is_ok():
		print("[demo] 1) ", r1.value)
	else:
		print("[demo] 1) FEHLER: ", r1.error_message())

	# 2) Eigenes Modul importieren (modules/calculations.py) — gleicher Code
	#    auf allen Plattformen, keine Plattform-Verzweigung im Nutzer-Code.
	var r2: Variant = await bridge.execute("""
import modules.calculations as calc
result = calc.summarize([1, 2, 3, 4, 5])
""", {})
	if r2.is_ok():
		print("[demo] 2) summarize: ", r2.value)
	else:
		print("[demo] 2) FEHLER: ", r2.error_message())

	# 3) Plugin benutzen (plugins/example_plugin.py)
	var r3: Variant = await bridge.execute("""
import example_plugin
result = example_plugin.plugin_info()
""", {})
	if r3.is_ok():
		print("[demo] 3) plugin: ", r3.value)
	else:
		print("[demo] 3) FEHLER: ", r3.error_message())

	print("[demo] FERTIG")
