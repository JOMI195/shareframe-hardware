#!/bin/bash
# BR2_ROOTFS_POST_IMAGE_SCRIPT: assemble sdcard.img with
#   - boot FAT (firmware, u-boot, boot.scr, uboot.env + redundant copy,
#     initramfs.cpio.gz, /boot/A/{zImage,dtb}, /boot/B/{zImage,dtb})
#   - rootfs slots A + B (both initially the same squashfs)
#   - /data ext4
#
# Buildroot invokes this after rootfs build with BINARIES_DIR + BUILD_DIR set.

set -euo pipefail

BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${BOARD_DIR}/../.." && pwd)"
GENIMAGE_CFG_IN="${BOARD_DIR}/genimage.cfg.in"
GENIMAGE_CFG="${BINARIES_DIR}/genimage.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

HOST_BIN="${PROJECT_ROOT}/buildroot/src/output/host/bin"

# 1. Compile boot.cmd -> boot.scr (U-Boot script) using the in-tree mkimage.
MKIMAGE="$(ls "${BUILD_DIR}"/uboot-*/tools/mkimage 2>/dev/null | head -1 || true)"
BOOT_CMD="${PROJECT_ROOT}/firmware-config/boot.cmd"
if [ -n "${MKIMAGE}" ] && [ -f "${BOOT_CMD}" ]; then
	"${MKIMAGE}" -A arm -O linux -T script -C none \
		-d "${BOOT_CMD}" "${BINARIES_DIR}/boot.scr"
else
	echo "post-image: WARN mkimage or boot.cmd missing; boot.scr not generated" >&2
fi

# 2. Compile uboot.env.txt -> uboot.env (+ redundant copy).
# SHAREFRAME_MODE=dev flips dev_netboot=1 (U-Boot TFTPs new artifacts into
# slot A then boots); =prod (default) keeps dev_netboot=0.
MKENVIMAGE="${HOST_BIN}/mkenvimage"
ENV_TXT="${PROJECT_ROOT}/firmware-config/uboot.env.txt"
MODE="${SHAREFRAME_MODE:-prod}"
case "${MODE}" in dev) DEV_NETBOOT=1 ;; *) DEV_NETBOOT=0 ;; esac
if [ -x "${MKENVIMAGE}" ] && [ -f "${ENV_TXT}" ]; then
	ENV_COMPILED="${BINARIES_DIR}/uboot.env.txt"
	sed "s/^dev_netboot=.*/dev_netboot=${DEV_NETBOOT}/" "${ENV_TXT}" > "${ENV_COMPILED}"
	# Non-redundant env: upstream U-Boot does not support
	# CONFIG_SYS_REDUNDAND_ENVIRONMENT with CONFIG_ENV_IS_IN_FAT, so don't
	# pass -r (the 5-byte header would CRC-fail when U-Boot reads it as
	# the 4-byte non-redundant layout).
	"${MKENVIMAGE}" -s 0x4000 -o "${BINARIES_DIR}/uboot.env"        "${ENV_COMPILED}"
	# mkenvimage drops 0640; tftpd (unprivileged) needs 0644 to serve.
	chmod 0644 "${BINARIES_DIR}/uboot.env"
	# uboot-redund.env retained as an empty stub on FAT only because the
	# previous layout wrote one; harmless and unread by current U-Boot.
	rm -f "${BINARIES_DIR}/uboot-redund.env"
	echo "post-image: uboot.env compiled with dev_netboot=${DEV_NETBOOT} (mode=${MODE})"
else
	echo "post-image: WARN mkenvimage or uboot.env.txt missing; uboot.env not generated" >&2
fi

# 3. Stage per-slot kernel + dtb under boot/A/ and boot/B/. Initial image
# flashes both slots with the same payload.
mkdir -p "${BINARIES_DIR}/boot/A" "${BINARIES_DIR}/boot/B"
for slot in A B; do
	[ -f "${BINARIES_DIR}/zImage" ]                  && cp "${BINARIES_DIR}/zImage"                  "${BINARIES_DIR}/boot/${slot}/zImage"
	[ -f "${BINARIES_DIR}/bcm2835-rpi-zero-w.dtb" ]  && cp "${BINARIES_DIR}/bcm2835-rpi-zero-w.dtb"  "${BINARIES_DIR}/boot/${slot}/bcm2835-rpi-zero-w.dtb"
done

# 4. Build the FAT contents list.
FILES=()
for f in bootcode.bin fixup.dat start.elf config.txt; do
	[ -f "${BINARIES_DIR}/rpi-firmware/${f}" ] && FILES+=( "rpi-firmware/${f}" )
done
[ -f "${BINARIES_DIR}/bcm2835-rpi-zero-w.dtb" ] && FILES+=( "bcm2835-rpi-zero-w.dtb" )
[ -f "${BINARIES_DIR}/u-boot.bin" ]             && FILES+=( "u-boot.bin" )
[ -f "${BINARIES_DIR}/boot.scr" ]               && FILES+=( "boot.scr" )
[ -f "${BINARIES_DIR}/uboot.env" ]              && FILES+=( "uboot.env" )
[ -f "${BINARIES_DIR}/uboot-redund.env" ]       && FILES+=( "uboot-redund.env" )
[ -f "${BINARIES_DIR}/initramfs.cpio.gz" ]      && FILES+=( "initramfs.cpio.gz" )
# Whole boot/ directory: mcopy -sp on a directory preserves the structure
# (boot/A/zImage etc.). Listing individual files instead flattens to root.
[ -d "${BINARIES_DIR}/boot" ]                   && FILES+=( "boot" )

BOOT_FILES=$(printf '\t\t\t"%s",\n' "${FILES[@]}")
awk -v repl="${BOOT_FILES}" '{gsub(/#BOOT_FILES#/, repl); print}' \
	"${GENIMAGE_CFG_IN}" > "${GENIMAGE_CFG}"

# 5. Run genimage.
trap 'rm -rf "${ROOTPATH_TMP}"' EXIT
ROOTPATH_TMP="$(mktemp -d)"
rm -rf "${GENIMAGE_TMP}"

genimage \
	--rootpath "${ROOTPATH_TMP}"   \
	--tmppath "${GENIMAGE_TMP}"    \
	--inputpath "${BINARIES_DIR}"  \
	--outputpath "${BINARIES_DIR}" \
	--config "${GENIMAGE_CFG}"
