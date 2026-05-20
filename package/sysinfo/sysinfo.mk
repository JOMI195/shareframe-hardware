################################################################################
# sysinfo
################################################################################

SYSINFO_VERSION = 1.0
SYSINFO_SITE = $(TOPDIR)/../../package/sysinfo/src
SYSINFO_SITE_METHOD = local

define SYSINFO_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) CC="$(TARGET_CC)"
endef

define SYSINFO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/sysinfo $(TARGET_DIR)/usr/bin/sysinfo
endef

$(eval $(generic-package))