# s6-linux-init-host — host-only: provides s6-linux-init-maker at build time.

S6_LINUX_INIT_HOST_VERSION = 1.1.2.1
# Buildroot mirror instead of skarnet.org (same tarball + hash as the target package).
S6_LINUX_INIT_HOST_SITE = https://sources.buildroot.net/s6-linux-init
S6_LINUX_INIT_HOST_SOURCE = s6-linux-init-$(S6_LINUX_INIT_HOST_VERSION).tar.gz
S6_LINUX_INIT_HOST_LICENSE = ISC
S6_LINUX_INIT_HOST_LICENSE_FILES = COPYING

HOST_S6_LINUX_INIT_HOST_DEPENDENCIES = \
	host-skalibs host-execline host-s6

HOST_S6_LINUX_INIT_HOST_CONF_OPTS = \
	--prefix=$(HOST_DIR) \
	--with-sysdeps=$(HOST_DIR)/lib/skalibs/sysdeps \
	--with-include=$(HOST_DIR)/include \
	--with-dynlib=$(HOST_DIR)/lib \
	--with-lib=$(HOST_DIR)/lib/execline \
	--with-lib=$(HOST_DIR)/lib/s6 \
	--with-lib=$(HOST_DIR)/lib/skalibs

define HOST_S6_LINUX_INIT_HOST_CONFIGURE_CMDS
	(cd $(@D); $(HOST_CONFIGURE_OPTS) ./configure $(HOST_S6_LINUX_INIT_HOST_CONF_OPTS))
endef

define HOST_S6_LINUX_INIT_HOST_BUILD_CMDS
	$(HOST_MAKE_ENV) $(MAKE) -C $(@D)
endef

define HOST_S6_LINUX_INIT_HOST_INSTALL_CMDS
	$(HOST_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR= install
endef

$(eval $(host-generic-package))
