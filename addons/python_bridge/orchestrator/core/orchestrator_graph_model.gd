class_name OrchestratorGraphModel
extends Resource
## Serialisierbares Modell des visuellen Node-Graphen (Auftrag §3).
##
## Reines Datenmodell ohne UI-Abhängigkeit: Knoten (Node) und Verbindungen
## (Connection). Die Editor-UI rendert daraus GraphNodes; die Runtime-Logik
## (Scheduler/Task-/Server-/File-Manager) ist bewusst getrennt (Auftrag §23).
## Der Graph ist speicher- und ladbar.

enum NodeType { TASK, ROUTER, SERVER, FILE_TRANSFER, CLUSTER }

const TYPE_TEXT := {
	NodeType.TASK: "Task",
	NodeType.ROUTER: "Router",
	NodeType.SERVER: "Server",
	NodeType.FILE_TRANSFER: "FileTransfer",
	NodeType.CLUSTER: "Cluster",
}

@export var nodes: Array = []           # [{id, type, title, position:[x,y], data:{}}]
@export var connections: Array = []     # [{from, to, kind}]


func _init() -> void:
	nodes = []
	connections = []


static func type_text(t: int) -> String:
	return str(TYPE_TEXT.get(t, "Unknown"))


# ---------------------------------------------------------------- Knoten
func add_node(id: String, type: int, title := "", position := Vector2.ZERO, data := {}) -> Dictionary:
	if id == "" or has_node(id):
		return {}
	var node := {
		"id": id,
		"type": type,
		"title": title if title != "" else id,
		"position": [position.x, position.y],
		"data": data.duplicate(true),
	}
	nodes.append(node)
	return node


func remove_node(id: String) -> bool:
	var index := _node_index(id)
	if index < 0:
		return false
	nodes.remove_at(index)
	# Verbindungen dieses Knotens mit entfernen.
	var kept: Array = []
	for c in connections:
		if str(c.get("from", "")) != id and str(c.get("to", "")) != id:
			kept.append(c)
	connections = kept
	return true


func has_node(id: String) -> bool:
	return _node_index(id) >= 0


func get_node_data(id: String) -> Dictionary:
	var index := _node_index(id)
	return nodes[index] if index >= 0 else {}


func get_position(id: String) -> Vector2:
	var node := get_node_data(id)
	var p: Array = node.get("position", [0, 0])
	return Vector2(float(p[0]), float(p[1]))


func set_position(id: String, position: Vector2) -> bool:
	var index := _node_index(id)
	if index < 0:
		return false
	nodes[index]["position"] = [position.x, position.y]
	return true


func node_count() -> int:
	return nodes.size()


# ---------------------------------------------------------------- Verbindungen
func connect_nodes(from_id: String, to_id: String, kind := "route") -> bool:
	if from_id == "" or to_id == "" or from_id == to_id:
		return false
	if not has_node(from_id) or not has_node(to_id):
		return false
	if has_connection(from_id, to_id):
		return false
	connections.append({"from": from_id, "to": to_id, "kind": kind})
	return true


func disconnect_nodes(from_id: String, to_id: String) -> bool:
	for i in range(connections.size() - 1, -1, -1):
		var c: Dictionary = connections[i]
		if str(c.get("from", "")) == from_id and str(c.get("to", "")) == to_id:
			connections.remove_at(i)
			return true
	return false


func has_connection(from_id: String, to_id: String) -> bool:
	for c in connections:
		if str(c.get("from", "")) == from_id and str(c.get("to", "")) == to_id:
			return true
	return false


func connection_count() -> int:
	return connections.size()


# ---------------------------------------------------------------- Serialisierung
func to_dict() -> Dictionary:
	return {
		"version": 1,
		"nodes": nodes.duplicate(true),
		"connections": connections.duplicate(true),
	}


static func from_dict(data: Dictionary) -> OrchestratorGraphModel:
	var model := OrchestratorGraphModel.new()
	model.nodes = (data.get("nodes", []) as Array).duplicate(true)
	model.connections = (data.get("connections", []) as Array).duplicate(true)
	return model


func save_json(path: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(to_dict(), "\t"))
	file.close()
	return OK


static func load_json(path: String) -> OrchestratorGraphModel:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		return from_dict(parsed as Dictionary)
	return null


func _node_index(id: String) -> int:
	for i in nodes.size():
		if str((nodes[i] as Dictionary).get("id", "")) == id:
			return i
	return -1
