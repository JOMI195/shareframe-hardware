# Helpers every image script shares (/usr/lib/shareframe/lib.sh).
load ../../support/common

setup() {
	sf_setup
	# shellcheck source=br2-external/overlay/usr/lib/shareframe/lib.sh
	. "$SF_LIB"
}

roundtrip() { printf '{"v":"%s"}' "$(json_escape "$1")" | jq -j .v; }

@test "json_escape: quotes, backslashes, tabs and newlines survive a JSON parser" {
	for v in plain 'a"b' 'back\slash' "tab	in" "two
lines" 'ünï "q" \\' ''; do
		assert_equal "$(roundtrip "$v")" "$v"
	done
}

@test "json_escape: other control characters are dropped, not emitted raw" {
	assert_equal "$(roundtrip "$(printf 'a\001b\033c')")" abc
}

@test "board_serial drops the leading zeros; no Serial line gives nothing" {
	CPUINFO="$SRC/tests/support/fixtures/cpuinfo-pi0w"
	assert_equal "$(board_serial)" a1b2c3d4
	printf 'Hardware\t: BCM2835\n' > "$T/cpuinfo"
	CPUINFO="$T/cpuinfo"
	assert_equal "$(board_serial)" ''
}

@test "board_name is shareframe-board and the serial's last four, upper case" {
	CPUINFO="$SRC/tests/support/fixtures/cpuinfo-pi0w"
	assert_equal "$(board_name)" shareframe-board-C3D4
}

@test "write_durable: the value replaces the file whole and is synced, no temp file left" {
	sync_records "$T/counter"
	echo 1 > "$T/counter"
	write_durable "$T/counter" 2
	assert_equal "$(cat "$T/counter")" 2
	synced 2
	assert_file_not_exists "$T/counter.tmp"
}
