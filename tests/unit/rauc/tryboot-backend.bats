# RAUC's custom bootloader backend: stages a slot for tryboot, commits or rolls it back.
load ../../support/common

setup() {
	sf_setup
	BACKEND="$PKG/shareframe-rauc/files/tryboot-backend"
	export NO_MOUNT=1 FW_MNT="$T/fw" STATE_DIR="$T/rauc" CMDLINE="$T/cmdline" TRYBOOT_FLAG="$T/tryboot" FW_LOCK="$T/fw.lock"
	mkdir -p "$FW_MNT" "$STATE_DIR"
}

card() { # <committed slot> <booted slot>
	local other=B
	[ "$1" = A ] || other=A
	printf 'enable_uart=1\nos_prefix=%s/\nkernel=zImage\n' "$1" > "$FW_MNT/config.txt"
	printf 'enable_uart=1\nos_prefix=%s/\nkernel=zImage\n' "$other" > "$FW_MNT/tryboot.txt"
	booted "$2"
}

booted() { printf 'console=ttyS1,115200 rauc.slot=%s panic=10\n' "$1" > "$CMDLINE"; }

@test "get-primary is the slot config.txt boots" {
	card A A
	run "$BACKEND" get-primary
	assert_success
	assert_output A
}

@test "a slot without a recorded state is good" {
	card A A
	run "$BACKEND" get-state B
	assert_output good
}

@test "set-primary stages the slot for one tryboot without touching config.txt" {
	card A A
	"$BACKEND" set-primary B
	assert_equal "$(cat "$STATE_DIR/pending")" B
	assert_file_exists "$TRYBOOT_FLAG"
	run "$BACKEND" get-primary
	assert_output A
}

@test "good from the trial boot commits: os_prefix swaps, pending and tryboot flag go" {
	card A A
	"$BACKEND" set-primary B
	booted B
	"$BACKEND" set-state B good
	run "$BACKEND" get-primary
	assert_output B
	assert_file_not_exists "$STATE_DIR/pending"
	assert_file_not_exists "$TRYBOOT_FLAG"
	assert_equal "$(sed -n 's/^os_prefix=//p' "$FW_MNT/tryboot.txt")" A/
	assert_equal "$(head -1 "$FW_MNT/config.txt")" enable_uart=1
}

@test "bad for the staged slot keeps the committed one and records the state" {
	card A A
	"$BACKEND" set-primary B
	"$BACKEND" set-state B bad
	run "$BACKEND" get-primary
	assert_output A
	assert_file_not_exists "$STATE_DIR/pending"
	run "$BACKEND" get-state B
	assert_output bad
}

@test "good for the committed slot leaves config.txt alone" {
	card A A
	before="$(cat "$FW_MNT/config.txt")"
	"$BACKEND" set-state A good
	assert_equal "$(cat "$FW_MNT/config.txt")" "$before"
}

@test "set-primary to the committed slot clears a stale pending slot" {
	card A A
	echo B > "$STATE_DIR/pending"
	: > "$TRYBOOT_FLAG"
	"$BACKEND" set-primary A
	assert_file_not_exists "$STATE_DIR/pending"
}

# With real mount handling: mount, umount and mountpoint are stubs over a mounted flag.
mounts() {
	unset NO_MOUNT
	quiet_stub mountpoint "[ -f '$T/mounted' ]"
	stub mount ": > '$T/mounted'"
	stub umount "rm -f '$T/mounted'"
}

@test "a p1 mount it found in place is left mounted for its owner" {
	card A A
	mounts
	: > "$T/mounted"
	run "$BACKEND" get-primary
	assert_output A
	refute_called umount
	assert_file_exists "$T/mounted"
}

@test "a p1 mount it made itself is undone" {
	card A A
	mounts
	"$BACKEND" get-primary
	assert_called 'mount -t vfat -o ro,noatime'
	assert_called umount
	assert_file_not_exists "$T/mounted"
}

@test "calls wait for each other, so a read never unmounts p1 under a commit" {
	card A A
	mounts
	touch "$T/hold"
	flock "$FW_LOCK" sh -c "touch '$T/held'; while [ -f '$T/hold' ]; do sleep 0.05; done" 3>&- &
	eventually 3 test -f "$T/held"
	{ "$BACKEND" get-primary > "$T/out"; touch "$T/done"; } 3>&- &
	sleep 0.5
	assert_file_not_exists "$T/done"
	rm "$T/hold"
	eventually 3 test -f "$T/done"
	assert_equal "$(cat "$T/out")" A
}

# bats test_tags=contract
@test "golden tryboot-get-primary.txt: the committed slot the update service reads" {
	card B A
	"$BACKEND" get-primary > "$T/primary"
	assert_golden tryboot-get-primary.txt "$T/primary"
}
