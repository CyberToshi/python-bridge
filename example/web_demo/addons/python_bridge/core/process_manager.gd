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

## Optional command-line marker (e.g. "--tag <instance>") used for a targeted
## host-side pkill when the process was launched through flatpak-spawn: the
## host child is not a child of our pid, so killing the spawn pid alone would
## orphan the actual server process.
var kill_marker: String = ""

## Starts the subprocess. Returns true when OS accepted the launch.
## In a flatpak sandbox the command is transparently re-routed to the host
## via `flatpak-spawn --host`: the sandbox runtime ships its own Python,
## which cannot use a venv created by the host interpreter (site-packages
## mismatch). Running the whole bridge process tree on the host keeps venv,
## pip and the server consistent.
func start(command: PackedStringArray) -> bool:
	var argv := wrap_argv(command)
	pid = OS.create_process(argv[0], argv.slice(1))
	return pid != -1

## True when the editor/game itself runs inside a flatpak sandbox.
static func in_flatpak() -> bool:
	if OS.get_environment("FLATPAK_ID") != "":
		return true
	return FileAccess.file_exists("/.flatpak-info")

## Returns `argv` unchanged outside flatpak; inside a sandbox it prefixes
## `flatpak-spawn --host` so the command executes on the host. Paths under
## `/run/host/` (the sandbox's view of the host filesystem) are translated
## back to their real host paths, since they do not exist on the host itself.
static func wrap_argv(argv: PackedStringArray) -> PackedStringArray:
	if not in_flatpak():
		return argv
	var out := PackedStringArray()
	out.append("flatpak-spawn")
	out.append("--host")
	for a in argv:
		out.append(_to_host_path(a))
	return out

## Maps `/run/host/<path>` -> `<path>`; other strings pass through.
static func _to_host_path(s: String) -> String:
	if s.begins_with("/run/host/"):
		return s.substr("/run/host".length())
	return s

## Non-blocking spawn of a full argv (path + args), flatpak-aware.
## Returns the pid, or -1 when the launch failed.
static func spawn(argv: PackedStringArray) -> int:
	var wrapped := wrap_argv(argv)
	return OS.create_process(wrapped[0], wrapped.slice(1))

## Blocking-ish OS.execute with a full argv (path + args), flatpak-aware.
## Mirrors OS.execute return semantics (exit code, -1 on failure).
static func execute(argv: PackedStringArray, out: Array, read_stderr := true) -> int:
	var wrapped := wrap_argv(argv)
	return OS.execute(wrapped[0], wrapped.slice(1), out, read_stderr)

func is_running() -> bool:
	if pid <= 0:
		return false
	# Only safe for PIDs we spawned ourselves (OS limitation). Falls back to
	# "running" when the API is unavailable so callers still force-kill after
	# their timeout (no zombie risk).
	if OS.has_method("is_process_running"):
		return OS.is_process_running(pid)
	return true

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
		if in_flatpak() and kill_marker != "":
			# flatpak-spawn reparents the command to the host; make sure the
			# real server process dies too (kill -9 on our pid only kills the
			# spawn wrapper).
			var pargs := PackedStringArray(["--host", "pkill", "-9", "-f", "--", kill_marker])
			OS.execute("flatpak-spawn", pargs, [], true)

## Releases the stored PID without touching the process (used after the
## process ended naturally).
func forget() -> void:
	pid = -1