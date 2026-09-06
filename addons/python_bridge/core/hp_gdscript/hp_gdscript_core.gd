class_name PythonBridgeHPCore
extends RefCounted
## Orchestrates the high-performance path:
##   GDScript (res://...) -> GDScript2All converter -> C++ (.hpp/.cpp)
##   -> GDExtension scaffold (.gdextension + SConscript-ready src/)
##   -> optional build.
##
## This module is intentionally thin. It does NOT contain a custom transpiler.
## It shells out to the bundled GDScript2All converter and adds the missing
## GDExtension scaffolding that the upstream converter does not (reliably)
## produce.

var config: PythonBridgeHPCfg
var _workspace_dir: String = ""
var _extension_dir: String = ""
var _last_error: String = ""
var _last_log: PackedStringArray = []

func _init(cfg: PythonBridgeHPCfg = null) -> void:
	config = cfg if cfg != null else PythonBridgeHPCfg.new()

## ----------------------------------------------------------------- public API

## Convert one or more GDScript files/folders to C++ and scaffold the
## GDExtension workspace under config.workspace_dir.
## Returns OK on success, an Error code otherwise.
## Logs are captured in _last_log; errors in _last_error.
func convert_and_scaffold(scripts: PackedStringArray) -> Error:
	_last_error = ""
	_last_log = []
	if scripts.is_empty():
		_last_error = "hp_gdscript: no scripts selected"
		return ERR_PARSE_ERROR

	var workspace := _resolve_workspace_dir()
	if workspace == "":
		return ERR_FILE_NOT_FOUND

	var converter := _converter_path()
	if converter == "":
		_last_error = "hp_gdscript: GDScript2All converter not found at: " + config.converter_main_py
		return ERR_FILE_NOT_FOUND

	# 1) run the upstream C++ converter (output dir is an absolute OS path)
	var out_dir_abs := _workspace_dir.path_join("_generated/src")
	var err := _run_converter(converter, scripts, out_dir_abs)
	if err != OK:
		return err

	# 2) scaffold GDExtension wrapper around the generated C++
	err = _scaffold(workspace, out_dir_abs)
	if err != OK:
		return err

	# 3) optional build
	if config.auto_build:
		err = _build()
		if err != OK:
			return err

	return OK

## Build the GDExtension in the workspace, if it is scaffolded.
func build() -> Error:
	_last_error = ""
	_last_log = []
	var workspace := _resolve_workspace_dir()
	if workspace == "":
		return ERR_FILE_NOT_FOUND
	return _build()

## Open the workspace folder in the OS file manager.
func reveal_workspace() -> void:
	var workspace := _resolve_workspace_dir()
	if workspace == "":
		return
	OS.shell_open(workspace)

## ----------------------------------------------------------------- internals

func _resolve_workspace_dir() -> String:
	var rel := config.workspace_dir as String
	if not rel.begins_with("res://"):
		rel = "res://" + rel
	_workspace_dir = ProjectSettings.globalize_path(rel)
	_extension_dir = _workspace_dir.path_join(config.extension_name)
	return _workspace_dir

func _converter_path() -> String:
	var rel := config.converter_main_py as String
	if FileAccess.file_exists(rel):
		return ProjectSettings.globalize_path(rel)
	return ""

func _run_converter(converter: String, scripts: PackedStringArray, out_dir_abs: String) -> Error:
	var exe := config.python_exe if config.python_exe != "" else "python3"
	# NOTE: arguments must NOT repeat the executable itself.
	var cmd := PackedStringArray()
	cmd.append(converter)
	for s in scripts:
		cmd.append(s)
	cmd.append("-t")
	cmd.append("Cpp")
	cmd.append("-o")
	cmd.append(out_dir_abs)
	if config.verbose_converter:
		cmd.append("-v")

	_last_log.append("[hp_gdscript] running converter: " + exe + " " + _cmd_to_str(cmd) + "\n")

	var output: Array = []
	var res := _exec(exe, cmd, output)
	if res == -1:
		# interpreter not found -> try common alternatives
		res = _exec("python", cmd, output)
	if res == -1:
		res = _exec("py", cmd, output)

	if output.size() > 0:
		_last_log.append("--- converter output ---")
		for line in output:
			_last_log.append(str(line) + "\n")
		_last_log.append("--- end converter output ---\n")

	if res != 0:
		_last_error = "hp_gdscript: converter exited with error code " + str(res)
		return ERR_CANT_CREATE

	# verify the converter produced at least one file
	var gen_src := out_dir_abs
	var d := DirAccess.open(gen_src)
	if d == null:
		_last_error = "hp_gdscript: converter finished but no output dir: " + gen_src
		return ERR_FILE_NOT_FOUND
	var found := false
	d.list_dir_begin()
	var fname := d.get_next()
	while fname != "":
		if not d.current_is_dir():
			found = true
			break
		fname = d.get_next()
	d.list_dir_end()
	if not found:
		_last_error = "hp_gdscript: converter produced no files in " + gen_src
		return ERR_FILE_NOT_FOUND
	return OK

func _scaffold(_workspace: String, generated_src_abs: String) -> Error:
	# Ensure directory layout:
	#   <workspace>/<extension_name>/
	#     <extension_name>.gdextension
	#     SConstruct
	#     src/
	#        SConscript
	#        register_types.h / register_types.cpp
	var ext_dir := _extension_dir
	var err := DirAccess.make_dir_recursive_absolute(ext_dir)
	if err != OK:
		_last_error = "hp_gdscript: could not create extension dir " + ext_dir
		return err

	# Write .gdextension
	var gdext := _gdextension_content()
	var gdext_path := ext_dir.path_join(config.extension_name + ".gdextension")
	var f := FileAccess.open(gdext_path, FileAccess.WRITE)
	if f == null:
		_last_error = "hp_gdscript: could not write " + gdext_path
		return ERR_CANT_OPEN
	f.store_string(gdext)
	f.close()

	# Write SConstruct (root) so a build can succeed once godot-cpp is present.
	var sconstruct := _sconstruct_content(generated_src_abs)
	var sc_path := ext_dir.path_join("SConstruct")
	f = FileAccess.open(sc_path, FileAccess.WRITE)
	if f == null:
		_last_error = "hp_gdscript: could not write " + sc_path
		return ERR_CANT_OPEN
	f.store_string(sconstruct)
	f.close()

	err = DirAccess.make_dir_recursive_absolute(ext_dir.path_join("src"))
	if err != OK:
		_last_error = "hp_gdscript: could not create src dir"
		return err

	var sconscript := _sconscript_content()
	var scp_path := ext_dir.path_join("src/SConscript")
	f = FileAccess.open(scp_path, FileAccess.WRITE)
	if f == null:
		_last_error = "hp_gdscript: could not write " + scp_path
		return ERR_CANT_OPEN
	f.store_string(sconscript)
	f.close()

	var rt_h := _register_types_h_content()
	f = FileAccess.open(ext_dir.path_join("src/register_types.h"), FileAccess.WRITE)
	if f == null:
		_last_error = "hp_gdscript: could not write register_types.h"
		return ERR_CANT_OPEN
	f.store_string(rt_h)
	f.close()

	var rt_cpp := _register_types_cpp_content()
	f = FileAccess.open(ext_dir.path_join("src/register_types.cpp"), FileAccess.WRITE)
	if f == null:
		_last_error = "hp_gdscript: could not write register_types.cpp"
		return ERR_CANT_OPEN
	f.store_string(rt_cpp)
	f.close()

	_last_log.append("[hp_gdscript] scaffold written to " + ext_dir + "\n")
	return OK

func _gdextension_content() -> String:
	# Library paths inside a .gdextension file are res:// relative.
	var lib := config.workspace_dir.path_join(config.extension_name)
	var plat := OS.get_name()
	var suffix := ".so"
	if plat == "Windows":
		suffix = ".dll"
	elif plat == "macOS":
		suffix = ".dylib"
	var content := "[configuration]\nentry_symbol = \"gdextension_init\"\ncompatibility_minimum = \"4.3\"\n\n[libraries]\n"
	content += "linux.x86_64 = \"" + lib + "/bin/linux.x86_64/lib" + config.extension_name + suffix + "\"\n"
	content += "windows.x86_64 = \"" + lib + "/bin/windows.x86_64/" + config.extension_name + suffix + "\"\n"
	content += "macos.universal = \"" + lib + "/bin/macos.universal/lib" + config.extension_name + suffix + "\"\n"
	return content

func _sconstruct_content(generated_src_abs: String) -> String:
	var src := generated_src_abs.replace("\\", "/")
	var sconstruct := "import os\n\n"
	sconstruct += "# godot-cpp path: override with GODOT_CPP env var or edit here.\n"
	sconstruct += "godot_cpp = os.environ.get('GODOT_CPP', '../../../godot-cpp')\n\n"
	sconstruct += "env = SConscript(os.path.join(godot_cpp, 'SConstruct'))\n\n"
	sconstruct += "env.Append(CPPPATH=[\n"
	sconstruct += "    'src/',\n"
	sconstruct += "    r'" + src + "',\n"
	sconstruct += "])\n\n"
	sconstruct += "sources = ['src/register_types.cpp']\n"
	sconstruct += "for root, dirs, files in os.walk(r'" + src + "'):\n"
	sconstruct += "    for f in files:\n"
	sconstruct += "        if f.endswith(('.cpp', '.cc')):\n"
	sconstruct += "            sources.append(os.path.join(root, f))\n\n"
	sconstruct += "if env['platform'] == 'macos':\n"
	sconstruct += "    library = env.SharedLibrary('#bin/lib" + config.extension_name + "', source=sources)\n"
	sconstruct += "else:\n"
	sconstruct += "    library = env.SharedLibrary('#bin/${LIBPREFIX}" + config.extension_name + "${LIBSUFFIX}', source=sources)\n"
	sconstruct += "Default(library)\n"
	return sconstruct

func _sconscript_content() -> String:
	return "Import('env')\nenv.Append(CPPPATH=['#src/'])\n"

func _register_types_h_content() -> String:
	return """#ifndef HP_GDSCRIPT_REGISTER_TYPES_H
#define HP_GDSCRIPT_REGISTER_TYPES_H

#include <godot_cpp/godot.hpp>

namespace hp_gdscript {
	void initialize_hp_gdscript(godot::ModuleInitializationLevel p_level);
	void uninitialize_hp_gdscript(godot::ModuleInitializationLevel p_level);
}

#endif
"""

func _register_types_cpp_content() -> String:
	return """#include "register_types.h"
#include <godot_cpp/core/class_db.hpp>

namespace hp_gdscript {
	void initialize_hp_gdscript(godot::ModuleInitializationLevel p_level) {
		if (p_level != godot::MODULE_INITIALIZATION_LEVEL_SCENE) return;
		// Generated classes are registered by their register_class<> calls.
	}
	void uninitialize_hp_gdscript(godot::ModuleInitializationLevel p_level) {
		(void)p_level;
	}
}

extern "C" {
	// GDExtension entry point.
	GDExtensionBool GDE_EXPORT hp_gdscript_init(
			GDExtensionInterfaceGetProcAddress p_get_proc_address,
			GDExtensionClassLibraryPtr p_library,
			GDExtensionInitialization *r_initialization) {
		godot::GDExtensionBinding::InitObject init_obj(
				p_get_proc_address, p_library, r_initialization);
		init_obj.register_initializer(hp_gdscript::initialize_hp_gdscript);
		init_obj.register_terminator(hp_gdscript::uninitialize_hp_gdscript);
		return init_obj.init();
	}
}
"""

func _build() -> Error:
	var ext_dir := _extension_dir
	var sc_path := ext_dir.path_join("SConstruct")
	if not FileAccess.file_exists(sc_path):
		_last_error = "hp_gdscript: no SConstruct in " + ext_dir + " - scaffold first"
		return ERR_FILE_NOT_FOUND

	var cmd := PackedStringArray()
	cmd.append("--directory=" + ext_dir)
	cmd.append("platform=" + _platform_name())
	cmd.append("target=template_debug")

	_last_log.append("[hp_gdscript] building: scons " + _cmd_to_str(cmd) + "\n")

	var output: Array = []
	var res := _exec("scons", cmd, output)
	if output.size() > 0:
		_last_log.append("--- build output ---")
		for line in output:
			_last_log.append(str(line) + "\n")
		_last_log.append("--- end build output ---\n")

	if res == -1:
		_last_error = "hp_gdscript: 'scons' executable not found on PATH"
		return ERR_FILE_NOT_FOUND
	if res != 0:
		_last_error = "hp_gdscript: build failed (exit " + str(res) + ")"
		return ERR_CANT_CREATE

	_last_log.append("[hp_gdscript] build OK\n")
	return OK

func _platform_name() -> String:
	var plat := OS.get_name()
	if plat == "Windows":
		return "windows"
	if plat == "macOS":
		return "macos"
	return "linux"

## OS.execute with a full argv (executable first), flatpak-aware: inside a
## sandbox the command is re-routed to the host so the same toolchain is
## used that owns the project venv / godot-cpp checkout.
func _exec(exe: String, args: PackedStringArray, out: Array) -> int:
	var argv := PackedStringArray([exe])
	argv.append_array(args)
	return BridgeProcessManager.execute(argv, out, true)

## Space-join helper: PackedStringArray has no join() in Godot 4.x.
func _cmd_to_str(cmd: PackedStringArray) -> String:
	var s := ""
	for i in cmd.size():
		if i > 0:
			s += " "
		s += cmd[i]
	return s

## read-only logs
func last_error() -> String:
	return _last_error

func last_log() -> PackedStringArray:
	return _last_log
