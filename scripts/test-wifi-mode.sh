#!/usr/bin/env bash
# Host tests for the Wi-Fi mode manager: station, hotspot fallback and the way back,
# against stubbed radio tools and the real LED arbiter.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANAGER="$ROOT/br2-external/overlay/usr/libexec/s6/wifi-mode-manager"
T="$(mktemp -d)"
pid=
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$T"' EXIT

mkdir -p "$T/bin" "$T/ctl" "$T/run" "$T/led"
for cmd in shareframe-event s6-svc; do
	printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$cmd" "$T" > "$T/bin/$cmd"
done
# The radio as the control files describe it.
cat > "$T/bin/wpa_cli" <<EOF
#!/bin/sh
[ -f "$T/ctl/assoc" ] && printf 'wpa_state=COMPLETED\nssid=home\n' || printf 'wpa_state=SCANNING\n'
EOF
cat > "$T/bin/ip" <<EOF
#!/bin/sh
[ -f "$T/ctl/address" ] && echo '    inet 192.168.1.5/24 scope global wlan0'
exit 0
EOF
printf '#!/bin/sh\n[ -f "%s/ctl/internet" ]\n' "$T" > "$T/bin/ping"
cat > "$T/bin/shareframe-ap" <<EOF
#!/bin/sh
echo "shareframe-ap \$*" >> "$T/calls"
[ "\$1" = status ] && echo "up stations=0"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/wifi-stack-restart"
# Every wait of the manager shrinks to a moment.
printf '#!/bin/sh\nexec /usr/bin/sleep 0.03\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*

export PATH="$T/bin:$ROOT/br2-external/overlay/usr/bin:$PATH"
export STATE_DIR="$T/run" SVC="$T/service" CONSOLE=/dev/null STACK_RESTART="$T/bin/wifi-stack-restart"
export AP_CONF="$T/ap.conf" WPA_CONF="$T/wpa_supplicant.conf"
export ASSOC_TIMEOUT=4 DHCP_GRACE=4 AP_RETRY_EVERY=1000000
export LED="$T/led" SAFE_MODE="$T/run/safe-mode" LED_RUN="$T/run/led"
echo 1 > "$T/led/max_brightness"
echo "none [timer]" > "$T/led/trigger"
printf "AP_SSID='frame-ap'\nAP_PASS='hotspot123'\n" > "$AP_CONF"
printf 'network={\n\tssid="home"\n}\n' > "$WPA_CONF"

fail=0
check() { # <desc> <expected> <actual>
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi
}
called() { grep -qs "^$1" "$T/calls" && echo yes || echo no; }
exists() { [ -e "$1" ] && echo yes || echo no; }
mode() { cat "$T/run/wifi-mode" 2>/dev/null || true; }
json() { sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p" "$T/run/wifi-mode.json" 2>/dev/null; }
led() {
	case "$(cat "$T/led/trigger")/$(cat "$T/led/delay_on" 2>/dev/null)/$(cat "$T/led/delay_off" 2>/dev/null)" in
		timer/200/9800) echo normal ;;
		timer/200/200) echo wifi-connecting ;;
		timer/500/2000) echo wifi-down ;;
		timer/800/800) echo ap-mode ;;
		*) echo other ;;
	esac
}
# Waits until a command prints the expected value, then prints what it last saw.
settle() { # <expected> <command...>
	want=$1; shift
	for _ in $(seq 100); do [ "$("$@")" = "$want" ] && break; sleep 0.1; done
	"$@"
}

touch "$T/ctl/assoc" "$T/ctl/address" "$T/ctl/internet"
"$MANAGER" &
pid=$!

check "known network in reach: connected" connected "$(settle connected mode)"
check "connected: ssid published" home "$(json ssid)"
check "connected: internet published" true "$(settle true json internet)"
check "connected: LED normal" normal "$(settle normal led)"
check "connected: station services asked up" yes "$(called "s6-svc -u $T/service/wpa_supplicant")"
check "connected: event logged" yes "$(called 'shareframe-event wifi connected')"

shareframe-led wifi-connecting
check "LED repainted by a stack restart: the manager sets it right again" normal "$(settle normal led)"

rm -f "$T/ctl/internet"
check "no internet: LED says so" wifi-down "$(settle wifi-down led)"
check "no internet: published" false "$(settle false json internet)"
check "no internet: stays a station, no hotspot" connected "$(mode)"

rm -f "$T/calls" "$T/ctl/assoc" "$T/ctl/address"
check "network gone: hotspot" ap "$(settle ap mode)"
check "hotspot: brought up" yes "$(called 'shareframe-ap up')"
check "hotspot: station services pinned down" yes "$(called "s6-svc -d $T/service/wpa_supplicant")"
check "hotspot: self-healing told to stand back" yes "$(exists "$T/run/wifi-switching")"
check "hotspot: credentials published" frame-ap "$(json ap_ssid)"
check "hotspot: failed attempt published" yes "$([ "$(json last_failed_at)" -gt 0 ] && echo yes || echo no)"
check "hotspot: LED" ap-mode "$(settle ap-mode led)"
check "hotspot: event logged" yes "$(called 'shareframe-event wifi ap fallback')"

rm -f "$T/calls"
touch "$T/ctl/assoc" "$T/ctl/address" "$T/ctl/internet" "$T/run/wifi-retry-requested"
check "retry asked from the dashboard: connected again" connected "$(settle connected mode)"
check "retry: hotspot taken down" yes "$(called 'shareframe-ap down')"
check "retry: self-healing allowed again" no "$(exists "$T/run/wifi-switching")"
check "retry: request consumed" no "$(exists "$T/run/wifi-retry-requested")"
check "retry: failed attempt forgotten" 0 "$(settle 0 json last_failed_at)"
check "retry: LED normal" normal "$(settle normal led)"

exit $fail
