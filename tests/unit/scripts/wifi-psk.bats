# WPA2 PSK derivation for factory Wi-Fi blocks (PBKDF2, the SSID is the salt).
load ../../support/common

setup() { host_setup; }

@test "the IEEE 802.11i test vector derives the expected PSK" {
	run "$SRC/scripts/wifi-psk.sh" --selftest
	assert_success
	assert_output --partial 'selftest OK'
}
