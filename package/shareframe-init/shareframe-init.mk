################################################################################
#
# shareframe-init  (s6 PID1 basedir + s6-rc DB)
#
################################################################################

SHAREFRAME_INIT_VERSION = 1.0
SHAREFRAME_INIT_SITE = $(BR2_EXTERNAL_SHAREFRAME_PATH)/package/shareframe-init
SHAREFRAME_INIT_SITE_METHOD = local
SHAREFRAME_INIT_LICENSE = ISC

SHAREFRAME_INIT_DEPENDENCIES = \
	host-s6-linux-init-host host-s6-rc \
	s6 s6-rc s6-linux-init execline busybox

define SHAREFRAME_INIT_BUILD_CMDS
endef

define SHAREFRAME_INIT_INSTALL_TARGET_CMDS
	# 1) s6-linux-init basedir
	rm -rf $(TARGET_DIR)/etc/s6-linux-init/current
	mkdir -p $(TARGET_DIR)/etc/s6-linux-init
	$(HOST_DIR)/bin/s6-linux-init-maker \
		-c /etc/s6-linux-init/current \
		-p /usr/bin:/bin:/usr/sbin:/sbin \
		-m 0022 -1 \
		$(TARGET_DIR)/etc/s6-linux-init/current

	# 2) Stage-2 Scripts ueberschreiben
	$(INSTALL) -m 0755 $(@D)/skel/rc.init           $(TARGET_DIR)/etc/s6-linux-init/current/scripts/rc.init
	$(INSTALL) -m 0755 $(@D)/skel/rc.shutdown       $(TARGET_DIR)/etc/s6-linux-init/current/scripts/rc.shutdown
	$(INSTALL) -m 0755 $(@D)/skel/rc.shutdown.final $(TARGET_DIR)/etc/s6-linux-init/current/scripts/rc.shutdown.final

	# 3) /init + /sbin/init -> s6
	ln -sf /etc/s6-linux-init/current/bin/init $(TARGET_DIR)/sbin/init
	ln -sf /etc/s6-linux-init/current/bin/init $(TARGET_DIR)/init

	# 3b) sysv power commands -> s6 clean shutdown (overwrite busybox applet symlinks)
	$(INSTALL) -m 0755 $(@D)/skel/reboot   $(TARGET_DIR)/sbin/reboot
	$(INSTALL) -m 0755 $(@D)/skel/poweroff $(TARGET_DIR)/sbin/poweroff
	$(INSTALL) -m 0755 $(@D)/skel/halt     $(TARGET_DIR)/sbin/halt
	$(INSTALL) -m 0755 $(@D)/skel/shutdown $(TARGET_DIR)/sbin/shutdown

	# 4) Host/Target-Pfad-Symlinks (execlineb in /bin, oneshot-run in /libexec)
	ln -sf /bin/execlineb $(TARGET_DIR)/usr/bin/execlineb
	mkdir -p $(TARGET_DIR)/usr/libexec
	ln -sf /libexec/s6-rc-oneshot-run $(TARGET_DIR)/usr/libexec/s6-rc-oneshot-run

	# 5) s6-rc Service-DB
	rm -rf $(TARGET_DIR)/etc/s6-rc/compiled
	mkdir -p $(TARGET_DIR)/etc/s6-rc
	$(HOST_DIR)/bin/s6-rc-compile $(TARGET_DIR)/etc/s6-rc/compiled \
		$(@D)/source/*/
endef

$(eval $(generic-package))
