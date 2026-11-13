#!/usr/bin/env bash
# Host tests for the status LED: which of several claims it shows.
set -euo pipefail

LED_CMD="$(cd "$(dirname "$0")/.." && pwd)/br2-external/overlay/usr/bin/shareframe-led"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

export LED="$T/led" SAFE_MODE="$T/run/safe-mode" LED_RUN="$T/run/led"

fail=0
check() { # <desc> <expected> <actual>
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi
}

# A kernel without the pattern trigger: every state is a trigger plus two delays.
reboot() {
	rm -rf "$T/led" "$T/run"
	mkdir -p "$T/led" "$T/run"
	echo 1 > "$T/led/max_brightness"
	echo "none [timer]" > "$T/led/trigger"
}

led() { "$LED_CMD" "$1" 2>/dev/null || true; }

shown() {
	case "$(cat "$T/led/trigger")" in
		heartbeat) echo booting ;;
		none) [ "$(cat "$T/led/brightness")" = 0 ] && echo off || echo error ;;
		timer)
			case "$(cat "$T/led/delay_on")/$(cat "$T/led/delay_off")" in
				200/9800) echo normal ;;
				200/200) echo wifi-connecting ;;
				500/2000) echo wifi-down ;;
				800/800) echo ap-mode ;;
				50/50) echo updating ;;
				1000/1000) echo protected ;;
				*) echo "unknown timer" ;;
			esac
			;;
		*) echo untouched ;;
	esac
}

reboot
led booting
check "boot: booting shows" booting "$(shown)"
led wifi-connecting
led normal
check "wifi codes replace each other" normal "$(shown)"

echo sentinel > "$T/led/delay_on"
led normal
check "an unchanged code is not written again" sentinel "$(cat "$T/led/delay_on")"

reboot
led normal
led error
check "error shows over a wifi code" error "$(shown)"
led wifi-connecting
led normal
check "error stays through later wifi changes" error "$(shown)"

reboot
led ap-mode
: > "$SAFE_MODE"
led protected
check "safe mode shows over a wifi code" protected "$(shown)"
led wifi-connecting
check "safe mode: a wifi change stays hidden" protected "$(shown)"
rm -f "$SAFE_MODE"
led refresh
check "safe mode lifted: the wifi code of that moment shows" wifi-connecting "$(shown)"

reboot
led normal
led error
: > "$SAFE_MODE"
led protected
check "safe mode shows over an error" protected "$(shown)"
led updating
check "an update shows over safe mode" updating "$(shown)"
led update-failed
check "failed update in safe mode: back to protected" protected "$(shown)"

reboot
led ap-mode
led updating
check "an update shows over a wifi code" updating "$(shown)"
led update-done
check "finished update: back to the wifi code" ap-mode "$(shown)"
led updating
led update-failed
check "failed update: error" error "$(shown)"

reboot
led normal
led error
led updating
led off
check "off shows over everything" off "$(shown)"
led normal
led refresh
check "off stays until the reboot" off "$(shown)"

reboot
led normal
set +e; "$LED_CMD" blinking 2>/dev/null; rc=$?; set -e
check "an unknown state is refused" 1 "$rc"
check "an unknown state leaves the LED alone" normal "$(shown)"

exit $fail
