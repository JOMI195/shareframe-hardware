# Release migrations on /data: run once per new version, in order; a failure retries next boot.
load ../../support/common

setup() {
	sf_setup
	export MIG_DIR="$T/mig" STATE="$T/state" RELEASE="$T/release" RUN_DIR="$T/run"
	mkdir -p "$MIG_DIR"
	echo VERSION=2.0.0 > "$RELEASE"
	printf 'echo first >> "%s/ran"\n' "$T" > "$MIG_DIR/010-first.sh"
	printf 'echo second >> "%s/ran"\n' "$T" > "$MIG_DIR/020-second.sh"
}

@test "a new version runs every migration in order and records the version" {
	"$S6/system-migrations" >/dev/null
	assert_equal "$(cat "$T/ran")" "first
second"
	assert_equal "$(cat "$STATE")" 2.0.0
	assert_file_not_exists "$RUN_DIR/migrations-failed"
}

@test "the same version again runs nothing" {
	"$S6/system-migrations" >/dev/null
	"$S6/system-migrations" >/dev/null
	assert_equal "$(wc -l < "$T/ran" | tr -d ' ')" 2
}

@test "a failing migration lets the rest run, flags it and retries next boot" {
	echo 'exit 1' > "$MIG_DIR/015-broken.sh"
	"$S6/system-migrations" >/dev/null
	assert_equal "$(cat "$T/ran")" "first
second"
	assert_file_exists "$RUN_DIR/migrations-failed"
	assert_file_not_exists "$STATE"
}
