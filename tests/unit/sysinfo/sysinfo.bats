# The login banner: parses shareframe-sysinfo's key=value lines into rows.
load ../../support/common

setup() {
	host_setup
	quiet_stub emitter "cat '$T/kv'"
	gcc -Wall -Wextra -Werror -DEMITTER="\"$STUBS/emitter\"" -o "$T/sysinfo" "$PKG/sysinfo/src/sysinfo.c"
	export NO_COLOR=1 USER=root
}

@test "rows come from the emitted keys, missing ones are skipped" {
	printf 'hostname=frame-1a2b\nversion=1.4.0\nserial=000123ab\nuptime_seconds=3720\n' > "$T/kv"
	run "$T/sysinfo"
	assert_success
	assert_line 'root@frame-1a2b'
	assert_line --regexp '^Version +1\.4\.0$'
	assert_line --regexp '^Serial +000123ab$'
	assert_line --regexp '^Uptime +1h 2m$'
	refute_line --partial 'Kernel'
}

@test "keys after the first 64 still make their rows" {
	for i in $(seq 1 80); do echo "proc_filler_$i=1"; done > "$T/kv"
	printf 'ip_usb0=10.55.0.1\nload_1=0.1\nload_5=0.2\nload_15=0.3\n' >> "$T/kv"
	run "$T/sysinfo"
	assert_line --regexp '^USB +10\.55\.0\.1$'
	assert_line --regexp '^Load +0\.1 0\.2 0\.3$'
}
