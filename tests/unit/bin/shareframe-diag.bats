# The support package: sectioned board state, gzip, with credentials masked.
load ../../support/common

setup() {
	sf_setup
	export ETC="$T/etc" DATA_DIR="$T/data" RUN_DIR="$T/run" SVC="$T/service" LOG_DIR="$T/log"
	mkdir -p "$ETC" "$DATA_DIR/last-reset" "$RUN_DIR" "$SVC/shareframe-display" "$LOG_DIR/shareframe"
	echo VERSION=1.4.0 > "$ETC/shareframe-release"
	echo '{"overall":"ok"}' > "$RUN_DIR/health.json"
	echo '1 2026-01-02T03:04:05 [boot] clean boot 12' > "$DATA_DIR/health.log"
	echo 'Kernel panic' > "$DATA_DIR/last-reset/dmesg-ramoops-0"
	printf '[12:00:01] wpa_supplicant: psk=s3cr3t-psk\nnormal line\n' > "$LOG_DIR/messages"
	printf '[12:00:02] [ws] Bearer eyJhbGciOi.eyJzdWIi.sig sent\n[12:00:03] dashboard_initial_password = "hunter2"\n' > "$LOG_DIR/shareframe/shareframe-websocket.log"
	quiet_stub shareframe-sysinfo 'printf "version=1.4.0\nwifi_ssid=my home\n"'
	quiet_stub s6-svstat 'echo "up (pid 1234) 56 seconds"'
	for cmd in uptime free df rauc dmesg; do quiet_stub "$cmd" "echo $cmd output"; done
}

package() { shareframe-diag | gunzip; }

@test "every section is there, with the state behind it" {
	run package
	for s in release sysinfo uptime services health.json events update-history rauc last-reset dmesg syslog shareframe-websocket.log; do
		assert_line "===== $s ====="
	done
	assert_line 'VERSION=1.4.0'
	assert_line 'shareframe-display: up (pid 1234) 56 seconds'
	assert_line '--- dmesg-ramoops-0'
	assert_line 'Kernel panic'
}

@test "credentials are masked, the rest of their line stays" {
	run package
	refute_output --partial s3cr3t-psk
	refute_output --partial hunter2
	refute_output --partial eyJ
	assert_line '[12:00:01] wpa_supplicant: psk=***'
	assert_line '[12:00:03] dashboard_initial_password =***'
	assert_line '[12:00:02] [ws] Bearer *** sent'
	assert_line 'normal line'
}

@test "the SSID stays out" {
	run package
	refute_output --partial 'my home'
}

@test "--out writes the package to a file" {
	shareframe-diag --out "$T/pkg.gz"
	gunzip -t "$T/pkg.gz"
}
