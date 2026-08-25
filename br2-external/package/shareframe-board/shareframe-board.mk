# shareframe-board — C++ services packaged from the sibling repo via Buildroot's
# cmake-package infra. Dev override:
#   make shareframe-board-rebuild SHAREFRAME_BOARD_OVERRIDE_SRCDIR=/path/to/checkout

SHAREFRAME_BOARD_VERSION = 1.0.0
SHAREFRAME_BOARD_SITE = $(BR2_EXTERNAL_SHAREFRAME_PATH)/../../shareframe-board
SHAREFRAME_BOARD_SITE_METHOD = local
SHAREFRAME_BOARD_LICENSE = ISC

SHAREFRAME_BOARD_DEPENDENCIES = openssl sqlitecpp spdlog lgpio

SHAREFRAME_BOARD_SUPPORTS_IN_SOURCE_BUILD = NO

# Config profile (default prod); threaded into CMake so only the selected config
# overlay ships. Default keeps bare `make` working.
SHAREFRAME_PROFILE ?= prod

# E-Paper driver toggle (default OFF -> no-op display). ON links the Waveshare
# SPI/GPIO driver. CMake caches it: flipping the value needs a dirclean, not just
# a reconfigure.
SHAREFRAME_EPD ?= OFF

# Outbound IP family (default AF_UNSPEC -> resolver decides). AF_INET forces IPv4.
# Like SHAREFRAME_EPD, baked in at fetch time: changing it needs a dirclean.
SHAREFRAME_IP_FAMILY ?= AF_UNSPEC

SHAREFRAME_BOARD_CONF_OPTS = \
	-DENABLE_EPD_HARDWARE=$(SHAREFRAME_EPD) \
	-DSHAREFRAME_IP_FAMILY=$(SHAREFRAME_IP_FAMILY) \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=OFF \
	-DSHAREFRAME_PROFILE=$(SHAREFRAME_PROFILE)

$(eval $(cmake-package))
