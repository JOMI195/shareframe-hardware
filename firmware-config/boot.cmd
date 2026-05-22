# U-Boot Boot-Script für Pi Zero W Netboot (von uboot-tools zu boot.scr kompiliert).
# TFTP-Server = Pi 4B (10.55.0.1), Link Zero<->4B = USB-Gadget-Ethernet (usb0).
setenv ipaddr   10.55.0.2
setenv serverip 10.55.0.1

# feste MACs fuers usb_ether-Gadget (sonst random/instabil)
setenv usbnet_devaddr  f8:dc:7a:00:00:02
setenv usbnet_hostaddr f8:dc:7a:00:00:01
setenv ethact   usb_ether
setenv ethprime usb_ether

tftp ${kernel_addr_r}  pizero/zImage
tftp ${fdt_addr_r}     pizero/bcm2835-rpi-zero-w.dtb
tftp ${ramdisk_addr_r} pizero/rootfs.cpio.gz

setenv bootargs earlycon=uart8250,mmio32,0x20215040 console=ttyS1,115200 root=/dev/ram0 rw
bootz ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
