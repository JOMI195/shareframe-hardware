################################################################################
#
# lgpio
#
# The "lg" GPIO archive (joan2937/lg) — liblgpio for SBC GPIO/SPI/I2C access
# via the Linux GPIO character device. Required by the Waveshare e-Paper
# driver in shareframe-board (compiled with USE_LGPIO_LIB).
#
################################################################################

LGPIO_VERSION = 0.2.2
LGPIO_SITE = $(call github,joan2937,lg,v$(LGPIO_VERSION))
LGPIO_LICENSE = Unlicense
LGPIO_LICENSE_FILES = UNLICENCE
LGPIO_INSTALL_STAGING = YES

# Upstream `all` also builds rgpiod/rgs and HTML docs, and `make install`
# shells out to host python2/python3 for the bindings. Build only the
# liblgpio shared object (target `liblgpio.so` -> liblgpio.so.1 + symlink,
# stripped) and install it by hand.
#
# NB1: the Makefile uses CROSS_PREFIX (not CROSS_COMPILE) for the tool prefix.
# NB2: do NOT pass CFLAGS — it would clobber the required -fpic/-pthread. The
#      Makefile appends $(CPPFLAGS) to its CFLAGS, so inject -std=gnu17 there.
# NB3: lg uses K&R empty-paren function pointers (typedef void (*)()); GCC 15
#      defaults to C23 where () means (void), turning every callback call into
#      a hard error. -std=gnu17 restores the "unspecified args" semantics.
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
