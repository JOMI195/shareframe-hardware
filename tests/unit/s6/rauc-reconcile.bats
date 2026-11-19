# At boot: a staged slot that is not running never came up, so it is marked bad, once.
load ../../support/common

setup() {
	sf_setup
	export CMDLINE="$T/cmdline" PENDING_FILE="$T/pending" BACKEND="$STUBS/tryboot-backend"
	echo 'console=ttyS1,115200 rauc.slot=A' > "$CMDLINE"
	stub rauc
	stub tryboot-backend
	stub shareframe-update-history
}

@test "a staged slot that did not boot is marked bad and recorded as a rollback" {
	echo B > "$PENDING_FILE"
	"$S6/rauc-reconcile" >/dev/null
	assert_called 'rauc status mark-bad other'
	assert_called 'shareframe-update-history rolled-back staged slot B failed to boot'
	refute_called tryboot-backend
}

@test "rauc unavailable: the backend clears the staged slot itself" {
	echo B > "$PENDING_FILE"
	stub rauc 'exit 1'
	"$S6/rauc-reconcile" >/dev/null
	assert_called 'tryboot-backend set-state B bad'
	assert_called 'shareframe-update-history rolled-back'
}

@test "the trial boot of the staged slot is left to the commit gate" {
	echo A > "$PENDING_FILE"
	"$S6/rauc-reconcile"
	assert_file_not_exists "$CALLS"
}

@test "nothing staged: nothing happens" {
	"$S6/rauc-reconcile"
	assert_file_not_exists "$CALLS"
}
