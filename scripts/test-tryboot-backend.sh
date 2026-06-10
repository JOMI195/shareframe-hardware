#!/usr/bin/env bash
# Host tests for the RAUC tryboot backend (fixture dirs, no real mounts).
set -euo pipefail

BACKEND="$(cd "$(dirname "$0")/.." && pwd)/package/shareframe-rauc/files/tryboot-backend"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

export NO_MOUNT=1
export FW_MNT="$T/fw" STATE_DIR="$T/rauc" CMDLINE="$T/cmdline" TRYBOOT_FLAG="$T/tryboot"
mkdir -p "$FW_MNT" "$STATE_DIR"

fresh() { # <committed-slot> <booted-slot>
	local committed="$1" other
	other=$([ "$committed" = A ] && echo B || echo A)
	printf 'enable_uart=1\nos_prefix=%s/\nkernel=zImage\n' "$committed" > "$FW_MNT/config.txt"
	printf 'enable_uart=1\nos_prefix=%s/\nkernel=zImage\n' "$other"     > "$FW_MNT/tryboot.txt"
	printf 'console=ttyS1,115200 rauc.slot=%s panic=10\n' "$2" > "$CMDLINE"
	rm -f "$STATE_DIR/pending" "$STATE_DIR"/state.* "$TRYBOOT_FLAG"
}

fail=0
check() { # <desc> <expected> <actual>
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi
}

# committed A, booted A: get-primary
fresh A A
check "get-primary committed A" "A" "$("$BACKEND" get-primary)"

# default state is good
check "get-state default good" "good" "$("$BACKEND" get-state B)"

# install flow: set-primary B stages pending + tryboot flag, no config change
fresh A A
"$BACKEND" set-primary B
check "set-primary stages pending" "B" "$(cat "$STATE_DIR/pending")"
check "set-primary sets tryboot flag" "yes" "$( [ -f "$TRYBOOT_FLAG" ] && echo yes || echo no )"
check "set-primary keeps committed A" "A" "$("$BACKEND" get-primary)"

# tryboot boot into B + mark-good: commit swaps os_prefix, clears pending
printf 'console=ttyS1,115200 rauc.slot=B panic=10\n' > "$CMDLINE"
"$BACKEND" set-state B good
check "commit swaps primary to B" "B" "$("$BACKEND" get-primary)"
check "commit clears pending" "no" "$( [ -f "$STATE_DIR/pending" ] && echo yes || echo no )"
check "commit clears tryboot flag" "no" "$( [ -f "$TRYBOOT_FLAG" ] && echo yes || echo no )"
check "tryboot.txt now points at A" "A/" "$(sed -n 's/^os_prefix=//p' "$FW_MNT/tryboot.txt")"
check "commit keeps other config keys" "enable_uart=1" "$(head -1 "$FW_MNT/config.txt")"

# rollback flow: staged B never boots; reconcile marks bad from A
fresh A A
"$BACKEND" set-primary B
"$BACKEND" set-state B bad
check "mark-bad keeps committed A" "A" "$("$BACKEND" get-primary)"
check "mark-bad clears pending" "no" "$( [ -f "$STATE_DIR/pending" ] && echo yes || echo no )"
check "mark-bad records state" "bad" "$("$BACKEND" get-state B)"

# good on already-committed slot: state only, no config rewrite
fresh A A
before=$(cat "$FW_MNT/config.txt")
"$BACKEND" set-state A good
check "good on committed slot keeps config" "$before" "$(cat "$FW_MNT/config.txt")"

# set-primary to already-committed slot clears stale pending
fresh A A
echo B > "$STATE_DIR/pending"; : > "$TRYBOOT_FLAG"
"$BACKEND" set-primary A
check "set-primary committed clears pending" "no" "$( [ -f "$STATE_DIR/pending" ] && echo yes || echo no )"

exit $fail
