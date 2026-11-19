# hostapd: renders its conf from ap.conf once the mode manager raises the ap-enabled flag.
load ../../support/common

setup() {
	sf_setup
	export AP_CONF="$T/ap.conf" RUN_DIR="$T/run"
	mkdir -p "$RUN_DIR"
	: > "$RUN_DIR/ap-enabled"
	stub hostapd
}

@test "the hotspot gets the stored SSID and WPA2 passphrase, special characters as they are" {
	printf '%s\n' "AP_SSID='shareframe-board-C3D4'" "AP_PASS='it'\\''s \"\$x\";#'" > "$AP_CONF"
	"$S6/hostapd"
	run cat "$RUN_DIR/hostapd.conf"
	assert_line 'ssid=shareframe-board-C3D4'
	assert_line "wpa_passphrase=it's \"\$x\";#"
	assert_line 'wpa=2'
	assert_called "hostapd $RUN_DIR/hostapd.conf"
}

@test "without a password the hotspot is open" {
	printf "AP_SSID='frame'\n" > "$AP_CONF"
	"$S6/hostapd"
	run cat "$RUN_DIR/hostapd.conf"
	refute_line --partial 'wpa='
}

@test "a password set through shareframe-ap can never add a config line" {
	CONSOLE=/dev/null SVC="$T/service" run shareframe-ap setpass "$(printf 'goodpass\nwpa=0')"
	assert_failure 1
	assert_output --partial printable
}
