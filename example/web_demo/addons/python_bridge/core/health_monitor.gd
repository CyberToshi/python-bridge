class_name BridgeHealthMonitor
extends RefCounted
## Health monitoring for one Python instance.
##
## Sends a PING every `health_check_interval_ms` while the instance is READY
## and tracks whether a PONG arrives. A PONG resets the counter; every full
## interval that passes without one counts as a missed window. When
## `health_missed_pong_limit` windows are missed in a row the instance is
## reported unhealthy so the bridge can trigger the crash/restart policy.
##
## Frame-driven (no threads): tick() is called once per frame from the
## instance while READY.

var _interval_ms: int = 5000
var _missed_pong_limit: int = 3

var _last_ping_ms: int = 0      # when the last PING was sent (0 = none yet)
var _missed_windows: int = 0
var _healthy: bool = true

func _init(interval_ms: int, missed_pong_limit: int) -> void:
	_interval_ms = maxi(interval_ms, 100)
	_missed_pong_limit = maxi(missed_pong_limit, 1)

func reset() -> void:
	_last_ping_ms = 0
	_missed_windows = 0
	_healthy = true

## True when a PING should be sent this frame.
func should_ping(now_ms: int) -> bool:
	return _last_ping_ms == 0 or now_ms - _last_ping_ms >= _interval_ms

func record_ping_sent(now_ms: int) -> void:
	_last_ping_ms = now_ms

func record_pong() -> void:
	_missed_windows = 0
	_healthy = true

## Called each frame while READY. Returns true when still healthy.
func tick(now_ms: int) -> bool:
	if _last_ping_ms <= 0:
		return true
	var elapsed_windows := (now_ms - _last_ping_ms) / _interval_ms
	if elapsed_windows > _missed_windows:
		_missed_windows = elapsed_windows
	if _missed_windows >= _missed_pong_limit:
		_healthy = false
	return _healthy

func is_healthy() -> bool:
	return _healthy

func missed_windows() -> int:
	return _missed_windows