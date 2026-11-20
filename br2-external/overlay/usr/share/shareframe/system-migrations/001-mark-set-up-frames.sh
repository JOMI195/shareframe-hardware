#!/bin/sh
# A frame that got this release over the air had a Wi-Fi and was owned before: mark both, so its
# setup and registration screens keep their 10-minute window. A freshly flashed card has no update
# state, so it shows them until it joins a Wi-Fi and until it is claimed.
set -u
DATA_DIR="${DATA_DIR:-/data/shareframe}"

[ -f "$DATA_DIR/update-verify/state" ] || exit 0
for flag in wifi-joined registered-once; do
	[ -e "$DATA_DIR/$flag" ] || echo migrated > "$DATA_DIR/$flag"
done
exit 0
