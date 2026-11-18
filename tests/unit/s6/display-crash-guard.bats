# LIMIT display crashes within WINDOW seconds put the display into safe mode until reboot.
load ../../support/common

setup() {
	sf_setup
	for cmd in shareframe-event shareframe-led s6-svc; do stub "$cmd"; done
	export DATA_DIR="$T/data" RUN_DIR="$T/run" UPTIME="$T/uptime" PENDING_FILE="$T/pending" CMDLINE="$T/cmdline"
	mkdir -p "$DATA_DIR" "$RUN_DIR"
	printf 'console=ttyS1,115200 rauc.slot=A\n' > "$CMDLINE"
}

crash() { echo "$1.42 100.0" > "$UPTIME"; "$S6/display-crash-guard"; }

@test "crashes older than the window are forgotten" {
	printf '10\n20\n' > "$RUN_DIR/display-crashes"
	for t in 1000 1010 1020 1030; do crash "$t"; done
	assert_equal "$(wc -l < "$RUN_DIR/display-crashes" | tr -d ' ')" 4
	assert_file_not_exists "$RUN_DIR/safe-mode"
}

@test "the fifth crash in the window trips safe mode with a panel clear" {
	for t in 1000 1010 1020 1030 1040; do crash "$t"; done
	assert_equal "$(cat "$RUN_DIR/safe-mode")" display-crash
	assert_file_exists "$RUN_DIR/safe-mode-clear"
}
