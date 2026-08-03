# install-check hook — runs in the OLD system BEFORE any slot is written.
# Embedded verbatim into the signed bundle's hook.sh. A non-zero exit ABORTS
# the install. Keep it idempotent and quick. Remove this file if unused.
echo "[release example pre.sh] old system, version $(sed -n 's/^VERSION=//p' /etc/shareframe-release 2>/dev/null)"

# Example: device-targeted key rotation, live half (pair with post.sh below).
# CAUTION: the bundle is signed but NOT encrypted — key material rides readable
# inside it. Only assign such a release to the one target device on the server.
#cat > /data/shareframe/.env.secrets.toml <<'SECRETS'
#ed25519_private_key = "NEW_KEY_BASE64"
#dashboard_initial_password = "NEW_PASSWORD"
#SECRETS
#chmod 0600 /data/shareframe/.env.secrets.toml
