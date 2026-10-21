#!/usr/bin/env bash
# Host tests for display safe mode: boot-guard, display-crash-guard, LED priority.
set -euo pipefail

S6="$(cd "$(dirname "$0")/.." && pwd)/br2-external/overlay/usr/libexec/s6"
LED_CMD="$(cd "$(dirname "$0")/.." && pwd)/br2-external/overlay/usr/bin/shareframe-led"
T="$(mktemp -d)"
# boot-guard backgrounds a STABLE-long sleep; a unique length lets the trap reap it.
NAP=86399
trap 'pkill -x -f "sleep $NAP" || true; rm -rf "$T"' EXIT

mkdir -p "$T/bin"
for cmd in shareframe-event shareframe-led; do
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
