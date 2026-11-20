# What shareframe-board writes for this repo's scripts: its goldens (tests/contract/golden there)
# fed to the scripts that read them. The board repo is mounted at $BOARD.
load ../support/common

setup() {
	sf_setup
	GOLDEN="$BOARD/tests/contract/golden"
}

# bats test_tags=contract
@test "the staged meta the update service writes gives the history its versions" {
	fixed_clock
	stub shareframe-event
	cp "$GOLDEN/pending-meta.json" "$T/meta.json"
	DATA_DIR="$T/data" META="$T/meta.json" RELEASE=/dev/null shareframe-update-history committed
	run jq -c '[.from_version, .to_version]' "$T/data/update-history.jsonl"
	assert_output "$(jq -c '[.from_version, .to_version]' "$GOLDEN/pending-meta.json")"
}

# bats test_tags=contract
@test "the image build accepts exactly the profiles the apps load" {
	accepted="$(grep -oE '^ *[a-z.|]*prod\.local[a-z.|]*\)' "$SRC/automation.sh" | tr -d ' )' | tr '|' '\n' | sort)"
	assert_equal "$accepted" "$(sort "$GOLDEN/profiles.txt")"
}

default_of() { # <script> <variable>: the variable's value with nothing overridden
	env -i PATH="$PATH" sh -c "$(grep -E "^(IFACE|STATE_DIR|MODE_FILE|JSON_FILE|RETRY_FLAG|BACKEND_OK|JOINED_FLAG|DATA_DIR|RUN_DIR)=" "$1"); echo \"\$$2\""
}

# bats test_tags=contract
@test "the scripts watch the flags where the apps leave them" {
	flag() { sed -n "s/^$1=//p" "$GOLDEN/run-flags.txt"; }
	assert_equal "$(default_of "$S6/wifi-mode-manager" JSON_FILE)" "$(flag wifi_mode)"
	assert_equal "$(default_of "$S6/wifi-mode-manager" RETRY_FLAG)" "$(flag wifi_retry_requested)"
	assert_equal "$(default_of "$S6/rauc-mark-good" BACKEND_OK)" "$(flag backend_ok)"
	assert_equal "$(default_of "$BIN/shareframe-safe-mode" RUN_DIR)/safe-mode" "$(flag safe_mode)"
}

# bats test_tags=contract
@test "the display finds the setup and owner marks where the scripts leave them" {
	flag() { sed -n "s/^$1=//p" "$GOLDEN/run-flags.txt"; }
	migration="$OVERLAY/usr/share/shareframe/system-migrations/001-mark-set-up-frames.sh"
	assert_equal "$(default_of "$S6/wifi-mode-manager" JOINED_FLAG)" "$(flag wifi_joined)"
	assert_equal "$(default_of "$migration" DATA_DIR)/wifi-joined" "$(flag wifi_joined)"
	assert_equal "$(default_of "$migration" DATA_DIR)/registered-once" "$(flag registered_once)"
}
