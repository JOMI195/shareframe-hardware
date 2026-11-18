# First-boot hotspot credentials: factory store, else derived from the serial, else the template.
load ../../support/common

setup() {
	sf_setup
	export AP_CONF="$T/data/wifi/ap.conf" FACTORY_DIR="$T/factory" SHARE_DIR="$T/share" CONSOLE="$T/console"
	export CPUINFO="$SRC/tests/support/fixtures/cpuinfo-pi0w"
	mkdir -p "$FACTORY_DIR" "$SHARE_DIR"
	printf "AP_SSID='from-template'\nAP_PASS='template-pass'\n" > "$SHARE_DIR/ap.conf.template"
}

creds() { (. "$AP_CONF"; echo "$AP_SSID $AP_PASS"); }

@test "the factory store wins and the file is private" {
	printf "AP_SSID='factory'\nAP_PASS='factory-pass'\n" > "$FACTORY_DIR/ap.conf"
	"$S6/seed-ap-config"
	assert_equal "$(creds)" 'factory factory-pass'
	assert_equal "$(stat -c %a "$AP_CONF")" 600
}

@test "without a factory file the SSID is the board's name and the password a salted serial hash" {
	"$S6/seed-ap-config"
	pass="$(printf 'shareframe-ap:a1b2c3d4' | sha256sum | cut -c1-10)"
	assert_equal "$(creds)" "shareframe-board-C3D4 $pass"
	assert_equal "$(stat -c %a "$AP_CONF")" 600
}

@test "the hotspot SSID and the hostname are the same name" {
	stub hostname
	"$S6/seed-ap-config"
	"$S6/set-hostname"
	assert_called "hostname $(creds | cut -d' ' -f1)"
}

@test "without a serial the template is used" {
	printf 'Hardware\t: BCM2835\n' > "$T/cpuinfo"
	CPUINFO="$T/cpuinfo" "$S6/seed-ap-config"
	assert_equal "$(creds)" 'from-template template-pass'
}

@test "existing credentials are never overwritten" {
	mkdir -p "$(dirname "$AP_CONF")"
	printf "AP_SSID='mine'\nAP_PASS='my-pass-123'\n" > "$AP_CONF"
	printf "AP_SSID='factory'\nAP_PASS='factory-pass'\n" > "$FACTORY_DIR/ap.conf"
	"$S6/seed-ap-config"
	assert_equal "$(creds)" 'mine my-pass-123'
}
