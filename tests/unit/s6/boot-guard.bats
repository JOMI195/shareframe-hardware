# Boot-loop guard: LIMIT short unclean boots in a row put the display into safe mode.
load ../../support/common

# boot-guard backgrounds a STABLE-long sleep; a length of its own lets teardown reap it.
NAP=86399

setup() {
	sf_setup
	for cmd in shareframe-event shareframe-led s6-svc; do stub "$cmd"; done
	export DATA_DIR="$T/data" RUN_DIR="$T/run" PENDING_FILE="$T/pending" CMDLINE="$T/cmdline"
	mkdir -p "$DATA_DIR" "$RUN_DIR"
	printf 'console=ttyS1,115200 rauc.slot=A\n' > "$CMDLINE"
}

teardown() { pkill -f "sleep $NAP" || true; }

# One boot: /run starts empty, /data persists.
boot() { # [clean]
	rm -rf "$RUN_DIR" && mkdir -p "$RUN_DIR"
	[ "${1:-}" = clean ] || : > "$RUN_DIR/unclean-boot"
	STABLE=$NAP "$S6/boot-guard" 3>&-
}

@test "four short unclean boots: the display keeps running" {
	for _ in 1 2 3 4; do boot; done
	assert_file_not_exists "$RUN_DIR/safe-mode"
}

@test "the fifth trips safe mode once: reason, panel clear, event, LED" {
	for _ in 1 2 3 4 5; do boot; done
	assert_equal "$(cat "$RUN_DIR/safe-mode")" boot-loop
	assert_file_exists "$RUN_DIR/safe-mode-clear"
	assert_called 'shareframe-event safe-mode boot loop'
	assert_called 'shareframe-led protected'
	boot
	assert_equal "$(cat "$RUN_DIR/safe-mode")" boot-loop
	assert_file_not_exists "$RUN_DIR/safe-mode-clear"
}

@test "a clean boot ends the streak and re-arms the panel clear" {
	for _ in 1 2 3 4 5; do boot; done
	boot clean
	assert_file_not_exists "$RUN_DIR/safe-mode"
	assert_equal "$(cat "$DATA_DIR/short_boots")" 0
	assert_file_not_exists "$DATA_DIR/safe-mode-cleared"
	for _ in 1 2 3 4; do boot; done
	assert_file_not_exists "$RUN_DIR/safe-mode"
}

@test "a trial boot is exempt" {
	for _ in 1 2 3 4; do boot; done
	echo A > "$PENDING_FILE"
	boot
	assert_file_not_exists "$RUN_DIR/safe-mode"
}

streak() { [ "$(cat "$DATA_DIR/short_boots")" = "$1" ]; }

@test "staying up STABLE seconds ends the streak" {
	for _ in 1 2 3 4 5; do boot; done
	rm -rf "$RUN_DIR" && mkdir -p "$RUN_DIR"
	: > "$RUN_DIR/unclean-boot"
	STABLE=1 "$S6/boot-guard" 3>&-
	eventually 3 streak 0
	assert_file_not_exists "$DATA_DIR/safe-mode-cleared"
}
