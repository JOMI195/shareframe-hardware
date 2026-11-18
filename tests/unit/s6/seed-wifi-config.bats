# First-boot Wi-Fi config: the factory store, else the template; never over an existing one.
load ../../support/common

setup() {
	sf_setup
	export WPA_CONF="$T/data/wifi/wpa_supplicant.conf" FACTORY_DIR="$T/factory" SHARE_DIR="$T/share" CONSOLE="$T/console"
	mkdir -p "$FACTORY_DIR" "$SHARE_DIR"
	echo 'network={ssid="template"}' > "$SHARE_DIR/wpa_supplicant.conf.template"
}

@test "the factory config wins and is private" {
	echo 'network={ssid="home"}' > "$FACTORY_DIR/wpa_supplicant.conf"
	"$S6/seed-wifi-config"
	assert_equal "$(cat "$WPA_CONF")" 'network={ssid="home"}'
	assert_equal "$(stat -c %a "$WPA_CONF")" 600
}

@test "without one the template is used, and an existing config is never replaced" {
	"$S6/seed-wifi-config"
	assert_equal "$(cat "$WPA_CONF")" 'network={ssid="template"}'
	echo 'network={ssid="mine"}' > "$WPA_CONF"
	echo 'network={ssid="home"}' > "$FACTORY_DIR/wpa_supplicant.conf"
	"$S6/seed-wifi-config"
	assert_equal "$(cat "$WPA_CONF")" 'network={ssid="mine"}'
}

@test "no source at all says so on the console and leaves no file" {
	rm "$SHARE_DIR/wpa_supplicant.conf.template"
	"$S6/seed-wifi-config"
	assert_file_not_exists "$WPA_CONF"
	assert_file_contains "$CONSOLE" 'no seed source found'
}
