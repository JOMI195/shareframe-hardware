# Frames in the field keep today's screens after the update; a fresh card shows its setup screens.
load ../../support/common

setup() {
	sf_setup
	export DATA_DIR="$T/data"
	mkdir -p "$DATA_DIR"
	MIGRATION="$OVERLAY/usr/share/shareframe/system-migrations/001-mark-set-up-frames.sh"
}

@test "a frame updated over the air is marked as joined and owned" {
	mkdir -p "$DATA_DIR/update-verify" && echo "from_version=1.2.0" > "$DATA_DIR/update-verify/state"
	run "$MIGRATION"
	assert_success
	[ -e "$DATA_DIR/wifi-joined" ]
	[ -e "$DATA_DIR/registered-once" ]
}

@test "a freshly flashed card stays unmarked" {
	run "$MIGRATION"
	assert_success
	[ ! -e "$DATA_DIR/wifi-joined" ]
	[ ! -e "$DATA_DIR/registered-once" ]
}

@test "a mark already there is left as it is" {
	mkdir -p "$DATA_DIR/update-verify" && echo x > "$DATA_DIR/update-verify/state"
	echo 1700000000 > "$DATA_DIR/wifi-joined"
	run "$MIGRATION"
	assert_equal "$(cat "$DATA_DIR/wifi-joined")" 1700000000
}
