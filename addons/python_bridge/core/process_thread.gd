class_name BridgeProcess
extends RefCounted
## Startet einen Subprozess NICHT-blockierend per `OS.create_process`.
##
## Kein Thread noetig: Der Prozess laeuft unabhaengig weiter. Das
## unbeabsichtigte Ende des Prozesses wird nicht ueber Exit-Codes erkannt,
## sondern ueber den Zustand der WebSocket-Verbindung (siehe bridge_instance.gd).
## Die PID wird gespeichert, damit bei Bedarf `kill()` moeglich ist.

var pid: int = -1

func start(command: PackedStringArray) -> bool:
	pid = OS.create_process(command[0], command.slice(1))
	return pid != -1

func is_running() -> bool:
	return pid > 0

func kill() -> void:
	if pid <= 0:
		return
	if OS.get_name() == "Windows":
		var args := PackedStringArray(["/PID", str(pid), "/F"])
		OS.execute("taskkill", args, [], true)
	else:
		var args := PackedStringArray(["-9", str(pid)])
		OS.execute("kill", args, [], true)