#!/bin/bash
# Post-build: Build-Metadaten ins Rootfs schreiben
set -e

TARGET_DIR="$1"   # von Buildroot gesetzt: Pfad zum Staging-Rootfs

echo "=== Post-build: Build-Stempel erzeugen ==="

{
    echo "built_at=$(date --iso-8601=seconds)"
    echo "built_by=$(whoami)@$(hostname)"
    echo "git_commit=${BUILD_SHA:-unknown}"
} > "$TARGET_DIR/etc/build-info"

echo "=== Post-build: /etc/build-info geschrieben ==="

if [ -n "$BUILD_SHA" ]; then
    {
        echo "BUILD_ID=$BUILD_SHA"
    } >> "$TARGET_DIR/etc/os-release"
    echo "=== Post-build: BUILD_ID in /etc/os-release ergaenzt ==="
fi

# Fake-hwclock seed: virgin SDs without /data/fake-hwclock start at build time
# instead of the 1970 epoch (TLS, log timestamps).
date +%s > "$TARGET_DIR/etc/fake-hwclock-default"
echo "=== Post-build: /etc/fake-hwclock-default mit Build-Epoch geschrieben ==="

# SHAREFRAME_MODE: dev | prod. Consumed by mode-aware longruns (Phase 6
# udhcpd-usb0 only runs in prod). Pure runtime signal; does not alter boot path.
MODE="${SHAREFRAME_MODE:-prod}"
echo "${MODE}" > "$TARGET_DIR/etc/shareframe-mode"
echo "=== Post-build: /etc/shareframe-mode=${MODE} ==="

# SHAREFRAME_PROFILE: dev | prod | prod.local. The 60-app s6 run scripts read
# this file and export it as SHAREFRAME_PROFILE, selecting the
# /etc/shareframe/config.<profile>.toml overlay the app merges on config.toml.
PROFILE="${SHAREFRAME_PROFILE:-prod}"
echo "${PROFILE}" > "$TARGET_DIR/etc/shareframe-profile"
echo "=== Post-build: /etc/shareframe-profile=${PROFILE} ==="
