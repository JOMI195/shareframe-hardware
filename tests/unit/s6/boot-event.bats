# The boot record: clean or unclean, the count of unclean resets, the last reset's pstore.
load ../../support/common

setup() {
	sf_setup
	export DATA_DIR="$T/data" RUN_DIR="$T/run" PSTORE="$T/pstore" PROC="$T/proc" RELEASE="$T/release"
	export CMDLINE="$T/cmdline" PENDING_FILE="$T/pending"
	mkdir -p "$DATA_DIR" "$PSTORE" "$PROC"
	echo "pstore $PSTORE pstore rw 0 0" > "$PROC/mounts"
	echo VERSION=1.4.0 > "$RELEASE"
	echo 'rauc.slot=A' > "$CMDLINE"
	echo 5 > "$DATA_DIR/boot_count"
	stub shareframe-event
	stub mount
}

boot() { "$S6/boot-event"; }

@test "a clean shutdown before: a clean boot, the marker consumed" {
	: > "$DATA_DIR/clean-shutdown"
	boot
	assert_called 'shareframe-event boot version=1.4.0 slot=A boot_count=5 unclean=0'
	assert_file_not_exists "$DATA_DIR/clean-shutdown"
	assert_file_not_exists "$RUN_DIR/unclean-boot"
}

@test "no marker: unclean, counted, and the pstore of the reset kept" {
	echo 'Kernel panic - not syncing' > "$PSTORE/dmesg-ramoops-0"
	echo 'paint start' > "$PSTORE/pmsg-ramoops-0"
	boot
	assert_file_exists "$RUN_DIR/unclean-boot"
	assert_equal "$(cat "$DATA_DIR/unclean_resets")" 1
	assert_equal "$(cat "$DATA_DIR/last-reset/dmesg-ramoops-0")" 'Kernel panic - not syncing'
	assert_called 'shareframe-event boot version=1.4.0 slot=A boot_count=5 unclean=1 pstore=2'
	assert_file_not_exists "$PSTORE/dmesg-ramoops-0"
}

@test "the very first boot has no marker yet and is not unclean" {
	echo 1 > "$DATA_DIR/boot_count"
	boot
	assert_file_not_exists "$RUN_DIR/unclean-boot"
}

@test "a garbled counter starts over" {
	echo garbage > "$DATA_DIR/unclean_resets"
	boot
	assert_equal "$(cat "$DATA_DIR/unclean_resets")" 1
}

@test "an unclean boot is on the card before the next power cut can take it" {
	echo 2 > "$DATA_DIR/unclean_resets"
	sync_records "$DATA_DIR/unclean_resets"
	"$S6/boot-event" >/dev/null 2>&1
	synced 3
}
