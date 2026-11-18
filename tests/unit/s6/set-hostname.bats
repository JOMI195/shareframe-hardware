# The board's hostname from its serial, so several frames can share a LAN.
load ../../support/common

setup() {
	sf_setup
	stub hostname
}

@test "the hostname is the board's name" {
	CPUINFO="$SRC/tests/support/fixtures/cpuinfo-pi0w" "$S6/set-hostname"
	assert_called 'hostname shareframe-board-C3D4'
}

@test "without a serial the build-time hostname stays" {
	printf 'Hardware\t: BCM2835\n' > "$T/cpuinfo"
	CPUINFO="$T/cpuinfo" "$S6/set-hostname"
	refute_called hostname
}
