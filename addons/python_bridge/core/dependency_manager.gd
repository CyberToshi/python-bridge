@tool
class_name PythonBridgeDependencyManager
extends RefCounted
## Sammelt Python-Paket-Abhängigkeiten, die Skripte SELBST deklarieren.
##
## Konvention (in der ersten Zeile einer Python-Datei im Workspace):
##
##     __bridge_deps__ = ["numpy", "pandas>=2.0"]
##
## Die Deklaration ist die Single Source of Truth und wird an allen Stellen
## gleich behandelt:
##   - Desktop: Provisioner installiert fehlende Pakete beim venv-Bau, der
##     Server installiert neu hinzugekommene Pakete zur Laufzeit nach.
##   - Web:     build_web_bundle.py schreibt die Deklarationen in
##     bridge_deps.json, der Pyodide-Worker lädt sie beim Start.
##
## Der GDScript-Parser hier ist bewusst ein simpler, konservativer
## String-Scan (erste Zuweisung, String-Literale, Strip von Versionsspecs):
## er darf NIEMALS einen Skriptinhalt verändern oder ausführen. Die
## verbindliche Prüfung (was ist wirklich importierbar?) macht die Python-
## Seite (executor._dependency_available) zur Laufzeit.

const DEPS_MARKER := "__bridge_deps__"

# findet: __bridge_deps__ = [ ... ]  (Top-Level, d.h. am Zeilenanfang -
# (?m) macht ^ zeilenweise; eingerueckte/nested Deklarationen zaehlen nicht,
# konsistent zur AST-Extraktion der Python-Seite)
const _DEPS_LINE_RE := "(?m)^__bridge_deps__\\s*=\\s*\\["


## Extrahiert Paketnamen aus einem Python-Quelltext (ohne ihn auszuführen).
## Nicht-String-Einträge werden ignoriert; Duplikate werden entfernt; die
## Reihenfolge bleibt erhalten. Versionsspecs ("pandas>=2.0") bleiben als
## voller Spec erhalten, damit pip sie auflösen kann.
static func deps_from_source(source: String) -> PackedStringArray:
	var out := PackedStringArray()
	if source.is_empty() or not source.contains(DEPS_MARKER):
		return out
	var regex := RegEx.new()
	regex.compile(_DEPS_LINE_RE)
	if regex.search(source) == null:
		return out
	for line in source.split("\n"):
		if not line.begins_with(DEPS_MARKER):
			continue  # nur Top-Level-Zeilen (keine Einrueckung)
		var t := line.strip_edges()
		var inner := _bracket_content(t)
		if inner == "":
			continue
		for spec in _string_literals(inner):
			if not out.has(spec):
				out.append(spec)
		return out  # nur die erste Deklaration zählt
	return out


## Sammelt die Deklarationen ALLER Skripte im Workspace (python_bridge/scripts,
## inkl. Unterordner). Fehlende/unlesbare Dateien werden still übersprungen.
static func from_workspace(workspace_fs: String) -> PackedStringArray:
	return from_scripts_dir(workspace_fs + "/scripts")


## Wie from_workspace, aber mit beliebigem Skript-Ordner (res://- oder
## absoluter Pfad). Nützlich für Tools und Tests.
static func from_scripts_dir(scripts_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(scripts_dir)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := scripts_dir + "/" + entry
		if dir.current_is_dir():
			if not entry.begins_with("."):
				for spec in from_scripts_dir(full):
					if not out.has(spec):
						out.append(spec)
		elif entry.ends_with(".py") or entry.ends_with(".pyx"):
			var f := FileAccess.open(full, FileAccess.READ)
			if f:
				for spec in deps_from_source(f.get_as_text()):
					if not out.has(spec):
						out.append(spec)
				f.close()
		entry = dir.get_next()
	dir.list_dir_end()
	return out


## Vereint Workspace-Deklarationen mit der klassischen dependencies.txt und
## der configure()-Liste. Resultat: ein einziger pip-Lauf beim Provisionieren.
static func combined_requirements(
		workspace_fs: String, cfg_dependencies: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for spec in from_workspace(workspace_fs):
		if not out.has(spec):
			out.append(spec)
	for spec in cfg_dependencies:
		var s := str(spec).strip_edges()
		if s != "" and not out.has(s):
			out.append(s)
	var req_file := workspace_fs + "/config/dependencies.txt"
	if FileAccess.file_exists(req_file):
		var f := FileAccess.open(req_file, FileAccess.READ)
		if f:
			for line in f.get_as_text().split("\n"):
				var s := line.strip_edges()
				if s != "" and not s.begins_with("#") and not out.has(s):
					out.append(s)
			f.close()
	return out


# ------------------------------------------------------------------ intern

## Inhalt der ersten [ ... ]-Klammer einer Zeile (oder "" ohne Abschluss).
static func _bracket_content(line: String) -> String:
	var start := line.find("[")
	if start < 0:
		return ""
	var end := line.rfind("]")
	if end < start:
		return ""
	return line.substr(start + 1, end - start - 1)


## String-Literale aus einem Klammerinhalt ("numpy" oder 'numpy>=1.0').
## Bewusst ohne echte Python-Lexer: es werden nur einfache, nicht
## verschachtelte Literale erkannt - fuer Paketnamen ausreichend.
static func _string_literals(inner: String) -> PackedStringArray:
	var out := PackedStringArray()
	var quote := ""
	var buf := ""
	for ch in inner:
		if quote != "":
			if ch == quote:
				var spec := buf.strip_edges()
				if spec != "" and not out.has(spec):
					out.append(spec)
				quote = ""
				buf = ""
			else:
				buf += ch
		elif ch == "\"" or ch == "'":
			quote = ch
			buf = ""
		# alles ausser Strings (Kommas, Specs ausserhalb von Quotes etc.)
		# wird ignoriert
	return out
