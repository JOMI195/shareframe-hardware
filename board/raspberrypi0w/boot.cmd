# U-Boot boot script for shareframe-pi0w (Phase 4: dev_netboot + A/B + recovery).
#
# uboot.env supplies:
#   dev_netboot      0 = boot SD A/B, 1 = TFTP fresh artifacts into slot A first
#   BOOT_ORDER       "A B" or "B A"
#   BOOT_A_LEFT      attempts remaining for slot A (0..3)
#   BOOT_B_LEFT      attempts remaining for slot B (0..3)
#
# Slot layout (sdcard.img genimage):
#   /dev/mmcblk0p1 = boot FAT (firmware, u-boot, boot.scr, uboot.env, initramfs.cpio.gz, /boot/A/, /boot/B/)
#   /dev/mmcblk0p2 = rootfs slot A (squashfs)
#   /dev/mmcblk0p3 = rootfs slot B (squashfs)
#   /dev/mmcblk0p4 = /data (ext4)

# Recovery: both slots exhausted -> give A one more attempt.
if test ${BOOT_A_LEFT} -le 0 && test ${BOOT_B_LEFT} -le 0; then
    setenv BOOT_A_LEFT 1
    setenv BOOT_B_LEFT 0
    saveenv
    echo "Recovery: BOOT_A_LEFT forced to 1"
fi

# ============================================================================
# Dev-netboot: TFTP fresh artifacts, write into slot A + boot FAT, fall through.
# ============================================================================
if test "${dev_netboot}" = "1"; then
    setenv ipaddr   10.55.0.2
    setenv serverip 10.55.0.1
    setenv ethact   usb_ether
    setenv ethprime usb_ether
    setenv arpretries 20
    setenv arp_wait_ms 200
    setenv netretry yes

    # Brief settle for the Zero's own gadget enumeration. The 4B already
    # carries 10.55.0.1 (ConfigureWithoutCarrier=yes in
    # /etc/systemd/network/10-zero-rndis.network), so no long
    # host-readiness wait is needed.
    echo "Dev netboot: TFTP -> slot A"
    sleep 3
    mmc dev 0
    part start mmc 0 2 slot_a_start

    # Each TFTP-then-write block is gated on TFTP success — a failed
    # TFTP MUST NOT trigger a write, that would corrupt the slot / FAT
    # file with stale ${loadaddr} contents.
    setenv dev_ok 1

    if tftp ${loadaddr} pizero/rootfs.squashfs; then
        setexpr blkcnt ${filesize} / 0x200
        setexpr blkcnt ${blkcnt} + 1
        mmc write ${loadaddr} ${slot_a_start} ${blkcnt}
    else
        echo "Dev netboot: rootfs.squashfs TFTP failed"
        setenv dev_ok 0
    fi

    if test "${dev_ok}" = "1" && tftp ${loadaddr} pizero/zImage; then
        fatwrite mmc 0:1 ${loadaddr} boot/A/zImage ${filesize}
    fi
    if test "${dev_ok}" = "1" && tftp ${loadaddr} pizero/bcm2835-rpi-zero-w.dtb; then
        fatwrite mmc 0:1 ${loadaddr} boot/A/bcm2835-rpi-zero-w.dtb ${filesize}
    fi
    if test "${dev_ok}" = "1" && tftp ${loadaddr} pizero/initramfs.cpio.gz; then
        fatwrite mmc 0:1 ${loadaddr} initramfs.cpio.gz ${filesize}
    fi

    if test "${dev_ok}" = "1"; then
        setenv BOOT_ORDER "A B"
        setenv BOOT_A_LEFT 3
        setenv BOOT_B_LEFT 3
        saveenv
        echo "Dev netboot: slot A refreshed; falling through to A boot"
    else
        echo "Dev netboot: incomplete refresh, booting existing slot A unchanged"
    fi
fi

# ============================================================================
# Normal A/B selection.
# ============================================================================
setenv slot ""
if test "${BOOT_ORDER}" = "B A"; then
    if test ${BOOT_B_LEFT} -gt 0; then
        setenv slot B
    elif test ${BOOT_A_LEFT} -gt 0; then
        setenv slot A
    fi
else
    if test ${BOOT_A_LEFT} -gt 0; then
        setenv slot A
    elif test ${BOOT_B_LEFT} -gt 0; then
        setenv slot B
    fi
fi

if test "${slot}" = "A"; then
    setenv slot_part 2
    setexpr BOOT_A_LEFT ${BOOT_A_LEFT} - 1
fi
if test "${slot}" = "B"; then
    setenv slot_part 3
    setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1
fi
saveenv

echo "Booting slot ${slot} (mmcblk0p${slot_part})"

fatload mmc 0:1 ${kernel_addr_r}  boot/${slot}/zImage
fatload mmc 0:1 ${fdt_addr_r}     boot/${slot}/bcm2835-rpi-zero-w.dtb
fatload mmc 0:1 ${ramdisk_addr_r} initramfs.cpio.gz

setenv bootargs "earlycon=uart8250,mmio32,0x20215040 console=ttyS1,115200 root=/dev/mmcblk0p${slot_part} rootfstype=squashfs ro rauc.slot=${slot}"
bootz ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
