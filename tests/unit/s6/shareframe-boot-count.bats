# The power-cycle count, once per boot.
load ../../support/common

setup() { sf_setup; export DATA_DIR="$T"; }

@test "each boot counts one, a missing or garbled counter starts at one" {
	sh "$S6/shareframe-boot-count"
	sh "$S6/shareframe-boot-count"
	assert_equal "$(cat "$T/boot_count")" 2
	echo garbage > "$T/boot_count"
	sh "$S6/shareframe-boot-count"
	assert_equal "$(cat "$T/boot_count")" 1
}
