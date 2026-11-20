# The Wi-Fi mode manager: station, hotspot fallback and the way back, against stubbed radio
# tools and the real LED arbiter.
load ../../support/common

setup() {
	sf_setup
	mkdir -p "$T/ctl" "$T/run" "$T/led"
	for cmd in shareframe-event s6-svc; do stub "$cmd"; done
	# The radio as the control files describe it.
	quiet_stub wpa_cli "[ -f '$T/ctl/assoc' ] && printf 'wpa_state=COMPLETED\\nssid=home\\n' || printf 'wpa_state=SCANNING\\n'"
	quiet_stub ip "[ -f '$T/ctl/address' ] && echo '    inet 192.168.1.5/24 scope global wlan0'
[ -f '$T/ctl/linklocal' ] && echo '    inet 169.254.7.7/16 scope link wlan0'
exit 0"
	quiet_stub ping "[ -f '$T/ctl/internet' ]"
	stub shareframe-ap '[ "$1" = status ] && echo "up stations=0"; exit 0'
	quiet_stub wifi-stack-restart 'exit 0'
	# Every wait of the manager shrinks to a moment.
	quiet_stub sleep 'exec /usr/bin/sleep 0.03'
	export STATE_DIR="$T/run" SVC="$T/service" CONSOLE=/dev/null LOGGER=true STACK_RESTART="$STUBS/wifi-stack-restart"
	export AP_CONF="$T/ap.conf" WPA_CONF="$T/wpa_supplicant.conf" JOINED_FLAG="$T/data/wifi-joined"
	export ASSOC_TIMEOUT=4 DHCP_GRACE=4 NO_ADDR_TIMEOUT=4 AP_RETRY_EVERY=1000000
	export LED="$T/led" SAFE_MODE="$T/run/safe-mode" LED_RUN="$T/run/led"
	echo 1 > "$T/led/max_brightness"
	echo "none [timer]" > "$T/led/trigger"
	printf "AP_SSID='frame-ap'\nAP_PASS='hotspot123'\n" > "$AP_CONF"
	printf 'network={\n\tssid="home"\n}\n' > "$WPA_CONF"
	# A frame set up before: marking it would sync the disk on every first connect.
	mkdir -p "$T/data" && echo 1700000000 > "$JOINED_FLAG"
	pid=
}

teardown() { stop; }

start() { rm -f "$CALLS" "$T/run/wifi-mode"; "$S6/wifi-mode-manager" 3>&- & pid=$!; }
stop() { [ -z "$pid" ] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=; } || true; }
radio() { touch "${@/#/$T/ctl/}"; }
no_radio() { rm -f "${@/#/$T/ctl/}"; }

mode() { cat "$T/run/wifi-mode" 2>/dev/null; }
json() { sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p" "$T/run/wifi-mode.json" 2>/dev/null; }
led() {
	case "$(cat "$T/led/trigger")/$(cat "$T/led/delay_on" 2>/dev/null)/$(cat "$T/led/delay_off" 2>/dev/null)" in
		timer/200/9800) echo normal ;;
		timer/200/200) echo wifi-connecting ;;
		timer/500/2000) echo wifi-down ;;
		timer/800/800) echo ap-mode ;;
		*) echo other ;;
	esac
}
is() { [ "$("$1" "${@:3}")" = "$2" ]; } # is <getter> <value> [getter args]
failed_recently() { [ "$(json last_failed_at)" -gt 0 ]; }

# The board on its known network, settled.
connected() {
	radio assoc address internet
	start
	eventually 10 is mode connected
}

# The known network went away and the hotspot is up.
in_hotspot() {
	connected
	rm -f "$CALLS"
	no_radio assoc address internet
	eventually 10 is mode ap
}

@test "known network in reach: connected, published, LED normal, station services up" {
	connected
	assert_equal "$(json ssid)" home
	eventually 10 is json true internet
	eventually 10 is led normal
	assert_called "s6-svc -u $T/service/wpa_supplicant"
	assert_called 'shareframe-event wifi connected'
}

# The display keeps a fresh frame's setup screen up until this flag exists.
@test "the first connection marks the frame as set up, later ones leave the mark alone" {
	rm "$JOINED_FLAG"
	connected
	eventually 5 test -s "$JOINED_FLAG"
	stop
	echo kept > "$JOINED_FLAG"
	connected
	assert_equal "$(cat "$JOINED_FLAG")" kept
}

@test "an LED repainted by a stack restart is set right again" {
	connected
	eventually 10 is led normal
	shareframe-led wifi-connecting
	eventually 10 is led normal
}

@test "no internet: stays a station, says so on the LED and in the JSON" {
	connected
	no_radio internet
	eventually 10 is led wifi-down
	eventually 10 is json false internet
	assert_equal "$(mode)" connected
	refute_called 'shareframe-ap up'
}

@test "network gone: hotspot up, station pinned down, credentials and failure published" {
	in_hotspot
	assert_called 'shareframe-ap up'
	assert_called "s6-svc -d $T/service/wpa_supplicant"
	assert_file_exists "$T/run/wifi-switching"
	assert_equal "$(json ap_ssid)" frame-ap
	failed_recently
	eventually 10 is led ap-mode
	assert_called 'shareframe-event wifi ap fallback'
}

@test "a retry asked from the dashboard brings the station back and forgets the failure" {
	in_hotspot
	rm -f "$CALLS"
	radio assoc address internet
	touch "$T/run/wifi-retry-requested"
	eventually 10 is mode connected
	assert_called 'shareframe-ap down'
	assert_file_not_exists "$T/run/wifi-switching"
	assert_file_not_exists "$T/run/wifi-retry-requested"
	eventually 10 is json 0 last_failed_at
	eventually 10 is led normal
}

@test "a lease earlier this boot: a lost lease keeps the station, no hotspot" {
	connected
	stop
	no_radio address internet
	radio linklocal
	start
	eventually 10 is mode connected
	refute_called 'shareframe-ap up'
}

@test "no lease since boot: hotspot naming the cause, and back after a retry with a lease" {
	radio assoc linklocal
	start
	eventually 10 is mode ap
	assert_called 'shareframe-event wifi ap fallback (no address from home)'
	failed_recently
	no_radio linklocal
	radio address internet
	touch "$T/run/wifi-retry-requested"
	eventually 10 is mode connected
}

@test "hotspot credentials with quotes and backslashes stay valid JSON and round-trip" {
	printf '%s\n' "AP_SSID='frame \"one\"'" "AP_PASS='pa\"ss\\word'\\''s'" > "$AP_CONF"
	in_hotspot
	run jq -r '.ap_ssid, .ap_password' "$T/run/wifi-mode.json"
	assert_success
	assert_output "frame \"one\"
pa\"ss\\word's"
}

# bats test_tags=contract
@test "golden wifi-mode-connected.json: the mode the dashboard and display read" {
	fixed_clock
	connected
	eventually 10 is json true internet
	assert_golden wifi-mode-connected.json "$T/run/wifi-mode.json"
}

# bats test_tags=contract
@test "golden wifi-mode-ap.json: the hotspot with credentials that need escaping" {
	fixed_clock
	printf '%s\n' "AP_SSID='frame \"one\"'" "AP_PASS='pa\"ss\\word'\\''s'" > "$AP_CONF"
	in_hotspot
	eventually 10 failed_recently
	assert_golden wifi-mode-ap.json "$T/run/wifi-mode.json"
}
