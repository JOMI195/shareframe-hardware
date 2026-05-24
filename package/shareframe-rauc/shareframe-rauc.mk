################################################################################
#
# shareframe-rauc
#
################################################################################

SHAREFRAME_RAUC_VERSION = 1.0
SHAREFRAME_RAUC_SITE = $(BR2_EXTERNAL_SHAREFRAME_PATH)/package/shareframe-rauc
SHAREFRAME_RAUC_SITE_METHOD = local
SHAREFRAME_RAUC_LICENSE = ISC

SHAREFRAME_RAUC_DEPENDENCIES = rauc

define SHAREFRAME_RAUC_BUILD_CMDS
endef

define SHAREFRAME_RAUC_INSTALL_TARGET_CMDS
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/etc/rauc
	$(INSTALL) -m 0644 $(@D)/files/system.conf      $(TARGET_DIR)/etc/rauc/system.conf
	$(INSTALL) -m 0755 $(@D)/files/post-install.sh  $(TARGET_DIR)/etc/rauc/post-install.sh
	# CA cert. May be missing if `scripts/gen-dev-keys.sh` was never run.
	# Install a placeholder so /etc/rauc/ca.cert.pem always exists; real cert
	# overrides at re-run.
	if [ -f $(@D)/files/ca.cert.pem ]; then \
		$(INSTALL) -m 0644 $(@D)/files/ca.cert.pem $(TARGET_DIR)/etc/rauc/ca.cert.pem; \
	else \
		echo "shareframe-rauc: WARN ca.cert.pem missing; run scripts/gen-dev-keys.sh first" >&2; \
		: > $(TARGET_DIR)/etc/rauc/ca.cert.pem; \
	fi
endef

$(eval $(generic-package))
