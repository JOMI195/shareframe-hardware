# ntpd's hook: the synced flag, and the clock saved right after the first step.
load ../../support/common

setup() {
	sf_setup
	export STATE="$T/ntp.synced" CLOCK_FILE="$T/fake-hwclock" CONSOLE=/dev/null
	quiet_stub date 'echo 1767323045'
}

@test "a step marks the clock synced and saves it for the next boot" {
	"$S6/ntpd-handler" step
	assert_file_exists "$STATE"
	assert_equal "$(cat "$CLOCK_FILE")" 1767323045
}

@test "periodic keeps the flag, unsync drops it" {
	"$S6/ntpd-handler" periodic
	assert_file_exists "$STATE"
	"$S6/ntpd-handler" unsync
	assert_file_not_exists "$STATE"
}
