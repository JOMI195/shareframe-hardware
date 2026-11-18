# Which A/B slot runs, which waits for its trial boot, and whether this boot is that trial.
load ../../support/common

setup() {
	sf_setup
	export CMDLINE="$T/cmdline" PENDING_FILE="$T/pending"
	echo 'console=ttyS1,115200 rauc.slot=B panic=10' > "$CMDLINE"
}

@test "booted is the slot on the kernel cmdline" {
	run shareframe-slot booted
	assert_output B
}

@test "nothing pending: no trial" {
	run shareframe-slot pending
	assert_output ''
	run shareframe-slot trial
	assert_failure
}

@test "the pending slot booted: this is its trial" {
	echo B > "$PENDING_FILE"
	run shareframe-slot trial
	assert_success
}

@test "another slot pending: not a trial, the staged one never came up" {
	echo A > "$PENDING_FILE"
	run shareframe-slot trial
	assert_failure
}

@test "an unknown subcommand is a usage error" {
	run shareframe-slot sideways
	assert_failure 2
}
