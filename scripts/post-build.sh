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
    "${DTC}" -@ -I dts -O dtb -o "${BINARIES_DIR}/spi0-spidev.dtbo" "${OVERLAY_SRC}"
    echo "=== Post-build: spi0-spidev.dtbo compiled into ${BINARIES_DIR} ==="
fi

# ramoops goes into the per-slot base DTB, not config.txt: updates never rewrite config.txt.
RAMOOPS_SRC="${SCRIPT_DIR}/../br2-external/board/raspberrypi0w/ramoops.dts"
BASE_DTB="${BINARIES_DIR}/bcm2835-rpi-zero-w.dtb"
"${DTC}" -@ -I dts -O dtb -o "${BUILD_DIR}/ramoops.dtbo" "${RAMOOPS_SRC}"
"${HOST_DIR}/bin/fdtoverlay" -i "${BASE_DTB}" -o "${BASE_DTB}.tmp" "${BUILD_DIR}/ramoops.dtbo"
mv "${BASE_DTB}.tmp" "${BASE_DTB}"
echo "=== Post-build: ramoops merged into ${BASE_DTB} ==="

# Buildroot never cleans output/target; the kernel ships in boot.tar, not /boot.
rm -rf "${TARGET_DIR}/boot"

# Per-commit LOCALVERSION leaves one modules dir per old build; keep the live one.
KREL="$(cat "${BUILD_DIR}"/linux-[0-9]*/include/config/kernel.release 2>/dev/null || true)"
if [ -z "${KREL}" ] || [ ! -d "${TARGET_DIR}/lib/modules/${KREL}" ]; then
    echo "post-build: kernel modules for '${KREL}' not found in target" >&2
    exit 1
fi
for d in "${TARGET_DIR}"/lib/modules/*; do
    [ "$(basename "$d")" = "${KREL}" ] || rm -rf "$d"
done
echo "=== Post-build: kept /lib/modules/${KREL} only ==="
