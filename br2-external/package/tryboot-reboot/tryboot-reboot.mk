################################################################################
# tryboot-reboot
################################################################################

TRYBOOT_REBOOT_VERSION = 1.0
TRYBOOT_REBOOT_SITE = $(BR2_EXTERNAL_SHAREFRAME_PATH)/package/tryboot-reboot/src
TRYBOOT_REBOOT_SITE_METHOD = local

define TRYBOOT_REBOOT_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) CC="$(TARGET_CC)"
endef

define TRYBOOT_REBOOT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/tryboot-reboot $(TARGET_DIR)/usr/sbin/tryboot-reboot
endef

$(eval $(generic-package))
