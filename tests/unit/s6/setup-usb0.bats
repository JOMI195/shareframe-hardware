# usb0: the fixed board address plus a serial-derived link-local alias.
load ../../support/common

setup() {
	sf_setup
	export SYSFS="$T/sys"
	mkdir -p "$SYSFS/class/net/usb0"
	stub ip
}

@test "10.55.0.1 and a link-local address from the serial's last four digits" {
	CPUINFO="$SRC/tests/support/fixtures/cpuinfo-pi0w" "$S6/setup-usb0"
	assert_called 'ip addr replace 10.55.0.1/24 dev usb0'
	assert_called 'ip addr replace 169.254.195.212/16 dev usb0'
	assert_called 'ip link set usb0 up'
}

@test "a third octet outside the usable link-local range becomes 1" {
	printf 'Serial\t\t: 00000000000000d4\n' > "$T/cpuinfo"
	CPUINFO="$T/cpuinfo" "$S6/setup-usb0"
	assert_called 'ip addr replace 169.254.1.212/16 dev usb0'
}
