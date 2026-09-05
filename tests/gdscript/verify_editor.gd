extends SceneTree
## Editor verification: checks that the Python Bridge plugin registered its
## autoload and that the editor dock panel exists.
## Run: godot --headless --editor --path . --script res://tests/gdscript/verify_editor.gd

func _initialize() -> void:
	await process_frame
	await process_frame
	var ok := true

	# 1) Autoload singleton must exist and be the facade script.
	var pb := root.get_node_or_null("PythonBridge")
	if pb == null:
		print("[VERIFY] FAIL: autoload PythonBridge missing")
		ok = false
	else:
		print("[VERIFY] OK: autoload PythonBridge present (script: ",
			pb.get_script().resource_path, ")")

	# 2) The dock panel must be somewhere under the editor UI, with its
	#    internal controls built (script list, code editor, action buttons).
	var found := _find_named(root, "Python Bridge")
	if found:
		print("[VERIFY] OK: dock panel 'Python Bridge' found at ",
			str(found).get_slice(":", 1))
		var file_list := _find_class(found, "ItemList")
		var code_edit := _find_class(found, "CodeEdit")
		var log_view := _find_class(found, "RichTextLabel")
		if file_list and code_edit and log_view:
			print("[VERIFY] OK: panel UI built (script list + code editor + log present)")
		else:
			print("[VERIFY] FAIL: panel UI incomplete (file_list=", file_list,
				", code_edit=", code_edit, ", log=", log_view, ")")
			ok = false
	else:
		print("[VERIFY] FAIL: dock panel 'Python Bridge' not found in editor UI")
		ok = false

	# 3) Plugin must be enabled in project settings.
	var plugins: PackedStringArray = ProjectSettings.get_setting("editor_plugins/enabled", [])
	if "res://addons/python_bridge/plugin.cfg" in plugins:
		print("[VERIFY] OK: plugin enabled in editor_plugins")
	else:
		print("[VERIFY] FAIL: plugin not in editor_plugins: ", plugins)
		ok = false

	print("[VERIFY] RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _find_named(node: Node, name: String) -> Node:
	if node.name == name:
		return node
	for child in node.get_children():
		var hit := _find_named(child, name)
		if hit != null:
			return hit
	return null

func _find_class(node: Node, cls: String) -> Node:
	if node.get_class() == cls:
		return node
	for child in node.get_children():
		var hit := _find_class(child, cls)
		if hit != null:
			return hit
	return null