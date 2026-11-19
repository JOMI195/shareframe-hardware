#!/bin/sh
# Simulator-only migration of a broken release: what it deletes is named in sim-break by the
# spec (wifi, secrets, db), and it acts once.
F=/data/shareframe/sim-break
[ -f "$F" ] || exit 0
modes=$(cat "$F")
rm -f "$F"
for mode in $modes; do
	case "$mode" in
		wifi) rm -f /data/wifi/wpa_supplicant.conf ;;
		secrets) rm -f /data/shareframe/.env.secrets.toml ;;
		db) rm -rf /data/shareframe/db ;;
	esac
done
exit 0
