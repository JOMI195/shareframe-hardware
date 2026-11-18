# The factory store (p5): what a factory reset restores; set changes the store, not /data.
load ../../support/common

setup() {
	sf_setup
	export FACTORY_DEV=/dev/fake FACTORY_DIR="$T/staged" FACTORY_MNT="$T/mnt"
	mkdir -p "$FACTORY_DIR"
	quiet_stub id 'echo 0'
	stub mount "mkdir -p '$FACTORY_MNT'"
	stub umount
	echo "AP_PASS='old'" > "$FACTORY_DIR/ap.conf"
}

@test "get prints a staged default" {
	run shareframe-factory get ap.conf
	assert_output "AP_PASS='old'"
}

@test "set writes the store through a mount and refreshes the staged copy" {
	echo "AP_PASS='new'" > "$T/new.conf"
	shareframe-factory set ap.conf "$T/new.conf" >/dev/null
	assert_called "mount -t vfat /dev/fake $FACTORY_MNT"
	assert_called "umount $FACTORY_MNT"
	assert_equal "$(cat "$FACTORY_MNT/ap.conf")" "AP_PASS='new'"
	assert_equal "$(cat "$FACTORY_DIR/ap.conf")" "AP_PASS='new'"
}

@test "only root, and only with a file to set" {
	run shareframe-factory set ap.conf "$T/missing"
	assert_failure 2
	quiet_stub id 'echo 1000'
	run shareframe-factory list
	assert_failure 1
}
