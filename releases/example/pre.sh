# install-check hook — runs in the OLD system BEFORE any slot is written.
# Embedded verbatim into the signed bundle's hook.sh. A non-zero exit ABORTS
# the install. Keep it idempotent and quick. Remove this file if unused.
echo "[release example pre.sh] old system, version $(sed -n 's/^VERSION=//p' /etc/shareframe-release 2>/dev/null)"
