# The board's metrics as key=value lines: the dashboard's system page and the heartbeat parse them.
load ../../support/common

setup() {
	sf_setup
	fixed_clock
	R="$T/root"
	export PROC="$R/proc" SYSFS="$R/sys" ETC="$R/etc" DATA_DIR="$R/data" RUN_DIR="$R/run" SVC="$R/service"
	export DATA_MNT="$R/data" ROOT_MNT="$R" CMDLINE="$PROC/cmdline" PENDING_FILE="$R/rauc/pending"
	mkdir -p "$PROC/device-tree" "$PROC/4242/fd" "$ETC" "$DATA_DIR" "$RUN_DIR" "$R/rauc" \
		"$SYSFS/class/thermal/thermal_zone0" "$SYSFS/devices/system/cpu/cpu0/cpufreq" "$SYSFS/class/net/wlan0" \
		"$SYSFS/block/mmcblk0/device" "$SYSFS/fs/f2fs/mmcblk0p6"
	cp "$SRC/tests/support/fixtures/cpuinfo-pi0w" "$PROC/cpuinfo"
	printf 'Raspberry Pi Zero W Rev 1.1\0' > "$PROC/device-tree/model"
	echo 'console=ttyS1,115200 rauc.slot=B panic=10' > "$PROC/cmdline"
	echo '3725.42 3500.00' > "$PROC/uptime"
	printf 'MemTotal:         438284 kB\nMemFree:          100000 kB\nMemAvailable:     312000 kB\n' > "$PROC/meminfo"
	echo '0.25 0.31 0.40 1/97 1234' > "$PROC/loadavg"
	echo 'cpu  1000 0 500 8500 0 0 0 0 0 0' > "$PROC/stat"
	echo 'cpu  1100 0 550 8850 0 0 0 0 0 0' > "$T/stat-later"
	printf 'Name:\tshareframe-disp\nVmHWM:\t   9000 kB\nVmRSS:\t   8000 kB\nVmData:\t   5000 kB\nVmStk:\t    132 kB\nThreads:\t3\n' > "$PROC/4242/status"
	touch "$PROC/4242/fd/0" "$PROC/4242/fd/1" "$PROC/4242/fd/2"
	echo 'PRETTY_NAME="Shareframe OS 1.10"' > "$ETC/os-release"
	printf 'VERSION=1.10\nOS_SHA=0123456\nAPP_SHA=abc1234-dirty\nBUILD_DATE=2026-01-01\n' > "$ETC/shareframe-release"
	echo 12 > "$DATA_DIR/boot_count"
	echo 2 > "$DATA_DIR/crash_count"
	echo garbage > "$DATA_DIR/unclean_resets"
	echo ok > "$RUN_DIR/health"
	echo '{"overall":"ok","oom":"ok","temp":"warn","disk":"ok"}' > "$RUN_DIR/health.json"
	echo 61500 > "$RUN_DIR/temp_peak"
	echo 250000 > "$RUN_DIR/ram_avail_min"
	echo connected > "$RUN_DIR/wifi-mode"
	echo '{"mode":"connected","ssid":"my net","internet":true,"ap_ssid":"shareframe-board-C3D4"}' > "$RUN_DIR/wifi-mode.json"
	echo 48312 > "$SYSFS/class/thermal/thermal_zone0/temp"
	echo 1000000 > "$SYSFS/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
	echo up > "$SYSFS/class/net/wlan0/operstate"
	echo SD16G > "$SYSFS/block/mmcblk0/device/name"
	echo 0x000003 > "$SYSFS/block/mmcblk0/device/manfid"
	echo 0x5344 > "$SYSFS/block/mmcblk0/device/oemid"
	echo '05/2023' > "$SYSFS/block/mmcblk0/device/date"
	echo 1048576 > "$SYSFS/fs/f2fs/mmcblk0p6/lifetime_write_kbytes"
	quiet_stub hostname 'echo shareframe-board-C3D4'
	quiet_stub uname 'echo Linux 6.18.12-sf'
	quiet_stub s6-svstat '[ "$3" = "$SVC/shareframe-display" ] && echo 4242 || echo -1'
	quiet_stub sleep "cp '$T/stat-later' '$PROC/stat'"
	quiet_stub ip 'case "$4" in wlan0) echo "    inet 10.0.2.15/24 brd 10.0.2.255 scope global wlan0" ;; usb0) echo "    inet 10.55.0.1/24 scope global usb0" ;; esac'
	quiet_stub iw 'printf "Connected to 02:00:00:00:01:00 (on wlan0)\n\tsignal: -61 dBm\n"'
	quiet_stub df 'printf "Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/x %s 1000 %s 10%% /x\n" "$([ "$2" = "$DATA_MNT" ] && echo 420000 || echo 250000)" "$([ "$2" = "$DATA_MNT" ] && echo 380000 || echo 0)"'
}

value() { shareframe-sysinfo | sed -n "s/^$1=//p"; }

@test "identity, release and slot: the booted slot is a trial while it is pending" {
	echo B > "$PENDING_FILE"
	run shareframe-sysinfo
	assert_line 'hostname=shareframe-board-C3D4'
	assert_line 'version=1.10'
	assert_line 'os_sha=0123456'
	assert_line 'serial=00000000a1b2c3d4'
	assert_line 'host_model=Raspberry Pi Zero W Rev 1.1'
	assert_line 'boot_slot=B'
	assert_line 'slot_trial=true'
}

@test "metrics are numbers in their units, a corrupt counter reads as 0" {
	run shareframe-sysinfo
	assert_line 'uptime_seconds=3725'
	assert_line 'cpu_temp_celsius=48.3'
	assert_line 'cpu_freq_mhz=1000'
	assert_line 'cpu_usage_percent=30.0'
	assert_line 'ram_total_bytes=448802816'
	assert_line 'storage_data_free_bytes=389120000'
	assert_line 'unclean_resets=0'
	assert_line 'proc_display_rss_bytes=8192000'
	assert_line 'proc_display_fds=3'
	refute_line --partial 'proc_websocket_'
}

@test "the hotspot reports its own SSID, never the password" {
	echo ap > "$RUN_DIR/wifi-mode"
	echo '{"mode":"ap","ssid":"","ap_ssid":"shareframe-board-C3D4","ap_password":"secret-pass"}' > "$RUN_DIR/wifi-mode.json"
	run shareframe-sysinfo
	assert_line 'wifi_ssid=shareframe-board-C3D4'
	refute_output --partial secret-pass
}

@test "missing sources leave their keys out and the rest is still printed" {
	rm -rf "$SYSFS" "$RUN_DIR" "$ETC"
	run shareframe-sysinfo
	assert_success
	refute_line --partial 'cpu_temp_celsius='
	refute_line --partial 'version='
	assert_line 'uptime_seconds=3725'
}

# bats test_tags=contract
@test "golden sysinfo.txt: every key the board apps parse" {
	shareframe-sysinfo > "$T/sysinfo.txt"
	assert_golden sysinfo.txt "$T/sysinfo.txt"
}
