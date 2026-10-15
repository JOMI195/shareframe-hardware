# shareframe-board — C++ services packaged from the sibling repo via Buildroot's
# cmake-package infra. Dev override:
#   make shareframe-board-rebuild SHAREFRAME_BOARD_OVERRIDE_SRCDIR=/path/to/checkout

SHAREFRAME_BOARD_VERSION = 1.0.0
SHAREFRAME_BOARD_SITE = $(BR2_EXTERNAL_SHAREFRAME_PATH)/../../shareframe-board
SHAREFRAME_BOARD_SITE_METHOD = local
SHAREFRAME_BOARD_LICENSE = ISC

SHAREFRAME_BOARD_DEPENDENCIES = openssl sqlitecpp spdlog lgpio

SHAREFRAME_BOARD_SUPPORTS_IN_SOURCE_BUILD = NO

# Buildroot's rsync never deletes, so files removed from the checkout would
# linger in the build dir and still be compiled. The excludes keep Buildroot's
# own stamps, file lists and out-of-source build dir.
define SHAREFRAME_BOARD_RSYNC_DELETE
	rsync -au --delete --chmod=u=rwX,go=rX $(RSYNC_VCS_EXCLUSIONS) \
		--exclude=/buildroot-build --exclude=/.stamp_* --exclude=/.files-list* \
		--exclude=/.applied_patches_list \
		$(call qstrip,$(SRCDIR))/ $(@D)/
endef
SHAREFRAME_BOARD_POST_RSYNC_HOOKS += SHAREFRAME_BOARD_RSYNC_DELETE

# App git sha, baked into the binaries. Read from the SITE (or the dev override),
# never $(@D): the local rsync drops .git. automation.sh exports APP_SHA; the
# $(shell) is the fallback for a bare `make`.
SHAREFRAME_BOARD_SRC = $(or $(SHAREFRAME_BOARD_OVERRIDE_SRCDIR),$(SHAREFRAME_BOARD_SITE))
SHAREFRAME_BOARD_APP_SHA = $(or $(APP_SHA),$(shell git -C $(SHAREFRAME_BOARD_SRC) describe --always --abbrev=7 --dirty --exclude='*' 2>/dev/null),unknown)

# Config profile (default prod); threaded into CMake so only the selected config
# overlay ships. Default keeps bare `make` working.
SHAREFRAME_PROFILE ?= prod

# E-Paper driver toggle (default OFF -> no-op display). ON links the Waveshare
# SPI/GPIO driver. CMake caches it: flipping the value needs a dirclean, not just
# a reconfigure.
SHAREFRAME_EPD ?= OFF

# Outbound IP family (default AF_UNSPEC -> resolver decides). AF_INET forces IPv4.
# Patched into the vendored IXWebSocket source; re-applies on reconfigure, no dirclean.
SHAREFRAME_IP_FAMILY ?= AF_UNSPEC

SHAREFRAME_BOARD_CONF_OPTS = \
	-DENABLE_EPD_HARDWARE=$(SHAREFRAME_EPD) \
	-DSHAREFRAME_IP_FAMILY=$(SHAREFRAME_IP_FAMILY) \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=OFF \
	-DSHAREFRAME_PROFILE=$(SHAREFRAME_PROFILE) \
	-DSHAREFRAME_APP_SHA=$(SHAREFRAME_BOARD_APP_SHA)

$(eval $(cmake-package))
