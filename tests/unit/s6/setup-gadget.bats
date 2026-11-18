# The USB gadget: a serial-derived, stable MAC pair for usb0, the board's local/unicast address.
load ../../support/common

setup() {
	sf_setup
	export SYSFS="$T/sys" CPUINFO="$SRC/tests/support/fixtures/cpuinfo-pi0w"
	mkdir -p "$SYSFS/class/udc/20980000.usb"
	G="$SYSFS/kernel/config/usb_gadget/shareframe"
}

@test "the MACs come from the serial: locally administered unicast, board and host differ" {
	"$S6/setup-gadget"
	assert_equal "$(cat "$G/functions/ncm.usb0/dev_addr")" 02:5f:a1:b2:c3:d4
	assert_equal "$(cat "$G/functions/ncm.usb0/host_addr")" 06:5f:a1:b2:c3:d4
	assert_equal "$(cat "$G/strings/0x409/serialnumber")" a1b2c3d4
	assert_equal "$(cat "$G/UDC")" 20980000.usb
}

@test "a gadget already set up is left alone" {
	mkdir -p "$G"
	"$S6/setup-gadget"
	assert_file_not_exists "$G/idVendor"
}
