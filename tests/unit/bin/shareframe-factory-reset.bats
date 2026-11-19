# A factory reset only marks the wipe; the next boot's mount-data does it.
load ../../support/common

setup() {
	sf_setup
	export RESET_MARK="$T/.factory-reset" CONSOLE=/dev/null
	stub reboot
	quiet_stub id 'echo 0'
}

@test "with --yes it marks the wipe and reboots" {
	shareframe-factory-reset --yes
	assert_file_exists "$RESET_MARK"
	assert_called reboot
}

@test "without --yes nothing happens" {
	run shareframe-factory-reset
	assert_failure 1
	assert_file_not_exists "$RESET_MARK"
	refute_called reboot
}

@test "only root may schedule it" {
	quiet_stub id 'echo 1000'
	run shareframe-factory-reset --yes
	assert_failure 1
	assert_file_not_exists "$RESET_MARK"
}
