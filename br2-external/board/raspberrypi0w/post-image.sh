#!/bin/bash
# Build boot FAT (firmware + A/B kernel sets) and assemble sdcard.img.
set -euo pipefail

BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"
GENIMAGE_CFG="${BOARD_DIR}/genimage.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"
MODE="${SHAREFRAME_BUILD_MODE:-prod}"

MKFS_VFAT="${HOST_DIR}/sbin/mkfs.vfat"
[ -x "${MKFS_VFAT}" ] || MKFS_VFAT="$(command -v mkfs.vfat)"
MCOPY="${HOST_DIR}/bin/mcopy"
[ -x "${MCOPY}" ] || MCOPY="$(command -v mcopy)"

FW_DIR="${BINARIES_DIR}/rpi-firmware"
for f in bootcode.bin start.elf fixup.dat; do
	[ -f "${FW_DIR}/${f}" ] || { echo "post-image: ${FW_DIR}/${f} missing" >&2; exit 1; }
done
for f in zImage bcm2835-rpi-zero-w.dtb spi0-spidev.dtbo initramfs.cpio.gz; do
	[ -f "${BINARIES_DIR}/${f}" ] || { echo "post-image: ${BINARIES_DIR}/${f} missing" >&2; exit 1; }
done

render_config() {
	sed "s|@OS_PREFIX@|$1|" "${BOARD_DIR}/config.txt"
	[ "${MODE}" = dev ] && echo "uart_2ndstage=1" || true
}

stage_slot_dir() { # <slot A|B> <dir>
	local slot="$1" dir="$2"
	mkdir -p "${dir}/overlays"
	# os_prefix requires overlays/README to exist in each slot subdir
	echo "per-slot overlays (os_prefix marker)" > "${dir}/overlays/README"
	sed "s/@SLOT@/${slot}/" "${BOARD_DIR}/cmdline.txt" > "${dir}/cmdline.txt"
	cp "${BINARIES_DIR}/zImage"                 "${dir}/zImage"
	cp "${BINARIES_DIR}/bcm2835-rpi-zero-w.dtb" "${dir}/bcm2835-rpi-zero-w.dtb"
	cp "${BINARIES_DIR}/spi0-spidev.dtbo"       "${dir}/overlays/spi0-spidev.dtbo"
	cp "${BINARIES_DIR}/initramfs.cpio.gz"      "${dir}/initramfs.cpio.gz"
}

TREE="${BINARIES_DIR}/boot-tree"
rm -rf "${TREE}"
mkdir -p "${TREE}"
cp "${FW_DIR}/bootcode.bin" "${FW_DIR}/start.elf" "${FW_DIR}/fixup.dat" "${TREE}/"
render_config "A/" > "${TREE}/config.txt"
render_config "B/" > "${TREE}/tryboot.txt"
stage_slot_dir A "${TREE}/A"
stage_slot_dir B "${TREE}/B"

# slot-neutral boot.tar tree for make-release (hook seds @SLOT@)
SLOT_TREE="${BINARIES_DIR}/bootslot-tree"
rm -rf "${SLOT_TREE}"
mkdir -p "${SLOT_TREE}"
cp "${BOARD_DIR}/cmdline.txt" "${SLOT_TREE}/cmdline.txt"
cp "${BINARIES_DIR}/zImage"                 "${SLOT_TREE}/zImage"
cp "${BINARIES_DIR}/bcm2835-rpi-zero-w.dtb" "${SLOT_TREE}/bcm2835-rpi-zero-w.dtb"
mkdir -p "${SLOT_TREE}/overlays"
echo "per-slot overlays (os_prefix marker)" > "${SLOT_TREE}/overlays/README"
cp "${BINARIES_DIR}/spi0-spidev.dtbo"       "${SLOT_TREE}/overlays/spi0-spidev.dtbo"
cp "${BINARIES_DIR}/initramfs.cpio.gz"      "${SLOT_TREE}/initramfs.cpio.gz"

# FAT16 at 64MiB — proven geometry; FAT32 -s 1 hung bootcode on this SoC.
rm -f "${BINARIES_DIR}/boot.vfat"
"${MKFS_VFAT}" -C -n BOOT "${BINARIES_DIR}/boot.vfat" 65536 >/dev/null
"${MCOPY}" -i "${BINARIES_DIR}/boot.vfat" -spQ "${TREE}"/* ::/
echo "post-image: boot.vfat built (mode=${MODE})"

# Factory store (p5): durable per-device defaults; provision-device.sh injects
# secrets later. Ships the baked root hash so every card has a durable pw.
FACTORY_TREE="${BINARIES_DIR}/factory-tree"
rm -rf "${FACTORY_TREE}"
mkdir -p "${FACTORY_TREE}"
awk -F: '$1=="root"{print $2}' "${TARGET_DIR}/etc/shadow" > "${FACTORY_TREE}/rootpw"
[ -s "${FACTORY_TREE}/rootpw" ] || { echo "post-image: no root hash in shadow" >&2; exit 1; }
rm -f "${BINARIES_DIR}/factory.vfat"
"${MKFS_VFAT}" -C -n FACTORY "${BINARIES_DIR}/factory.vfat" 32768 >/dev/null
"${MCOPY}" -i "${BINARIES_DIR}/factory.vfat" -spQ "${FACTORY_TREE}"/* ::/
echo "post-image: factory.vfat built"

ROOTPATH_TMP="$(mktemp -d)"
trap 'rm -rf "${ROOTPATH_TMP}"' EXIT
rm -rf "${GENIMAGE_TMP}"

genimage \
	--rootpath "${ROOTPATH_TMP}"   \
	--tmppath "${GENIMAGE_TMP}"    \
	--inputpath "${BINARIES_DIR}"  \
	--outputpath "${BINARIES_DIR}" \
	--config "${GENIMAGE_CFG}"
