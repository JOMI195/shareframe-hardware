# s6 finish hook of the app services: restarts and crashes to the event log, crashes counted.
load ../../support/common

setup() {
	sf_setup
	export DATA_DIR="$T" SVC="$T/service"
	stub shareframe-event
	quiet_stub s6-svstat 'echo true'
}

finish() { "$S6/service-finish" shareframe-display "$@"; }

@test "a crash is logged with its cause, counted, and reported to the caller" {
	run finish 139
	assert_failure 2
	assert_called 'shareframe-event crash shareframe-display exit code 139'
	run finish 256 11
	assert_failure 2
	assert_called 'shareframe-event crash shareframe-display signal 11'
	assert_equal "$(cat "$T/crash_count")" 2
}

@test "a restart by signal and a clean exit are logged, not counted" {
	finish 256 15
	finish 0
	assert_called 'shareframe-event service shareframe-display restarted (signal 15)'
	assert_called 'shareframe-event service shareframe-display exited cleanly'
	assert_file_not_exists "$T/crash_count"
}

@test "a service taken down on purpose stays silent" {
	quiet_stub s6-svstat 'echo false'
	finish 1
	assert_file_not_exists "$CALLS"
}
