################################################################################
#
# shareframe-board
#
# C++23 services (shareframe-display, shareframe-websocket, shareframe-dashboard,
# shareframe-heartbeat) plus the shareframe-migrate DB-setup oneshot, packaged
# from the sibling repo at ../shareframe-board. Built via Buildroot's
# cmake-package infra so the toolchain file is injected automatically;
# install(TARGETS) in CMakeLists drives which binaries ship.
#
# Override the source path during dev with:
#   make shareframe-board-rebuild SHAREFRAME_BOARD_OVERRIDE_SRCDIR=/path/to/checkout
#
################################################################################

SHAREFRAME_BOARD_VERSION = 1.0.0
SHAREFRAME_BOARD_SITE = $(BR2_EXTERNAL_SHAREFRAME_PATH)/../../shareframe-board
SHAREFRAME_BOARD_SITE_METHOD = local
SHAREFRAME_BOARD_LICENSE = ISC

SHAREFRAME_BOARD_DEPENDENCIES = openssl sqlitecpp spdlog lgpio

SHAREFRAME_BOARD_SUPPORTS_IN_SOURCE_BUILD = NO

# SHAREFRAME_PROFILE: dev | prod (default) | prod.local. Exported by
# automation.sh (env -> make var); -? default keeps bare `make` working.
# Threaded into CMake so install() ships only the selected config.<profile>.toml
# overlay (matched at runtime by the /etc/shareframe-profile the s6 run scripts
# export). Must stay in sync with what post-build.sh writes to that file.
SHAREFRAME_PROFILE ?= prod

# SHAREFRAME_EPD: ON | OFF (default). Exported by automation.sh from the
# config.env (env -> make var); -? default keeps bare `make` working. ON links
# the waveshare e-Paper driver (external/waveshare, real SPI/GPIO) — needs the
# SPI/spidev kernel fragment (fragments/kernel-spi.fragment) and the
# spi0-spidev.dtbo overlay, both already shipped. OFF builds the no-op
# DisplayManager fallback. CMake caches the option: switch value -> a
# shareframe-board-dirclean is required (automation rebuild loop does
# -reconfigure, so flip via env then full build, or dirclean first).
SHAREFRAME_EPD ?= OFF

SHAREFRAME_BOARD_CONF_OPTS = \
	-DENABLE_EPD_HARDWARE=$(SHAREFRAME_EPD) \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=OFF \
	-DSHAREFRAME_PROFILE=$(SHAREFRAME_PROFILE)

$(eval $(cmake-package))
