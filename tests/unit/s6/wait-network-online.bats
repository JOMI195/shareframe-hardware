# Gate before the app chain: the internet, the hotspot, or the timeout, whichever comes first.
load ../../support/common

setup() {
	sf_setup
	export RUN_DIR="$T/run" CONSOLE="$T/console" TIMEOUT=3
	mkdir -p "$RUN_DIR"
	quiet_stub sleep 'exit 0'
}

@test "the internet in reach: through at once" {
	stub ping 'exit 0'
	"$S6/wait-network-online"
	assert_equal "$(grep -c '^ping' "$CALLS")" 1
}

@test "on the hotspot there is no upstream to wait for" {
	stub ping 'exit 1'
	echo ap > "$RUN_DIR/wifi-mode"
	"$S6/wait-network-online"
	assert_file_contains "$CONSOLE" 'AP mode'
}

@test "no internet: starts anyway after the timeout" {
	stub ping 'exit 1'
	"$S6/wait-network-online"
	assert_equal "$(grep -c '^ping' "$CALLS")" 3
	assert_file_contains "$CONSOLE" 'starting anyway'
}
