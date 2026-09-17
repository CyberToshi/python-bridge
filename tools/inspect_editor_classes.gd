@tool
extends EditorScript

func _run() -> void:
    print("=== FileDialog ===")
    var fd := FileDialog.new()
    for m in fd.get_method_list():
        print(m.name)
    print("=== ItemList ===")
    var il := ItemList.new()
    for m in il.get_method_list():
        print(m.name)
    print("=== ProjectSettings ===")
    for m in ProjectSettings.get_method_list():
        print(m.name)
