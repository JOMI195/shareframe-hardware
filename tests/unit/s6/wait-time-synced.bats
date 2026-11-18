# Gate for TLS services: a clock that looks real, or the timeout.
load ../../support/common

setup() {
	sf_setup
	export CONSOLE="$T/console" TIMEOUT=3
	quiet_stub sleep 'exit 0'
}

@test "a real clock passes at once" {
	quiet_stub date 'echo 1767323045'
	"$S6/wait-time-synced"
	assert_file_not_exists "$CONSOLE"
}

@test "a clock near the epoch gives up after the timeout" {
	quiet_stub date 'echo 86400'
	"$S6/wait-time-synced"
	assert_file_contains "$CONSOLE" 'continuing'
}
