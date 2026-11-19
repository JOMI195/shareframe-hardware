# The A/B commit gate of a trial boot: commits when the new system is healthy, else reboots
# back to the committed slot.
load ../../support/common

setup() {
	sf_setup
	GATE="$S6/rauc-mark-good"
	for cmd in rauc shareframe-update-history shareframe-event reboot; do stub "$cmd"; done
	quiet_stub s6-svstat 'echo true'
	stub shareframe-update-verify "exit \"\$(cat '$T/verify-rc' 2>/dev/null || echo 0)\""
	quiet_stub curl "exit \"\$(cat '$T/curl-rc')\""
	# The gate's polling interval shrinks to a moment.
	quiet_stub sleep 'exec /usr/bin/sleep 0.05'
	export DEADLINE=1 PENDING_FILE="$T/pending" HEALTH_JSON="$T/health.json" WIFI_JSON="$T/wifi-mode.json"
	export BACKEND_OK="$T/backend-ok" CMDLINE="$T/cmdline" REMOTE_SAFE_MODE="$T/safe-mode-remote"
	echo 0 > "$T/curl-rc"
}

trial() { # <health overall> <internet true|false> <backend reached yes|no>
	echo B > "$PENDING_FILE"
	printf 'console=ttyS1,115200 rauc.slot=B\n' > "$CMDLINE"
	printf '{"overall":"%s"}\n' "$1" > "$HEALTH_JSON"
	printf '{"mode":"connected","internet":%s}\n' "$2" > "$WIFI_JSON"
	[ "$3" = no ] || : > "$BACKEND_OK"
}

# The gate backgrounds itself; this waits for its verdict.
verdict() {
	local _
	for _ in $(seq 100); do
		called 'rauc status mark-good' && { echo commit; return; }
		called reboot && { echo reboot; return; }
		sleep 0.1
	done
	echo none
}

@test "healthy and the backend reached: commits" {
	trial ok true yes
	"$GATE" >/dev/null 2>&1
	assert_equal "$(verdict)" commit
}

@test "without internet the backend is not required" {
	trial ok false no
	"$GATE" >/dev/null 2>&1
	assert_equal "$(verdict)" commit
}

@test "a commit lifts remote safe mode" {
	: > "$REMOTE_SAFE_MODE"
	trial ok false no
	"$GATE" >/dev/null 2>&1
	assert_equal "$(verdict)" commit
	eventually 3 test ! -f "$REMOTE_SAFE_MODE"
}

@test "a rollback keeps remote safe mode" {
	: > "$REMOTE_SAFE_MODE"
	trial critical false no
	"$GATE" >/dev/null 2>&1
	assert_equal "$(verdict)" reboot
	assert_file_exists "$REMOTE_SAFE_MODE"
}

@test "internet but never reached the backend: reboots and logs why" {
	trial ok true no
	"$GATE" >/dev/null 2>&1
	assert_equal "$(verdict)" reboot
	assert_called 'shareframe-event update commit gate'
}

@test "critical health: reboots" {
	trial critical false no
	"$GATE" >/dev/null 2>&1
	assert_equal "$(verdict)" reboot
}

@test "dashboard unreachable: reboots" {
	trial ok true yes
	echo 7 > "$T/curl-rc"
	"$GATE" >/dev/null 2>&1
	assert_equal "$(verdict)" reboot
}

@test "not a trial boot: does nothing" {
	trial ok true yes
	echo A > "$PENDING_FILE"
	"$GATE" >/dev/null 2>&1
	sleep 0.5
	assert_file_not_exists "$CALLS"
}

@test "the gate checks what the boot restored, and an identity still gone keeps it from committing" {
	trial ok true yes
	echo 1 > "$T/verify-rc"
	"$GATE" >/dev/null 2>&1
	assert_equal "$(verdict)" reboot
	assert_called 'shareframe-update-verify check'
	refute_called 'shareframe-update-verify restore'
}
