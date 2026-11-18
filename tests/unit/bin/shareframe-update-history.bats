# The update history on /data: one JSON line per install outcome, capped, read by the dashboard.
load ../../support/common

setup() {
	sf_setup
	fixed_clock
	stub shareframe-event
	export DATA_DIR="$T/data" META="$T/pending-meta.json" RELEASE="$T/shareframe-release"
	HIST="$DATA_DIR/update-history.jsonl"
	echo 'VERSION=1.0.0' > "$RELEASE"
}

meta() { printf '{"from_version":"%s","to_version":"%s"}\n' "$1" "$2" > "$META"; }

@test "an outcome takes its versions from the staged meta and consumes it" {
	meta 1.0.0 1.1.0
	shareframe-update-history committed
	run jq -c '[.from_version, .to_version, .result, .error]' "$HIST"
	assert_output '["1.0.0","1.1.0","committed",""]'
	assert_file_not_exists "$META"
	assert_called 'shareframe-event update committed 1.0.0 -> 1.1.0'
}

@test "without a staged meta the installed version is the from version" {
	shareframe-update-history install-failed 'checksum mismatch'
	run jq -c '[.from_version, .to_version, .error]' "$HIST"
	assert_output '["1.0.0","","checksum mismatch"]'
}

@test "an error with quotes, backslashes and newlines keeps every line valid JSON" {
	shareframe-update-history install-failed "$(printf 'rauc: "bad"\\sig\nline two')"
	run jq -r .error "$HIST"
	assert_success
	assert_output 'rauc: "bad"\sigline two'
}

@test "the history keeps the newest 50 entries" {
	for i in $(seq 1 55); do shareframe-update-history rolled-back "run $i"; done
	assert_equal "$(wc -l < "$HIST" | tr -d ' ')" 50
	assert_equal "$(head -1 "$HIST" | jq -r .error)" 'run 6'
	assert_equal "$(tail -1 "$HIST" | jq -r .error)" 'run 55'
}

# bats test_tags=contract
@test "golden update-history.jsonl: what the dashboard's update history parses" {
	meta 1.0.0 1.1.0
	shareframe-update-history committed
	meta 1.1.0 1.2.0
	shareframe-update-history rolled-back
	shareframe-update-history install-failed 'rauc: "bad signature"'
	assert_golden update-history.jsonl "$HIST"
}
