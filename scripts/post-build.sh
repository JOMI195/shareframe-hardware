#!/bin/bash
# Post-build: write build metadata into the rootfs
set -e

TARGET_DIR="$1"   # set by Buildroot: staging rootfs path

echo "=== Post-build: write build stamp ==="

{
    echo "built_at=$(date --iso-8601=seconds)"
    echo "built_by=$(whoami)@$(hostname)"
    echo "git_commit=${OS_SHA:-unknown}"
    # config_label: from the config dir's config.env; empty for an argless build.
    echo "config_label=${SHAREFRAME_CONFIG_LABEL:-}"
} > "$TARGET_DIR/etc/build-info"

echo "=== Post-build: wrote /etc/build-info ==="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Single version source for the app, RAUC manifest and server compare; the
# explicit version wins, else the git sha.
VERSION="${SHAREFRAME_VERSION:-${OS_SHA:-unknown}}"
{
    echo "VERSION=${VERSION}"
    echo "OS_SHA=${OS_SHA:-unknown}"
    echo "APP_SHA=${APP_SHA:-unknown}"
    echo "BUILD_DATE=$(date --iso-8601=seconds)"
} > "$TARGET_DIR/etc/shareframe-release"
echo "=== Post-build: /etc/shareframe-release VERSION=${VERSION} ==="

mkdir -p "$TARGET_DIR/etc/shareframe"
printf 'version = "%s"\n' "${VERSION}" > "$TARGET_DIR/etc/shareframe/VERSION.toml"
echo "=== Post-build: /etc/shareframe/VERSION.toml ==="

# /etc/os-release is a symlink into /usr/lib; edit the real file. Replace-then-
# append so a re-run can't stack duplicate BUILD_ID lines.
OSREL="$TARGET_DIR/usr/lib/os-release"
if [ -n "$OS_SHA" ] && [ -f "$OSREL" ]; then
    sed -i -e "s/^VERSION=.*/VERSION=\"${OS_SHA}\"/" \
           -e "s/^VERSION_ID=.*/VERSION_ID=\"${OS_SHA}\"/" \
           -e "/^BUILD_ID=/d" "$OSREL"
    echo "BUILD_ID=${OS_SHA}" >> "$OSREL"
    echo "=== Post-build: os-release VERSION_ID/BUILD_ID=${OS_SHA} ==="
fi

# Fake-hwclock seed: virgin SDs start at build time, not the 1970 epoch.
date +%s > "$TARGET_DIR/etc/fake-hwclock-default"
echo "=== Post-build: wrote /etc/fake-hwclock-default ==="

# Build flavor; only post-image.sh acts on it (verbose UART in dev).
MODE="${SHAREFRAME_BUILD_MODE:-prod}"
echo "${MODE}" > "$TARGET_DIR/etc/shareframe-build-mode"
echo "=== Post-build: /etc/shareframe-build-mode=${MODE} ==="

# Config profile; the app reads it and merges the matching config overlay.
PROFILE="${SHAREFRAME_PROFILE:-prod}"
echo "${PROFILE}" > "$TARGET_DIR/etc/shareframe-profile"
echo "=== Post-build: /etc/shareframe-profile=${PROFILE} ==="

# Compile the SPI DT overlay shipped in each boot slot.
OVERLAY_SRC="${SCRIPT_DIR}/../br2-external/board/raspberrypi0w/overlays/spi0-spidev.dts"
DTC="${HOST_DIR}/bin/dtc"
if [ -x "${DTC}" ] && [ -f "${OVERLAY_SRC}" ]; then
    mkdir -p "${TARGET_DIR}/boot"
    "${DTC}" -@ -I dts -O dtb -o "${TARGET_DIR}/boot/spi0-spidev.dtbo" "${OVERLAY_SRC}"
    # Also stage into BINARIES_DIR for the initial flash (post-image.sh).
    [ -n "${BINARIES_DIR:-}" ] && cp "${TARGET_DIR}/boot/spi0-spidev.dtbo" "${BINARIES_DIR}/spi0-spidev.dtbo"
    echo "=== Post-build: spi0-spidev.dtbo compiled into /boot ==="
fi
