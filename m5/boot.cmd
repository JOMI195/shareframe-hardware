# U-Boot Boot-Script für Pi Zero W Netboot (mit mkimage zu boot.scr kompiliert).
# TFTP-Server = Pi 4B (10.55.0.1), Verbindung über USB-Gadget-Ethernet (usb0).
setenv serverip 10.55.0.1
setenv ipaddr   10.55.0.2

usb start

tftp ${kernel_addr_r}  pizero/zImage
tftp ${fdt_addr_r}     pizero/bcm2835-rpi-zero-w.dtb
tftp ${ramdisk_addr_r} pizero/rootfs.cpio.gz

# Pi Zero W GPIO-Konsole = mini-UART (ttyS1); PL011 (ttyAMA0) ist für BT reserviert.
setenv bootargs console=ttyS1,115200 root=/dev/ram0 rw
bootz ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
