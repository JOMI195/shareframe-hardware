#!/bin/sh
# Simulator-only migration of a broken release: what it deletes is named in sim-break by the
# spec, and it acts once.
F=/data/shareframe/sim-break
[ -f "$F" ] || exit 0
mode=$(cat "$F")
rm -f "$F"
case "$mode" in
	wifi) rm -f /data/wifi/wpa_supplicant.conf ;;
	secrets) rm -f /data/shareframe/.env.secrets.toml ;;
esac
exit 0
