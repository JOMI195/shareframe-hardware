# The Wi-Fi mode manager: station, hotspot fallback and the way back, against stubbed radio
# tools and the real LED arbiter.
load ../../support/common

setup() {
	sf_setup
	mkdir -p "$T/ctl" "$T/run" "$T/led"
	for cmd in shareframe-event s6-svc; do stub "$cmd"; done
	# The radio as the control files describe it.
	quiet_stub wpa_cli "case \"\$3\" in
	scan_results) echo 'bssid / frequency / signal level / flags / ssid'; cat '$T/ctl/scan' 2>/dev/null ;;
	list_networks) echo 'network id / ssid / bssid / flags'; printf '0\\thome\\tany\\t%s\\n' \"\$(cat '$T/ctl/flags' 2>/dev/null)\" ;;
	*) [ -f '$T/ctl/assoc' ] && printf 'wpa_state=COMPLETED\\nssid=home\\n' || printf 'wpa_state=SCANNING\\n' ;;
	esac"
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
	export BACKEND_OK="$T/run/backend-ok"
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
seen() { printf '00:11:22:33:44:55\t2412\t%s\t%s\t%s\n' "$2" "$3" "$1" >> "$T/ctl/scan"; } # seen <ssid> <signal> <flags>
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

@test "each station attempt leaves the networks in reach for the dashboard, strongest first" {
	seen home -70 '[WPA2-PSK-CCMP][ESS]'
	seen home -40 '[WPA2-PSK-CCMP][ESS]'
	seen 'Caf\xc3\xa9 "x"' -60 '[ESS]'
	seen '' -30 '[WPA2-PSK-CCMP][ESS]'
	connected
	eventually 5 test -s "$T/run/wifi-scan.json"
	run jq -c '.networks' "$T/run/wifi-scan.json"
	assert_output '[{"ssid":"home","signal":-40,"secured":true},{"ssid":"Caf\\xc3\\xa9 \"x\"","signal":-60,"secured":false}]'
	[ "$(jq '.at' "$T/run/wifi-scan.json")" -gt 0 ]
}

# Logs and events end up in diagnostics and on the server; the owner's network names stay on the frame.
@test "the logs and events never name a network" {
	export CONSOLE="$T/console"
	radio assoc linklocal
	start
	eventually 10 is mode ap
	no_radio linklocal
	radio address internet
	touch "$T/run/wifi-retry-requested"
	eventually 10 is mode connected
	run grep -c home "$T/console" "$CALLS"
	refute_output --partial ':1'
	assert_file_exists "$T/console"
}

# The setup screen and the dashboard tell the owner what to fix.
@test "a refused password is named when the hotspot comes back" {
	seen home -40 '[WPA2-PSK-CCMP][ESS]'
	echo '[TEMP-DISABLED]' > "$T/ctl/flags"
	start
	eventually 10 is mode ap
	eventually 10 is json wrong_password last_failed_reason
}

@test "a saved network out of reach is named" {
	seen neighbour -40 '[WPA2-PSK-CCMP][ESS]'
	start
	eventually 10 is mode ap
	eventually 10 is json not_found last_failed_reason
}

@test "a saved network in reach that does not take the frame is named" {
	seen home -40 '[WPA2-PSK-CCMP][ESS]'
	start
	eventually 10 is mode ap
	eventually 10 is json not_joined last_failed_reason
}

@test "a network that hands out no address is named" {
	radio assoc linklocal
	start
	eventually 10 is mode ap
	eventually 10 is json no_address last_failed_reason
}

@test "with nothing saved the hotspot stays up, no station retry tears it down" {
	printf 'ctrl_interface=/var/run/wpa_supplicant\n' > "$WPA_CONF"
	export AP_RETRY_EVERY=1
	start
	eventually 10 is mode ap
	eventually 10 is json no_networks last_failed_reason
	rm -f "$CALLS"
	/usr/bin/sleep 1
	refute_called 'shareframe-ap down'
}

# Some networks block ping; the heartbeat's mark proves the way out.
@test "a recent answer from the server counts as internet where ping is blocked" {
	date +%s > "$BACKEND_OK"
	radio assoc address
	start
	eventually 10 is mode connected
	eventually 10 is json true internet
}

@test "an old answer from the server does not count as internet" {
	echo 1000 > "$BACKEND_OK"
	radio assoc address
	start
	eventually 10 is mode connected
	eventually 10 is json false internet
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
	assert_called 'shareframe-event wifi ap fallback (no address from the network)'
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
	echo '[TEMP-DISABLED]' > "$T/ctl/flags"
	in_hotspot
	eventually 10 failed_recently
	assert_golden wifi-mode-ap.json "$T/run/wifi-mode.json"
}

# bats test_tags=contract
@test "golden wifi-scan.json: the networks the dashboard offers, with names that need escaping" {
	fixed_clock
	seen home -48 '[WPA2-PSK-CCMP][ESS]'
	seen 'Caf\xc3\xa9 "Gast"' -61 '[ESS]'
	seen 'back\\slash' -75 '[WPA3-SAE-CCMP][ESS]'
	connected
	eventually 5 test -s "$T/run/wifi-scan.json"
	assert_golden wifi-scan.json "$T/run/wifi-scan.json"
}
