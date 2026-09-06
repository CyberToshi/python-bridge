class_name PythonBridgeHPCfg
extends RefCounted
## Configuration for the GDScript2All high-performance path (GDScript -> C++ -> GDExtension).

## Absolute/relative path to the system python3 used to run the GDScript2All
## converter. Default: "python3" from PATH. Set explicitly if your Python
## lives elsewhere (e.g. "C:/Python312/python.exe").
var python_exe: String = "python3"

## Path to the GDScript2All converter main.py, relative to the project root.
## The bundled copy lives next to this add-on; set this only if you moved it.
var converter_main_py: String = "res://GdScript2All-8e0f207aa042d2642e7e003cef03add7f377b22e/addons/gdscript2all/converter/main.py"

## Where generated C++ and GDExtension scaffolding is placed. Relative to
## project root. Must live under res:// so Godot sees the files; must NOT be
## the add-on dir itself (generated files must stay editable and survived
## add-on updates).
var workspace_dir: String = "res://hp_gdscript"

## Name of the GDExtension shared library (without prefix/suffix). The scaffold
## builds a library named lib<name>.so / <name>.dll / lib<name>.dylib.
var extension_name: String = "hp_gdscript"

## Auto-build after code generation. If false, the user must build manually.
var auto_build: bool = true

## Build timeout in seconds. A hanging compiler blocks the editor less hard
## with a limit here.
var build_timeout_sec: int = 300

## Godot version triplet used by godot-cpp (must match the engine the project
## targets + the godot-cpp you provide). Example: "4.3.1".
var godot_version: String = "4.3.1"

## godot-cpp source dir. The scaffold expects godot-cpp next to the extension
## workspace. If empty, we only scaffold and let the user provide godot-cpp
## manually (advanced path). If set, we create the symlink/copy when scaffolding.
var godot_cpp_dir: String = ""

## Verbosity of converter output shown in the panel.
var verbose_converter: bool = true
