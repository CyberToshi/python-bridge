class_name BridgeProcessManager
extends RefCounted
## Starts and manages a Python subprocess without blocking the main thread.
##
## Uses OS.create_process (non-blocking). The process runs independently;
## its unexpected end is detected via the WebSocket state (the server closes
## the connection when it dies) and, as a secondary signal, via
## OS.is_process_running(pid). The PID is kept so the instance can kill the
## process (graceful shutdown fallback / zombie prevention).
##
## No shell is involved: arguments are passed as a structured
## PackedStringArray (safe for spaces, umlauts, unicode).

var pid: int = -1

## Starts the subprocess. Returns true when OS accepted the launch.
func start(command: PackedStringArray) -> bool:
	pid = OS.create_process(command[0], command.slice(1))
	return pid != -1

func is_running() -> bool:
	if pid <= 0:
		return false
	# Only safe for PIDs we spawned ourselves (OS limitation).
	return OS.is_process_running(pid)

func get_exit_code() -> int:
	if pid <= 0:
		return -1
	return OS.get_process_exit_code(pid)

## Force-kills the process (taskkill /F on Windows, kill -9 elsewhere).
## Never leaves a zombie behind; safe to call multiple times.
func kill() -> void:
	if pid <= 0:
		return
	if OS.get_name() == "Windows":
		var args := PackedStringArray(["/PID", str(pid), "/F"])
		OS.execute("taskkill", args, [], true)
	else:
		var args := PackedStringArray(["-9", str(pid)])
		OS.execute("kill", args, [], true)

## Releases the stored PID without touching the process (used after the
## process ended naturally).
func forget() -> void:
	pid = -1