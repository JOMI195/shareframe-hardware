# The health daemon (one pass with ONCE=1): oom, temperature and disk to health.json, the
# event log on a change only, and the error LED on a critical fault.
load ../../support/common

setup() {
	sf_setup
	fixed_clock
	export STATE_DIR="$T/run" DATA_DIR="$T/data" PROC="$T/proc" THERMAL="$T/temp" CONSOLE=/dev/null ONCE=1
	export DMESG="$STUBS/dmesg" DISK_MOUNTS="$T"
	mkdir -p "$PROC"
	echo '100.00 50.00' > "$PROC/uptime"
	printf 'MemTotal: 438284 kB\nMemAvailable: 312000 kB\n' > "$PROC/meminfo"
	echo 45000 > "$THERMAL"
	quiet_stub dmesg "cat '$T/dmesg' 2>/dev/null"
	used 50
	stub shareframe-event
	stub shareframe-led
}

used() { # <percent of the disk in use> [inodes in use]
	quiet_stub df "if [ \"\$1\" = -i ]; then u=${2:-1}; else u=$1; fi; printf 'Filesystem 1K-blocks Used Available Use%% Mounted\n/dev/x 1000 0 0 %s%% /x\n' \"\$u\""
}

health() { "$S6/shareframe-health"; }
field() { jq -r ".$1" "$STATE_DIR/health.json"; }

@test "all fine: ok everywhere, watermarks recorded, no LED claim" {
	health
	assert_equal "$(field overall)/$(field oom)/$(field temp)/$(field disk)" ok/ok/ok/ok
	assert_equal "$(cat "$STATE_DIR/health")" ok
	assert_equal "$(cat "$STATE_DIR/temp_peak")" 45000
	assert_equal "$(cat "$STATE_DIR/ram_avail_min")" 312000
	refute_called shareframe-led
}

@test "a hot CPU warns, hotter is critical and claims the error LED" {
	echo 82000 > "$THERMAL"
	health
	assert_equal "$(field temp)/$(field overall)" warn/warn
	echo 90000 > "$THERMAL"
	health
	assert_equal "$(field temp)/$(field overall)" critical/critical
	assert_called 'shareframe-led error'
	assert_called 'shareframe-event temp warn -> critical (90C)'
}

@test "a state is logged when it changes, not on every pass" {
	echo 82000 > "$THERMAL"
	health
	health
	assert_equal "$(grep -c '^shareframe-event temp' "$CALLS")" 1
}

@test "an under-voltage in the kernel log is critical and counted" {
	echo 'hwmon hwmon1: Undervoltage detected!' > "$T/dmesg"
	health
	assert_equal "$(field temp)" critical
	assert_equal "$(cat "$STATE_DIR/uv_events")" 1
}

@test "an earlyoom kill stays critical for the hold time" {
	echo 1 > "$STATE_DIR/oom-kills" 2>/dev/null || { mkdir -p "$STATE_DIR"; echo 1 > "$STATE_DIR/oom-kills"; }
	health
	assert_equal "$(field oom)/$(field oom_kills)" critical/1
	echo '200.00 50.00' > "$PROC/uptime"
	health
	assert_equal "$(field oom)" critical
	echo '500.00 50.00' > "$PROC/uptime"
	health
	assert_equal "$(field oom)" ok
}

@test "a nearly full disk warns, a full one or used-up inodes are critical" {
	used 92
	health
	assert_equal "$(field disk)" warn
	used 97
	health
	assert_equal "$(field disk)" critical
	used 50 96
	health
	assert_equal "$(field disk)" critical
}

@test "a board without a thermal zone still reports" {
	rm "$THERMAL"
	health
	assert_equal "$(field temp)" ok
}
