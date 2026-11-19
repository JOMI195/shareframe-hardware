# Remote safe mode: the server can stop the display on purpose, across reboots.
load ../../support/common

NAP=86399

setup() {
	sf_setup
	for cmd in shareframe-event shareframe-led s6-svc; do stub "$cmd"; done
	export DATA_DIR="$T/data" RUN_DIR="$T/run" PENDING_FILE="$T/pending" CMDLINE="$T/cmdline"
	mkdir -p "$DATA_DIR" "$RUN_DIR"
	printf 'console=ttyS1,115200 rauc.slot=A\n' > "$CMDLINE"
}

teardown() { pkill -f "sleep $NAP" || true; }

boot() { # [clean]
	rm -rf "$RUN_DIR" && mkdir -p "$RUN_DIR"
	[ "${1:-}" = clean ] || : > "$RUN_DIR/unclean-boot"
	STABLE=$NAP "$S6/boot-guard" 3>&-
}

@test "enter stops the display, persists the marker and logs it, without a panel clear" {
	shareframe-safe-mode enter >/dev/null
	assert_file_exists "$DATA_DIR/safe-mode-remote"
	assert_equal "$(cat "$RUN_DIR/safe-mode")" remote
	assert_called 's6-svc -d /run/service/shareframe-display'
	assert_called 'shareframe-event safe-mode remote: display disabled'
	assert_file_not_exists "$RUN_DIR/safe-mode-clear"
}

@test "remote safe mode survives clean boots and a boot loop keeps its reason" {
	shareframe-safe-mode enter >/dev/null
	boot clean
	assert_equal "$(cat "$RUN_DIR/safe-mode")" remote
	assert_file_not_exists "$RUN_DIR/safe-mode-clear"
	for _ in 1 2 3 4 5; do boot; done
	assert_equal "$(cat "$RUN_DIR/safe-mode")" remote
	assert_file_not_exists "$RUN_DIR/safe-mode-clear"
}

@test "a trial boot runs the display, and enter is refused there with a reason" {
	shareframe-safe-mode enter >/dev/null
	echo A > "$PENDING_FILE"
	boot clean
	assert_file_not_exists "$RUN_DIR/safe-mode"
	rm -f "$CALLS"
	run shareframe-safe-mode enter
	assert_failure 1
	assert_output --partial 'not confirmed'
	refute_called s6-svc
}

@test "exit lifts a boot-loop safe mode, resets the counter, restarts the display" {
	for _ in 1 2 3 4 5; do boot; done
	shareframe-safe-mode exit >/dev/null
	assert_file_not_exists "$RUN_DIR/safe-mode"
	assert_equal "$(cat "$DATA_DIR/short_boots")" 0
	assert_called 's6-svc -u /run/service/shareframe-display'
	assert_called 'shareframe-led refresh'
}

@test "exit removes the remote marker, so the next boot runs the display" {
	shareframe-safe-mode enter >/dev/null
	shareframe-safe-mode exit >/dev/null
	assert_file_not_exists "$DATA_DIR/safe-mode-remote"
	boot clean
	assert_file_not_exists "$RUN_DIR/safe-mode"
}

@test "exit outside safe mode says so and touches nothing" {
	echo 3 > "$DATA_DIR/short_boots"
	echo 1000 > "$RUN_DIR/display-crashes"
	run shareframe-safe-mode exit
	assert_output 'not in safe mode'
	assert_equal "$(cat "$DATA_DIR/short_boots")" 3
	assert_file_exists "$RUN_DIR/display-crashes"
	assert_file_not_exists "$CALLS"
}

@test "a second enter says so and touches nothing" {
	shareframe-safe-mode enter >/dev/null
	rm -f "$CALLS"
	run shareframe-safe-mode enter
	assert_output 'already in safe mode'
	assert_file_not_exists "$CALLS"
}

@test "enter over an automatic safe mode makes it remote and persistent" {
	echo display-crash > "$RUN_DIR/safe-mode"
	shareframe-safe-mode enter >/dev/null
	assert_equal "$(cat "$RUN_DIR/safe-mode")" remote
	assert_file_exists "$DATA_DIR/safe-mode-remote"
}

@test "the reset counter is on the card before a power cut can bring the old streak back" {
	for _ in 1 2 3 4 5; do boot; done
	sync_records "$DATA_DIR/short_boots"
	shareframe-safe-mode exit >/dev/null
	synced 0
}
