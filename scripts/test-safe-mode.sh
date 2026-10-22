#!/usr/bin/env bash
# Host tests for display safe mode: boot-guard, display-crash-guard, remote safe mode, LED priority.
set -euo pipefail

S6="$(cd "$(dirname "$0")/.." && pwd)/br2-external/overlay/usr/libexec/s6"
LED_CMD="$(cd "$(dirname "$0")/.." && pwd)/br2-external/overlay/usr/bin/shareframe-led"
SAFE_CMD="$(cd "$(dirname "$0")/.." && pwd)/br2-external/overlay/usr/bin/shareframe-safe-mode"
T="$(mktemp -d)"
# boot-guard backgrounds a STABLE-long sleep; a unique length lets the trap reap it.
NAP=86399
trap 'pkill -x -f "sleep $NAP" || true; rm -rf "$T"' EXIT

mkdir -p "$T/bin"
for cmd in shareframe-event shareframe-led s6-svc; do
	printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$cmd" "$T" > "$T/bin/$cmd"
done
chmod +x "$T/bin/"*

export PATH="$T/bin:$PATH"
export DATA_DIR="$T/data" RUN_DIR="$T/run" PENDING_FILE="$T/pending" CMDLINE="$T/cmdline" UPTIME="$T/uptime"
mkdir -p "$DATA_DIR" "$RUN_DIR"
printf 'console=ttyS1,115200 rauc.slot=A\n' > "$CMDLINE"

fail=0
check() { # <desc> <expected> <actual>
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi
}
exists() { [ -f "$1" ] && echo yes || echo no; }

boot() { # one unclean boot: /run is fresh, /data persists
	rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
	: > "$RUN_DIR/unclean-boot"
	STABLE=$NAP "$S6/boot-guard"
}

clean_boot() {
	rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
	STABLE=$NAP "$S6/boot-guard"
}

for _ in 1 2 3 4; do boot; done
check "4 unclean boots: no safe mode" no "$(exists "$RUN_DIR/safe-mode")"
boot
check "5th unclean boot: safe mode" boot-loop "$(cat "$RUN_DIR/safe-mode" 2>/dev/null)"
check "5th unclean boot: panel clear requested" yes "$(exists "$RUN_DIR/safe-mode-clear")"
check "5th unclean boot: event logged" yes "$(grep -q '^shareframe-event safe-mode boot loop' "$T/calls" && echo yes || echo no)"
check "5th unclean boot: LED protected" yes "$(grep -q '^shareframe-led protected' "$T/calls" && echo yes || echo no)"
boot
check "6th unclean boot: still safe mode" boot-loop "$(cat "$RUN_DIR/safe-mode" 2>/dev/null)"
check "6th unclean boot: no second clear" no "$(exists "$RUN_DIR/safe-mode-clear")"

clean_boot
check "clean boot: no safe mode" no "$(exists "$RUN_DIR/safe-mode")"
check "clean boot resets the counter" 0 "$(cat "$DATA_DIR/short_boots")"
check "clean boot re-arms the panel clear" no "$(exists "$DATA_DIR/safe-mode-cleared")"
for _ in 1 2 3 4; do boot; done
check "4 unclean boots after a clean one: no safe mode" no "$(exists "$RUN_DIR/safe-mode")"

echo A > "$PENDING_FILE"
boot
check "trial boot is exempt" no "$(exists "$RUN_DIR/safe-mode")"
rm -f "$PENDING_FILE"

rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
: > "$RUN_DIR/unclean-boot"
STABLE=1 "$S6/boot-guard"
for _ in $(seq 30); do [ "$(cat "$DATA_DIR/short_boots")" = 0 ] && break; sleep 0.1; done
check "stable uptime resets the counter" 0 "$(cat "$DATA_DIR/short_boots")"
check "stable uptime re-arms the panel clear" no "$(exists "$DATA_DIR/safe-mode-cleared")"

called() { grep -qs "^$1" "$T/calls" && echo yes || echo no; }

rm -rf "$RUN_DIR" "$DATA_DIR" "$T/calls"; mkdir -p "$RUN_DIR" "$DATA_DIR"
"$SAFE_CMD" enter >/dev/null
check "remote enter: marker written" yes "$(exists "$DATA_DIR/safe-mode-remote")"
check "remote enter: safe mode" remote "$(cat "$RUN_DIR/safe-mode" 2>/dev/null)"
check "remote enter: display stopped" yes "$(called 's6-svc -d /run/service/shareframe-display')"
check "remote enter: event logged" yes "$(called 'shareframe-event safe-mode remote: display disabled')"
check "remote enter: no panel clear" no "$(exists "$RUN_DIR/safe-mode-clear")"
clean_boot
check "remote: clean boot keeps safe mode" remote "$(cat "$RUN_DIR/safe-mode" 2>/dev/null)"
check "remote: no panel clear on boot" no "$(exists "$RUN_DIR/safe-mode-clear")"
for _ in 1 2 3 4 5; do boot; done
check "remote: boot loop keeps the remote reason" remote "$(cat "$RUN_DIR/safe-mode" 2>/dev/null)"
check "remote: boot loop adds no panel clear" no "$(exists "$RUN_DIR/safe-mode-clear")"
echo A > "$PENDING_FILE"
clean_boot
check "remote: trial boot runs the display" no "$(exists "$RUN_DIR/safe-mode")"
rm -f "$T/calls"
set +e; out=$("$SAFE_CMD" enter); rc=$?; set -e
check "remote enter on trial boot refused" 1 "$rc"
check "remote enter on trial boot gives a reason" yes "$(echo "$out" | grep -q 'not confirmed' && echo yes || echo no)"
check "remote enter on trial boot leaves the display" no "$(called s6-svc)"
rm -f "$PENDING_FILE"

rm -rf "$RUN_DIR" "$DATA_DIR" "$T/calls"; mkdir -p "$RUN_DIR" "$DATA_DIR"
for _ in 1 2 3 4 5; do boot; done
"$SAFE_CMD" exit >/dev/null
check "remote exit: lifts boot-loop safe mode" no "$(exists "$RUN_DIR/safe-mode")"
check "remote exit: resets the counter" 0 "$(cat "$DATA_DIR/short_boots")"
check "remote exit: display started" yes "$(called 's6-svc -u /run/service/shareframe-display')"
"$SAFE_CMD" enter >/dev/null
"$SAFE_CMD" exit >/dev/null
check "remote exit: marker removed" no "$(exists "$DATA_DIR/safe-mode-remote")"
clean_boot
check "remote exit: no safe mode after reboot" no "$(exists "$RUN_DIR/safe-mode")"

rm -rf "$RUN_DIR" "$DATA_DIR" "$T/calls"; mkdir -p "$RUN_DIR" "$DATA_DIR"
echo 3 > "$DATA_DIR/short_boots"
printf '1000\n' > "$RUN_DIR/display-crashes"
check "exit without safe mode says so" "not in safe mode" "$("$SAFE_CMD" exit)"
check "exit without safe mode keeps the boot counter" 3 "$(cat "$DATA_DIR/short_boots")"
check "exit without safe mode keeps the crash log" yes "$(exists "$RUN_DIR/display-crashes")"
check "exit without safe mode touches nothing" no "$([ -f "$T/calls" ] && echo yes || echo no)"

"$SAFE_CMD" enter >/dev/null
rm -f "$T/calls"
check "second enter says so" "already in safe mode" "$("$SAFE_CMD" enter)"
check "second enter touches nothing" no "$([ -f "$T/calls" ] && echo yes || echo no)"

rm -rf "$RUN_DIR" "$DATA_DIR"; mkdir -p "$RUN_DIR" "$DATA_DIR"
echo display-crash > "$RUN_DIR/safe-mode"
"$SAFE_CMD" enter >/dev/null
check "enter over automatic safe mode turns it remote" remote "$(cat "$RUN_DIR/safe-mode")"
check "enter over automatic safe mode persists it" yes "$(exists "$DATA_DIR/safe-mode-remote")"

crash() { echo "$1.42 100.0" > "$UPTIME"; "$S6/display-crash-guard"; }

rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
printf '10\n20\n' > "$RUN_DIR/display-crashes"
for t in 1000 1010 1020 1030; do crash "$t"; done
check "old crashes leave the window" 4 "$(wc -l < "$RUN_DIR/display-crashes" | tr -d ' ')"
check "4 crashes: no safe mode" no "$(exists "$RUN_DIR/safe-mode")"
crash 1040
check "5th crash: safe mode" display-crash "$(cat "$RUN_DIR/safe-mode" 2>/dev/null)"
check "5th crash: panel clear requested" yes "$(exists "$RUN_DIR/safe-mode-clear")"

mkdir -p "$T/led"
echo 1 > "$T/led/max_brightness"
echo "none [timer]" > "$T/led/trigger"
led() { LED="$T/led" SAFE_MODE="$RUN_DIR/safe-mode" "$LED_CMD" "$1"; cat "$T/led/delay_on" 2>/dev/null; }
check "safe mode: protected applies" 1000 "$(led protected)"
check "safe mode: normal ignored" 1000 "$(led normal)"
check "safe mode: off applies" 0 "$(led off >/dev/null; cat "$T/led/brightness")"
rm -f "$RUN_DIR/safe-mode"
check "no safe mode: normal applies" 200 "$(led normal)"

exit $fail
