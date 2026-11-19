# SSDP: a description pointing at the dashboard, under one UUID for the board's lifetime.
load ../../support/common

setup() {
	sf_setup
	export DATA="$T/data" RUN_DIR="$T/run" PROC="$T/proc"
	mkdir -p "$PROC/sys/kernel/random"
	echo 0a1b2c3d-0000-4000-8000-000000000001 > "$PROC/sys/kernel/random/uuid"
	quiet_stub hostname 'echo shareframe-board-C3D4'
	stub ssdpd
}

@test "the description names the board and keeps its UUID across restarts" {
	"$S6/ssdpd"
	echo 0a1b2c3d-0000-4000-8000-000000000002 > "$PROC/sys/kernel/random/uuid"
	"$S6/ssdpd"
	run cat "$RUN_DIR/ssdp/description.xml"
	assert_line '  <friendlyName>shareframe-board-C3D4</friendlyName>'
	assert_line '  <UDN>uuid:0a1b2c3d-0000-4000-8000-000000000001</UDN>'
	assert_line '  <presentationURL>/</presentationURL>'
	assert_called "ssdpd -n -s -r 30 -w -c $DATA/ssdpd/ssdpd.cache -d http://%s/ssdp/description.xml wlan0 usb0"
}
