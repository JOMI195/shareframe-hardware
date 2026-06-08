#!/bin/bash
# Post-build: Build-Metadaten ins Rootfs schreiben
set -e

TARGET_DIR="$1"   # von Buildroot gesetzt: Pfad zum Staging-Rootfs

echo "=== Post-build: Build-Stempel erzeugen ==="

{
    echo "built_at=$(date --iso-8601=seconds)"
    echo "built_by=$(whoami)@$(hostname)"
    echo "git_commit=${BUILD_SHA:-unknown}"
    # config_label: aus configs/<kunde>/config.env (SHAREFRAME_CONFIG_LABEL),
    # leer beim arglosen Build. Zeigt am Image, mit welcher Config gebaut wurde.
    echo "config_label=${SHAREFRAME_CONFIG_LABEL:-}"
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

# Compile the SPI DT overlay into /boot so it ships inside the squashfs slot.
# RAUC post-install.sh then syncs it to FAT /boot/<slot>/ on every update,
# exactly like zImage + bcm2835-rpi-zero-w.dtb -> per-slot, rollback-safe.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERLAY_SRC="${SCRIPT_DIR}/../board/raspberrypi0w/overlays/spi0-spidev.dts"
DTC="${HOST_DIR}/bin/dtc"
if [ -x "${DTC}" ] && [ -f "${OVERLAY_SRC}" ]; then
    mkdir -p "${TARGET_DIR}/boot"
    "${DTC}" -@ -I dts -O dtb -o "${TARGET_DIR}/boot/spi0-spidev.dtbo" "${OVERLAY_SRC}"
    # Also into BINARIES_DIR so post-image.sh stages it into FAT boot/A,B for
    # the initial flash (RAUC takes over per-slot thereafter).
    [ -n "${BINARIES_DIR:-}" ] && cp "${TARGET_DIR}/boot/spi0-spidev.dtbo" "${BINARIES_DIR}/spi0-spidev.dtbo"
    echo "=== Post-build: spi0-spidev.dtbo compiled into /boot ==="
fi
