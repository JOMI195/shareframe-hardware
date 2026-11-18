# Finish hook of wpa_supplicant and dhcpcd: bounce wlan0 and restart both, unless the board is
# shutting down or the mode manager is switching to the hotspot.
load ../../support/common

setup() {
	sf_setup
	export RUN="$T/run" SVC="$T/service" CONSOLE=/dev/null
	mkdir -p "$RUN/shareframe"
	stub ip
	stub s6-svc
	stub shareframe-led
}

restart() { "$S6/wifi-stack-restart" wpa_supplicant; }

@test "the link is bounced and wpa_supplicant restarts before dhcpcd" {
	restart
	assert_called 'ip addr flush dev wlan0'
	assert_equal "$(grep '^s6-svc' "$CALLS")" "s6-svc -r $SVC/wpa_supplicant
s6-svc -r $SVC/dhcpcd-wlan"
	assert_called 'shareframe-led wifi-connecting'
	assert_file_not_exists "$RUN/wifi-stack-restart.lock"
}

@test "during a shutdown or a switch to the hotspot it stands back" {
	: > "$RUN/shutting-down"
	restart
	: > "$RUN/shareframe/wifi-switching"
	rm "$RUN/shutting-down"
	restart
	assert_file_not_exists "$CALLS"
}

@test "a second trigger while one runs does nothing" {
	mkdir "$RUN/wifi-stack-restart.lock"
	sleep 30 3>&- &
	echo $! > "$RUN/wifi-stack-restart.lock/pid"
	restart
	kill $!
	refute_called s6-svc
}

@test "a lock left by a dead run is taken over" {
	mkdir "$RUN/wifi-stack-restart.lock"
	echo 999999 > "$RUN/wifi-stack-restart.lock/pid"
	restart
	assert_called "s6-svc -r $SVC/wpa_supplicant"
}
