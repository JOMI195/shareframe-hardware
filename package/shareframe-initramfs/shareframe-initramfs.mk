################################################################################
#
# shareframe-initramfs
#
# Tiny initramfs (~500 KiB) loaded by the Pi firmware (config.txt initramfs
# directive). Its /init parses rauc.slot from
# /proc/cmdline, mounts the chosen squashfs slot partition read-only, sets up
# a tmpfs overlay for writable /, then switch_root into /sbin/init (s6).
#
# Built via the kernel's gen_init_cpio + a declarative manifest
# (initramfs.list). Manifest declares files / dirs / symlinks / the
# /dev/console char node without needing root or mknod. Busybox must be
# statically linked (CONFIG_STATIC=y) so no /lib/ld-musl-armhf.so.1 needs
# packaging.
#
################################################################################

SHAREFRAME_INITRAMFS_VERSION = 1.0
SHAREFRAME_INITRAMFS_SITE = $(BR2_EXTERNAL_SHAREFRAME_PATH)/package/shareframe-initramfs
SHAREFRAME_INITRAMFS_SITE_METHOD = local
SHAREFRAME_INITRAMFS_LICENSE = ISC
SHAREFRAME_INITRAMFS_INSTALL_IMAGES = YES

# linux: provides usr/gen_init_cpio after kernel build.
# busybox: target /bin/busybox (must be CONFIG_STATIC=y in busybox.conf).
SHAREFRAME_INITRAMFS_DEPENDENCIES = busybox linux

define SHAREFRAME_INITRAMFS_BUILD_CMDS
endef

define SHAREFRAME_INITRAMFS_INSTALL_IMAGES_CMDS
	GEN_INIT_CPIO=$$(ls $(BUILD_DIR)/linux-*/usr/gen_init_cpio 2>/dev/null | head -1); \
	if [ -z "$$GEN_INIT_CPIO" ]; then \
		echo "shareframe-initramfs: gen_init_cpio not found under $(BUILD_DIR)/linux-*/usr/"; \
		exit 1; \
	fi; \
	if ! file $(TARGET_DIR)/bin/busybox | grep -q 'statically linked'; then \
		echo "shareframe-initramfs: ERROR busybox is not statically linked. Set CONFIG_STATIC=y in busybox/busybox.conf."; \
		exit 1; \
	fi; \
	sed -e "s|@INIT_SRC@|$(@D)/rootfs/init|"           \
	    -e "s|@BUSYBOX_SRC@|$(TARGET_DIR)/bin/busybox|" \
	    $(@D)/initramfs.list > $(@D)/initramfs.list.expanded; \
	"$$GEN_INIT_CPIO" $(@D)/initramfs.list.expanded \
		| gzip -9 > $(BINARIES_DIR)/initramfs.cpio.gz; \
	echo "shareframe-initramfs: $(BINARIES_DIR)/initramfs.cpio.gz"; \
	ls -l $(BINARIES_DIR)/initramfs.cpio.gz
endef

$(eval $(generic-package))
