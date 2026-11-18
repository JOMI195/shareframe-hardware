# The persistent event log: numbered lines that the heartbeat forwards since its last cursor.
load ../../support/common

setup() {
	sf_setup
	fixed_clock
	stub logger
	export DATA_DIR="$T/data"
	LOG="$DATA_DIR/health.log"
}

@test "events get increasing numbers, the time and their source" {
	shareframe-event wifi connected
	shareframe-event update installing 1.1.0
	run cat "$LOG"
	assert_line --index 0 --regexp '^1 [0-9T:-]+ \[wifi\] connected$'
	assert_line --index 1 --regexp '^2 [0-9T:-]+ \[update\] installing 1\.1\.0$'
	assert_called 'logger -t shareframe-wifi connected'
}

@test "parallel writers never share a number" {
	for i in $(seq 1 20); do shareframe-event load "event $i" & done
	wait
	assert_equal "$(cut -d' ' -f1 "$LOG" | sort -n | uniq | wc -l | tr -d ' ')" 20
}

@test "--since prints only newer events" {
	for i in 1 2 3; do shareframe-event wifi "event $i"; done
	run shareframe-event --since 1
	assert_equal "$(echo "$output" | cut -d' ' -f1 | tr '\n' ' ')" '2 3 '
}

@test "a cursor beyond a wiped log starts over instead of hiding new events" {
	shareframe-event wifi first
	run shareframe-event --since 400
	assert_output --regexp '^1 .* first$'
}

@test "the log is trimmed to half when it outgrows its limit" {
	export LOG_MAX_LINES=10
	for i in $(seq 1 11); do shareframe-event wifi "event $i"; done
	assert_equal "$(wc -l < "$LOG" | tr -d ' ')" 5
	assert_equal "$(tail -1 "$LOG" | cut -d' ' -f1)" 11
}

@test "a call without a message is a usage error" {
	run shareframe-event wifi
	assert_failure 2
}

# bats test_tags=contract
@test "golden event-since.txt: the lines the heartbeat parses" {
	shareframe-event boot clean boot 12
	shareframe-event wifi ap fallback '(no address from home)'
	shareframe-event remote 'reboot requested by server'
	shareframe-event --since 0 > "$T/since"
	assert_golden event-since.txt "$T/since"
}
