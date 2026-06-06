################################################################################
#
# shareframe-board
#
# C++23 applications (shareframe-application + shareframe-dashboard) packaged
# from the sibling repo at ../shareframe-board. Built via Buildroot's
# cmake-package infra so the toolchain file is injected automatically.
#
# Override the source path during dev with:
#   make shareframe-board-rebuild SHAREFRAME_BOARD_OVERRIDE_SRCDIR=/path/to/checkout
#
################################################################################

SHAREFRAME_BOARD_VERSION = 1.0.0
SHAREFRAME_BOARD_SITE = $(BR2_EXTERNAL_SHAREFRAME_PATH)/../shareframe-board
SHAREFRAME_BOARD_SITE_METHOD = local
SHAREFRAME_BOARD_LICENSE = ISC

SHAREFRAME_BOARD_DEPENDENCIES = openssl sqlitecpp spdlog lgpio

SHAREFRAME_BOARD_SUPPORTS_IN_SOURCE_BUILD = NO

SHAREFRAME_BOARD_CONF_OPTS = \
	-DENABLE_EPD_HARDWARE=OFF \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=OFF

$(eval $(cmake-package))
