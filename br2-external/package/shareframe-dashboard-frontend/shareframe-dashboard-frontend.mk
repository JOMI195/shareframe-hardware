# shareframe-dashboard-frontend — React/Vite dashboard UI built from the sibling
# repo with host-nodejs, installed as static files served by nginx. Dev override:
#   make shareframe-dashboard-frontend-rebuild \
#     SHAREFRAME_DASHBOARD_FRONTEND_OVERRIDE_SRCDIR=/path/to/checkout

SHAREFRAME_DASHBOARD_FRONTEND_VERSION = 1.0.0
SHAREFRAME_DASHBOARD_FRONTEND_SITE = $(BR2_EXTERNAL_SHAREFRAME_PATH)/../../shareframe-board/dashboard-frontend
SHAREFRAME_DASHBOARD_FRONTEND_SITE_METHOD = local
SHAREFRAME_DASHBOARD_FRONTEND_LICENSE = ISC

# host-nodejs provides $(HOST_DIR)/bin/{node,npm} used to build the SPA.
SHAREFRAME_DASHBOARD_FRONTEND_DEPENDENCIES = host-nodejs

# Buildroot's rsync never deletes, so files removed from the checkout would
# linger in the build dir and still be compiled. Limited to frontend/ so the
# stamps, npm cache and build output at the top level survive.
define SHAREFRAME_DASHBOARD_FRONTEND_RSYNC_DELETE
	rsync -au --delete --chmod=u=rwX,go=rX $(RSYNC_VCS_EXCLUSIONS) \
		$(call qstrip,$(SRCDIR))/frontend/ $(@D)/frontend/
endef
SHAREFRAME_DASHBOARD_FRONTEND_POST_RSYNC_HOOKS += SHAREFRAME_DASHBOARD_FRONTEND_RSYNC_DELETE

# Keep node PATH + npm cache inside the build dir (don't touch ~/.npm). Don't set
# NODE_ENV=production: tsc/vite are devDependencies and must install.
define SHAREFRAME_DASHBOARD_FRONTEND_BUILD_CMDS
	cd $(@D)/frontend && \
		PATH=$(HOST_DIR)/bin:$(BR_PATH) HOME=$(@D) npm_config_cache=$(@D)/.npm-cache \
		$(HOST_DIR)/bin/npm ci
	cd $(@D)/frontend && \
		PATH=$(HOST_DIR)/bin:$(BR_PATH) HOME=$(@D) npm_config_cache=$(@D)/.npm-cache \
		$(HOST_DIR)/bin/npm run build
endef

# vite.config.ts emits the production bundle to ../build (i.e. $(@D)/build).
define SHAREFRAME_DASHBOARD_FRONTEND_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/share/shareframe/dashboard-frontend
	cp -a $(@D)/build/. $(TARGET_DIR)/usr/share/shareframe/dashboard-frontend/
endef

$(eval $(generic-package))
