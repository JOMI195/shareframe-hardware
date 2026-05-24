#!/bin/sh
# RAUC post-install handler. Copies kernel + DTB out of the freshly-written
# squashfs slot to /boot/<slot>/ on the FAT partition so U-Boot can fatload
# them without having to read squashfs in U-Boot.
#
# Env vars supplied by RAUC:
#   RAUC_TARGET_SLOTS = list of installed slot ids (e.g. "rootfs.1")
#   RAUC_SLOT_BOOTNAME_<id> = A | B
#   RAUC_SLOT_DEVICE_<id> = /dev/mmcblk0pN
set -eu

log() { echo "[rauc post-install] $*"; }

# /boot must be mounted (mount-boot oneshot handles this at boot; here we
# may need to mount it ourselves if rauc is invoked early).
if ! mountpoint -q /boot; then
	mount -t vfat /dev/mmcblk0p1 /boot
	BOOT_MOUNTED_HERE=1
else
	BOOT_MOUNTED_HERE=0
fi

for slot in ${RAUC_TARGET_SLOTS}; do
	eval bn="\${RAUC_SLOT_BOOTNAME_${slot}:-}"
	eval dev="\${RAUC_SLOT_DEVICE_${slot}:-}"
	[ -n "${bn}" ] || { log "no BOOTNAME for ${slot}; skipping"; continue; }
	[ -n "${dev}" ] || { log "no DEVICE for ${slot}; skipping"; continue; }

	log "syncing kernel+dtb from ${dev} -> /boot/${bn}/"
	tmp=$(mktemp -d)
	mount -t squashfs -o ro "${dev}" "${tmp}"

	mkdir -p "/boot/${bn}"
	# Atomic-ish: write to .new then rename.
	for f in zImage bcm2835-rpi-zero-w.dtb; do
		if [ -f "${tmp}/boot/${f}" ]; then
			cp "${tmp}/boot/${f}" "/boot/${bn}/${f}.new"
			mv "/boot/${bn}/${f}.new" "/boot/${bn}/${f}"
		else
			log "WARN ${tmp}/boot/${f} missing in slot squashfs"
		fi
	done

	# DTBs subdir if Buildroot's LINUX_INSTALL_TARGET put them there.
	if [ -d "${tmp}/boot/dtbs" ]; then
		find "${tmp}/boot/dtbs" -name '*.dtb' -exec cp {} "/boot/${bn}/" \;
	fi

	umount "${tmp}"
	rmdir "${tmp}"
done

sync
[ "${BOOT_MOUNTED_HERE}" = 1 ] && umount /boot
log "done"
