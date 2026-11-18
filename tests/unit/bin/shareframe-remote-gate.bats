# The board's say before a remote reboot-class command: never during a trial boot, at most one
# remote reboot per MIN_GAP.
load ../../support/common

setup() {
	sf_setup
	export DATA_DIR="$T/data" CMDLINE="$T/cmdline" PENDING_FILE="$T/pending" MIN_GAP=1800
	echo 'rauc.slot=A' > "$CMDLINE"
	quiet_stub date 'echo 10000'
}

@test "a settled board may reboot" {
	run shareframe-remote-gate check
	assert_success
}

@test "a trial boot refuses with the reason, also without the rate limit" {
	echo A > "$PENDING_FILE"
	run shareframe-remote-gate check --no-rate-limit
	assert_failure 1
	assert_output --partial 'booted slot A is not confirmed yet'
}

@test "a second remote reboot inside MIN_GAP is refused, after it is allowed again" {
	shareframe-remote-gate mark
	quiet_stub date 'echo 11000'
	run shareframe-remote-gate check
	assert_failure 1
	assert_output 'last remote reboot was less than 30 minutes ago'
	run shareframe-remote-gate check --no-rate-limit
	assert_success
	quiet_stub date 'echo 11800'
	run shareframe-remote-gate check
	assert_success
}

@test "a clock that went backwards does not block forever" {
	mkdir -p "$DATA_DIR"
	echo 99999 > "$DATA_DIR/remote-reboot-at"
	run shareframe-remote-gate check
	assert_success
}
