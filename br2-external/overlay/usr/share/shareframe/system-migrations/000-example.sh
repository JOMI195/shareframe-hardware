#!/bin/sh
# Example migration: proves the runner works. Idempotent by construction.
echo "[migration 000-example] running in new system (version $(sed -n 's/^VERSION=//p' /etc/shareframe-release 2>/dev/null), data mounted: $(mountpoint -q /data && echo yes || echo no))"
exit 0
