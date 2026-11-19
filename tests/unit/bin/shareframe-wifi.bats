# Saved Wi-Fi networks: through wpa_cli while wpa_supplicant runs, straight in the
# config file while the hotspot has the radio.
load ../../support/common

setup() {
	sf_setup
	export WPA_CONF="$T/wpa_supplicant.conf"
	offline
	# The real tool's block layout, with a stand-in hash.
	quiet_stub wpa_passphrase 'printf "network={\n\tssid=\"%s\"\n\t#psk=\"%s\"\n\tpsk=%s\n}\n" "$1" "$2" "$(printf %s "$1$2" | sha256sum | cut -c1-64)"'
	printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\n\nnetwork={\n\tssid="home"\n\tpsk=aaaa\n}\n' > "$WPA_CONF"
}

offline() { stub wpa_cli 'exit 1'; }
online() { # wpa_cli of a running supplicant with the given "id<TAB>ssid" networks
	printf '%s\n' "$@" > "$T/networks"
	stub wpa_cli "case \"\$3\" in
		ping) echo PONG ;;
		list_networks) echo 'network id / ssid / bssid / flags'; sed 's/\$/\tany\t/' '$T/networks' ;;
		*) echo OK ;;
	esac"
}
saved() { shareframe-wifi list | tail -n +2 | cut -f2; }
blocks() { grep -c 'network={' "$WPA_CONF"; }

# list prints SSIDs the way wpa_cli does (printf_encode), online and offline alike.
@test "offline list shows quoted SSIDs and the hex ones wpa_supplicant writes, as wpa_cli prints them" {
	printf 'network={\n\tssid=c3bc6e69636f6465\n\tpsk=bbbb\n}\n' >> "$WPA_CONF"
	assert_equal "$(saved)" 'home
\xc3\xbcnicode'
}

@test "offline add hashes the password and the network shows up" {
	shareframe-wifi add office secret-pass
	assert_equal "$(saved)" "home
office"
	run grep -c secret-pass "$WPA_CONF"
	assert_output 0
}

@test "offline add keeps an SSID with quotes, backslashes or a newline in one block" {
	ssid="$(printf 'x"\\y\n}\nnetwork={ssid="evil"')"
	shareframe-wifi add "$ssid" secret-pass
	assert_equal "$(blocks)" 2
	assert_equal "$(saved | tail -n +2)" 'x\"\\y\n}\nnetwork={ssid=\"evil\"'
}

@test "offline add without a password saves an open network" {
	shareframe-wifi add cafe
	assert_equal "$(grep -c 'key_mgmt=NONE' "$WPA_CONF")" 1
}

@test "offline del removes exactly the named block, by its listed or its raw SSID" {
	shareframe-wifi add office secret-pass
	shareframe-wifi add ünicode secret-pass
	printf 'network={\n\tssid=c3bc6e69636f6466\n\tpsk=bbbb\n}\n' >> "$WPA_CONF"
	shareframe-wifi del ünicode
	shareframe-wifi del '\xc3\xbcnicodf'
	shareframe-wifi del home
	assert_equal "$(saved)" office
}

@test "offline del of an unknown network fails and keeps the file" {
	before="$(cat "$WPA_CONF")"
	run shareframe-wifi del nowhere
	assert_failure 1
	assert_output --partial "no network matching 'nowhere'"
	assert_equal "$(cat "$WPA_CONF")" "$before"
}

@test "offline mod changes the password of that network only" {
	shareframe-wifi add office old-pass
	shareframe-wifi mod office new-pass
	assert_equal "$(grep -c "psk=$(printf %s officenew-pass | sha256sum | cut -c1-64)" "$WPA_CONF")" 1
	assert_equal "$(grep -c 'psk=aaaa' "$WPA_CONF")" 1
	run grep -c new-pass "$WPA_CONF"
	assert_output 0
}

@test "offline mod of an unknown network fails" {
	run shareframe-wifi mod nowhere new-pass
	assert_failure 1
}

@test "online del of an SSID that looks like a number removes that network, not that id" {
	online "$(printf '0\thome')" "$(printf '1\t5')" "$(printf '5\toffice')"
	shareframe-wifi del 5
	assert_called 'wpa_cli -i wlan0 remove_network 1'
	assert_called 'wpa_cli -i wlan0 save_config'
}

# The dashboard shows the real name and sends it back; wpa_cli lists it escaped.
@test "online del and mod find a network by its real name as well as by its listed one" {
	online "$(printf '0\thome')" "$(printf '1\tCaf\\xc3\\xa9 Wi-Fi')"
	shareframe-wifi del 'Café Wi-Fi'
	assert_called 'wpa_cli -i wlan0 remove_network 1'
	shareframe-wifi mod 'Café Wi-Fi' new-password-1 >/dev/null
	assert_called 'wpa_cli -i wlan0 set_network 1 psk'
	shareframe-wifi del 'Caf\xc3\xa9 Wi-Fi'
	[ "$(grep -c 'remove_network 1' "$CALLS")" = 2 ] || fail "listed name not found"
}

@test "a password wpa_passphrase rejects saves nothing" {
	quiet_stub wpa_passphrase 'echo "Passphrase must be 8..63 characters"; exit 1'
	before="$(cat "$WPA_CONF")"
	run shareframe-wifi add office short
	assert_failure 1
	run shareframe-wifi mod home short
	assert_failure 1
	assert_equal "$(cat "$WPA_CONF")" "$before"
}

# bats test_tags=contract
@test "golden wifi-list.txt: saved networks as the dashboard parses them" {
	shareframe-wifi add 'Café Wi-Fi' secret-pass
	shareframe-wifi add 'my net' secret-pass
	shareframe-wifi add 5 secret-pass
	shareframe-wifi add 'quote"d' secret-pass
	shareframe-wifi list > "$T/list"
	assert_golden wifi-list.txt "$T/list"
}

# bats test_tags=contract
@test "golden wifi-status.txt: the association the dashboard shows" {
	quiet_stub wpa_cli 'printf "bssid=02:00:00:00:01:00\nfreq=2412\nssid=my net\nid=1\nmode=station\npairwise_cipher=CCMP\ngroup_cipher=CCMP\nkey_mgmt=WPA2-PSK\nwpa_state=COMPLETED\nip_address=10.0.2.15\naddress=02:00:00:00:00:00\n"'
	quiet_stub ip 'case "$1" in
		-4) printf "3: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000\n    inet 10.0.2.15/24 brd 10.0.2.255 scope global wlan0\n       valid_lft 86321sec preferred_lft 86321sec\n" ;;
	esac'
	shareframe-wifi status > "$T/status"
	assert_golden wifi-status.txt "$T/status"
}
