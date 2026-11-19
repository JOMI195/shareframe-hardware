# At boot, right after the migrations and before the seeds and the apps: a trial boot gets back
# what its release lost. It never fails the boot; the commit gate decides.
load ../../support/common

setup() {
	sf_setup
	stub shareframe-update-verify "exit \"\$(cat '$T/verify-rc' 2>/dev/null || echo 0)\""
	stub shareframe-slot "exit \"\$(cat '$T/trial-rc')\""
	export CONSOLE="$T/console"
}

@test "a trial boot restores" {
	echo 0 > "$T/trial-rc"
	run "$S6/update-verify-restore"
	assert_success
	assert_called 'shareframe-update-verify restore'
}

@test "a trial whose identity cannot come back still boots" {
	echo 0 > "$T/trial-rc"
	echo 1 > "$T/verify-rc"
	run "$S6/update-verify-restore"
	assert_success
	assert_called 'shareframe-update-verify restore'
	assert_file_contains "$CONSOLE" 'could not be restored'
}

@test "an ordinary boot touches nothing" {
	echo 1 > "$T/trial-rc"
	run "$S6/update-verify-restore"
	assert_success
	refute_called shareframe-update-verify
}
