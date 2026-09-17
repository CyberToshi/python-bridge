extends Node

## Minimal Godot-side proof for the new IPC control path over the existing bridge.

## This is intentionally small: it exercises only the metadata control messages
## that were added to the Python-side server (pb_region_meta / pb_region_attach
## / pb_region_release). No shared-memory handling happens in Godot in this
## step the bridge is only used as the control channel.


func _ready() -> void:
	var inst: BridgeInstance = PythonBridge.get_instance("default")
	if inst == null or not inst.is_ready():
		print("[IPCProof] bridge not ready in this test run")
		return

	# 1) Create a typed region through the bridge metadata control path.
	var create_msg := _region_meta("create", {
		"label": "godot/proofbuf",
		"layout": {"dtype": "float64", "items": 1024},
	})
	_await_and_print(inst, create_msg)

	# 2) Attach to the same region by id (metadata-only side channel).
	var list_msg := _region_meta("list")
	_await_and_print(inst, list_msg)

	var describe_msg := _region_meta("describe", {
		"id": _last_created_id,
	})
	_await_and_print(inst, describe_msg)

	# 3) Release the region through the ownership control path.
	var release_msg := _region_meta("release", {
		"id": _last_created_id,
	})
	_await_and_print(inst, release_msg)

	# 4) Descriptors should now be empty after owner release.
	var list_after := _region_meta("list")
	_await_and_print(inst, list_after)


var _last_created_id: String = ""


func _region_meta(action: String, payload: Dictionary = {}) -> Dictionary:
	return {
		"v": PythonProtocol.PROTOCOL_VERSION,
		"type": "pb_region_meta",
		"id": "IPCProof-%d" % Time.get_ticks_msec(),
		"action": action,
	}.duplicate(true).merge(payload)


func _await_and_print(inst: BridgeInstance, msg: Dictionary) -> void:
	var rid: String = _rid()
	_pending_control[rid] = {
		"msg": msg,
		"seen": false,
	}
	if inst.send_message(msg) != OK:
		print("[IPCProof] send failed for ", rid)
		_pending_control.erase(rid)
		return
	await _wait_control_rid(rid, 5.0)
	_pending_control.erase(rid)


var _pending_control: Dictionary = {}


func _rid() -> String:
	return "ipc-%d" % Time.get_ticks_msec()


func _wait_control_rid(rid: String, timeout_sec: float) -> void:
	var waited := 0.0
	while waited < timeout_sec:
		await get_tree().process_frame
		waited += 0.016
		if _pending_control.has(rid):
			var item: Dictionary = _pending_control[rid]
			if item.get("seen", false):
				if item.has("ok") and item["ok"]:
					if (item.get("item", {}) is Dictionary):
						_last_created_id = str((item["item"] as Dictionary).get("id", ""))
					print("[IPCProof] ok:", item.get("action", ""), "->", item.get("item", {}))
				else:
					print("[IPCProof] err:", item.get("action", ""), "->", item.get("error", {}))
				return
	print("[IPCProof] timeout for ", rid)
