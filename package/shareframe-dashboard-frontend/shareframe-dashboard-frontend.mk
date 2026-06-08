################################################################################
#
# shareframe-dashboard-frontend
#
# React/Vite dashboard UI built from the sibling repo at
# ../shareframe-board/dashboard-frontend. Built at firmware-build time with
# host-nodejs and installed as static files to /usr/share/shareframe/
# dashboard-frontend, served by nginx on port 80 (see overlay/etc/nginx).
#
# Override the source path during dev with:
#   make shareframe-dashboard-frontend-rebuild \
#     SHAREFRAME_DASHBOARD_FRONTEND_OVERRIDE_SRCDIR=/path/to/checkout
#
################################################################################

SHAREFRAME_DASHBOARD_FRONTEND_VERSION = 1.0.0
SHAREFRAME_DASHBOARD_FRONTEND_SITE = $(BR2_EXTERNAL_SHAREFRAME_PATH)/../shareframe-board/dashboard-frontend
SHAREFRAME_DASHBOARD_FRONTEND_SITE_METHOD = local
SHAREFRAME_DASHBOARD_FRONTEND_LICENSE = ISC

# host-nodejs provides $(HOST_DIR)/bin/{node,npm} used to build the SPA.
SHAREFRAME_DASHBOARD_FRONTEND_DEPENDENCIES = host-nodejs

# `npm ci` needs node on PATH and a writable HOME/cache. Keep both inside the
# per-package build dir so we never touch the user's ~/.npm. Do NOT set
# NODE_ENV=production here: tsc/vite live in devDependencies and must install.
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
