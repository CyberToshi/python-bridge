@tool
extends Node

func _ready() -> void:
    print("=== FileDialog ===")
    var fd := FileDialog.new()
    for m in fd.get_method_list():
        print(m.name)
    print("=== ItemList ===")
    var il := ItemList.new()
    for m in il.get_method_list():
        print(m.name)
    print("=== ProjectSettings has_setting ===")
    print("has_setting exists: " + str(ProjectSettings.has_setting("does_not_exist")))
    print("=== done ===")
