include $(sort $(wildcard $(BR2_EXTERNAL_HW4_PATH)/package/*/*.mk))
include $(sort $(wildcard $(BR2_EXTERNAL_HW4_PATH)/modules/*/*.mk))

HW4_KERNEL_MODULE_PKGS := $(notdir $(patsubst %/,%,$(wildcard $(BR2_EXTERNAL_HW4_PATH)/modules/*/)))

define HW4_INVALIDATE_KERNEL_MODULES
	rm -rf $(TARGET_DIR)/lib/modules/*
	for pkg in $(HW4_KERNEL_MODULE_PKGS); do \
		rm -f $(BUILD_DIR)/$$pkg-*/.stamp_built \
		      $(BUILD_DIR)/$$pkg-*/.stamp_target_installed \
		      $(BUILD_DIR)/$$pkg-*/.stamp_staging_installed; \
	done
endef
LINUX_POST_BUILD_HOOKS += HW4_INVALIDATE_KERNEL_MODULES
