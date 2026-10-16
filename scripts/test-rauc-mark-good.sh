#!/usr/bin/env bash
# Host tests for the A/B commit gate (stubbed rauc/s6/reboot, fixture files).
set -euo pipefail

GATE="$(cd "$(dirname "$0")/.." && pwd)/br2-external/overlay/usr/libexec/s6/rauc-mark-good"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
for cmd in rauc shareframe-update-history shareframe-event reboot; do
	printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$cmd" "$T" > "$T/bin/$cmd"
done
printf '#!/bin/sh\necho true\n' > "$T/bin/s6-svstat"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/shareframe-update-verify"
chmod +x "$T/bin/"*

export PATH="$T/bin:$PATH" DEADLINE=1
export PENDING_FILE="$T/pending" HEALTH_JSON="$T/health.json" WIFI_JSON="$T/wifi-mode.json"
export BACKEND_OK="$T/backend-ok" CMDLINE="$T/cmdline"

fresh() { # <health overall> <internet true|false> <backend-ok yes|no>
	rm -f "$T/calls" "$BACKEND_OK"
	echo B > "$PENDING_FILE"
	printf 'console=ttyS1,115200 rauc.slot=B\n' > "$CMDLINE"
	printf '{"overall":"%s"}\n' "$1" > "$HEALTH_JSON"
	printf '{"mode":"connected","internet":%s}\n' "$2" > "$WIFI_JSON"
	[ "$3" = yes ] && : > "$BACKEND_OK"
	return 0
}

outcome() { # waits for the backgrounded gate to commit or reboot
	for _ in $(seq 100); do
		grep -q '^rauc status mark-good' "$T/calls" 2>/dev/null && { echo commit; return; }
		grep -q '^reboot' "$T/calls" 2>/dev/null && { echo reboot; return; }
		sleep 0.1
	done
	echo none
}

fail=0
check() { # <desc> <expected> <actual>
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi
}

fresh ok true yes
"$GATE" >/dev/null
check "healthy + backend reached commits" commit "$(outcome)"

fresh ok false no
"$GATE" >/dev/null
check "no internet skips the backend check" commit "$(outcome)"

fresh ok true no
"$GATE" >/dev/null
check "internet without backend contact reboots" reboot "$(outcome)"
check "timeout is logged as event" yes "$(grep -q '^shareframe-event update commit gate' "$T/calls" && echo yes || echo no)"

fresh critical false no
"$GATE" >/dev/null
check "critical health reboots" reboot "$(outcome)"

fresh ok true yes
echo A > "$PENDING_FILE"
"$GATE" >/dev/null
sleep 0.5
check "non-trial boot does nothing" none "$([ -f "$T/calls" ] && echo called || echo none)"

exit $fail
