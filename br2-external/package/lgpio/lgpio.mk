# lgpio — liblgpio (joan2937/lg) for GPIO/SPI/I2C via the Linux chardev;
# required by the Waveshare e-Paper driver.

LGPIO_VERSION = 0.2.2
LGPIO_SITE = $(call github,joan2937,lg,v$(LGPIO_VERSION))
LGPIO_LICENSE = Unlicense
LGPIO_LICENSE_FILES = UNLICENCE
LGPIO_INSTALL_STAGING = YES

# Build only liblgpio (skip rgpiod/docs/python bindings) and install by hand.
# Gotchas: Makefile uses CROSS_PREFIX not CROSS_COMPILE; don't pass CFLAGS (it
# clobbers -fpic/-pthread — inject -std=gnu17 via CPPFLAGS); -std=gnu17 also
# stops GCC 15's C23 default rejecting lg's K&R empty-paren fn pointers.
define LGPIO_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) CROSS_PREFIX="$(TARGET_CROSS)" \
		CPPFLAGS="-std=gnu17" -C $(@D) liblgpio.so
endef

define LGPIO_INSTALL_STAGING_CMDS
	$(INSTALL) -D -m 0644 $(@D)/lgpio.h $(STAGING_DIR)/usr/include/lgpio.h
	$(INSTALL) -D -m 0755 $(@D)/liblgpio.so.1 $(STAGING_DIR)/usr/lib/liblgpio.so.1
	ln -sf liblgpio.so.1 $(STAGING_DIR)/usr/lib/liblgpio.so
endef

define LGPIO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/liblgpio.so.1 $(TARGET_DIR)/usr/lib/liblgpio.so.1
endef

$(eval $(generic-package))
