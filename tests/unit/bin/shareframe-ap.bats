# The hotspot: its credentials file, and the services behind the ap-enabled flag.
load ../../support/common

setup() {
	sf_setup
	export AP_CONF="$T/wifi/ap.conf" RUN_DIR="$T/run" SVC="$T/service" CONSOLE=/dev/null
	mkdir -p "$RUN_DIR"
	for cmd in s6-svc ip iw; do stub "$cmd"; done
	quiet_stub sleep 'exit 0'
}

creds() { (. "$AP_CONF"; printf '%s|%s' "$AP_SSID" "$AP_PASS"); }

@test "setpass keeps the SSID and stores a password that sources back exactly" {
	mkdir -p "$T/wifi"
	printf "AP_SSID='frame-ap'\nAP_PASS='old-pass-1'\n" > "$AP_CONF"
	shareframe-ap setpass "it's \"q\" \$HOME;\\x"
	assert_equal "$(creds)" "frame-ap|it's \"q\" \$HOME;\\x"
	assert_equal "$(stat -c %a "$AP_CONF")" 600
}

@test "setpass refuses passwords hostapd would refuse and keeps the old one" {
	mkdir -p "$T/wifi"
	printf "AP_SSID='frame-ap'\nAP_PASS='old-pass-1'\n" > "$AP_CONF"
	run shareframe-ap setpass short
	assert_failure 1
	run shareframe-ap setpass "$(printf '%064d' 0)"
	assert_failure 1
	assert_equal "$(creds)" 'frame-ap|old-pass-1'
}

@test "setpass restarts hostapd only while the hotspot is up" {
	shareframe-ap setpass new-pass-1
	refute_called s6-svc
	: > "$RUN_DIR/ap-enabled"
	shareframe-ap setpass new-pass-2
	eventually 3 called "s6-svc -r $SVC/hostapd"
}

@test "up raises the flag and kicks hostapd and dnsmasq; down undoes it" {
	shareframe-ap up
	assert_file_exists "$RUN_DIR/ap-enabled"
	assert_called "s6-svc -r $SVC/hostapd"
	assert_called "s6-svc -r $SVC/dnsmasq-ap"
	assert_called 'ip addr add 192.168.4.1/24 dev wlan0'
	shareframe-ap down
	assert_file_not_exists "$RUN_DIR/ap-enabled"
}

@test "down without the hotspot never touches wlan0" {
	shareframe-ap down
	assert_file_not_exists "$CALLS"
}

@test "status counts the stations on the hotspot" {
	run shareframe-ap status
	assert_output 'down stations=0'
	: > "$RUN_DIR/ap-enabled"
	stub iw 'printf "Station 02:00:00:00:03:00 (on wlan0)\n\tinactive time: 10 ms\nStation 02:00:00:00:04:00 (on wlan0)\n"'
	run shareframe-ap status
	assert_output 'up stations=2'
}
