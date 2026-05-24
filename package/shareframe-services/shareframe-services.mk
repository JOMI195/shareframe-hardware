################################################################################
#
# shareframe-services
#
# Packs the per-board C++ service tree (source/) into /opt/services.sqfs.
# Currently a placeholder: source/ is empty. Future services contribute
# their install layout into source/<name>/.
#
################################################################################

SHAREFRAME_SERVICES_VERSION = 1.0
SHAREFRAME_SERVICES_SITE = $(BR2_EXTERNAL_SHAREFRAME_PATH)/package/shareframe-services
SHAREFRAME_SERVICES_SITE_METHOD = local
SHAREFRAME_SERVICES_LICENSE = ISC

SHAREFRAME_SERVICES_DEPENDENCIES = host-squashfs

define SHAREFRAME_SERVICES_BUILD_CMDS
	rm -rf $(@D)/services
	mkdir -p $(@D)/services
	if [ -d $(@D)/source ] && [ -n "$$(ls -A $(@D)/source 2>/dev/null || true)" ]; then \
		cp -a $(@D)/source/. $(@D)/services/; \
	fi
	$(HOST_DIR)/bin/mksquashfs $(@D)/services $(@D)/services.sqfs \
		-comp zstd -noappend -all-root -no-progress -quiet
endef

define SHAREFRAME_SERVICES_INSTALL_TARGET_CMDS
	$(INSTALL) -m 0644 -D $(@D)/services.sqfs $(TARGET_DIR)/opt/services.sqfs
endef

$(eval $(generic-package))
