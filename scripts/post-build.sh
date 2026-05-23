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
