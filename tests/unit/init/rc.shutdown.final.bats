# The very last step of a reboot: a staged update turns it into a one-time tryboot.
load ../../support/common

setup() {
	sf_setup
	export TRYBOOT_FLAG="$T/tryboot" TRYBOOT_REBOOT="$STUBS/tryboot-reboot"
	stub tryboot-reboot
}

@test "with the tryboot flag the firmware is told to boot the staged slot once" {
	: > "$TRYBOOT_FLAG"
	sh "$PKG/shareframe-init/skel/rc.shutdown.final"
	assert_called tryboot-reboot
}

@test "a plain reboot stays plain" {
	sh "$PKG/shareframe-init/skel/rc.shutdown.final"
	refute_called tryboot-reboot
}

@test "a failing tryboot reboot still lets the normal reboot happen" {
	: > "$TRYBOOT_FLAG"
	stub tryboot-reboot 'exit 1'
	run sh "$PKG/shareframe-init/skel/rc.shutdown.final"
	assert_success
}
