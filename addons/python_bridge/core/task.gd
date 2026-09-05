class_name PythonBridgeTask
extends RefCounted
## A single unit of work submitted to the Python Bridge.
##
## Lifecycle (managed exclusively by PythonBridgeTaskManager):
##   QUEUED -> RUNNING -> COMPLETED | FAILED | CANCELLED | TIMEOUT
##
## Task IDs are unique per bridge lifetime. `instance_id` selects a specific
## instance; empty string means "auto-assign to any ready instance".
## `priority` is an integer where 0 is the highest priority.
## `timeout_ms` bounds the EXECUTION time (measured from RUNNING); waiting
## for a worker slot is bounded separately by the queue timeout (see
## task manager). `batchable` allows the scheduler to merge this task into a
## batch frame.
##
## Source handling (Code Plane / ScriptRegistry):
##   - `source` is the inline source that *defines* a context (first call,
##     changed script, temp code).
##   - `source_hash` is its SHA-256. When the target instance already has
##     this context+hash defined (registry), the dispatcher may drop the
##     inline source and reference only the hash.
##   - `_source_sent` records whether the last built message carried the
##     source (used to confirm the registry after an ok result).

enum State { QUEUED, RUNNING, COMPLETED, FAILED, CANCELLED, TIMEOUT }

signal done(result: PythonBridgeResult)

var id: String = ""
var instance_id: String = ""          # "" = auto-assign
var priority: int = 0                 # 0 = highest
var created_at_ms: int = 0
var queued_at_ms: int = 0             # last entry into the queue (timeout anchor)
var state: int = State.QUEUED
var command: String = PythonProtocol.CMD_RUN  # run | call | define
var context_id: String = ""
var source: String = ""               # inline source (defines / temp code)
var source_hash: String = ""          # sha256 of source (ScriptRegistry)
var input: Variant = null             # run: the `input` variable
var function: String = ""             # call: function name
var args: Array = []                  # call: positional args
var kwargs: Dictionary = {}           # call: keyword args
var timeout_ms: int = 0               # execution timeout, counted from RUNNING
var started_at_ms: int = 0            # set when the task transitions to RUNNING
var max_retries: int = 0
var retries_left: int = 0
var retry_policy: String = "connection_error"
var batchable: bool = true
var cancel_requested: bool = false
var result: PythonBridgeResult = null
var meta: Dictionary = {}

## Internal bookkeeping (task manager / scheduler)
var _seq: int = 0                     # stable ordering tiebreaker
var _next_attempt_ms: int = 0         # retry delay; 0 = ready now
var _source_sent: bool = false        # last built message carried the source
var _source_resent: bool = false      # one-shot SCRIPT_NOT_DEFINED recovery
var _force_source: bool = false       # rebuild with source even if defined

func is_terminal() -> bool:
	return state in [State.COMPLETED, State.FAILED, State.CANCELLED, State.TIMEOUT]

func is_queued() -> bool:
	return state == State.QUEUED

func state_text() -> String:
	match state:
		State.QUEUED: return "queued"
		State.RUNNING: return "running"
		State.COMPLETED: return "completed"
		State.FAILED: return "failed"
		State.CANCELLED: return "cancelled"
		State.TIMEOUT: return "timeout"
	return "unknown"

## Convenience builder for call tasks (used by call_script etc.).
static func make_call(p_call_id: String, p_context: String, p_source: String, p_function: String, p_args: Array, p_kwargs: Dictionary, p_timeout_ms: int, p_priority := 0) -> PythonBridgeTask:
	var t := PythonBridgeTask.new()
	t.id = p_call_id
	t.command = PythonProtocol.CMD_CALL
	t.context_id = p_context
	t.source = p_source
	t.function = p_function
	t.args = p_args
	t.kwargs = p_kwargs
	t.timeout_ms = p_timeout_ms
	t.priority = p_priority
	return t

## Convenience builder for run tasks (used by execute / execute_script).
static func make_run(p_call_id: String, p_context: String, p_source: String, p_input: Variant, p_timeout_ms: int, p_priority := 0) -> PythonBridgeTask:
	var t := PythonBridgeTask.new()
	t.id = p_call_id
	t.command = PythonProtocol.CMD_RUN
	t.context_id = p_context
	t.source = p_source
	t.input = p_input
	t.timeout_ms = p_timeout_ms
	t.priority = p_priority
	return t

## Convenience builder for define tasks (preload a script into a context).
static func make_define(p_call_id: String, p_context: String, p_source: String, p_timeout_ms: int, p_priority := 0) -> PythonBridgeTask:
	var t := PythonBridgeTask.new()
	t.id = p_call_id
	t.command = PythonProtocol.CMD_DEFINE
	t.context_id = p_context
	t.source = p_source
	t.timeout_ms = p_timeout_ms
	t.priority = p_priority
	return t
