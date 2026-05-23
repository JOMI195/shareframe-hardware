#!/bin/bash
# Post-build: Build-Metadaten ins Rootfs schreiben
set -e

TARGET_DIR="$1"   # von Buildroot gesetzt: Pfad zum Staging-Rootfs

echo "=== Post-build: Build-Stempel erzeugen ==="

{
    echo "built_at=$(date --iso-8601=seconds)"
    echo "built_by=$(whoami)@$(hostname)"
    echo "git_commit=${BUILD_SHA:-unknown}"
} > "$TARGET_DIR/etc/build-info"

echo "=== Post-build: /etc/build-info geschrieben ==="

if [ -n "$BUILD_SHA" ]; then
    {
        echo "BUILD_ID=$BUILD_SHA"
    } >> "$TARGET_DIR/etc/os-release"
    echo "=== Post-build: BUILD_ID in /etc/os-release ergaenzt ==="
fi

echo "=== Post-build: s6 als PID1 einrichten ==="
SRC="${BR2_EXTERNAL_SHAREFRAME_PATH}/s6"

# 1) s6-linux-init basedir erzeugen (PID1-Image)
rm -rf "$TARGET_DIR/etc/s6-linux-init/current"
mkdir -p "$TARGET_DIR/etc/s6-linux-init"
"$HOST_DIR/bin/s6-linux-init-maker" \
    -c /etc/s6-linux-init/current \
    -p /usr/bin:/bin:/usr/sbin:/sbin \
    -m 0022 -1 \
    "$TARGET_DIR/etc/s6-linux-init/current"

# eigene Stage-2-Scripts: s6-rc default-Bundle hochfahren
cp "$SRC/skel/rc.init"     "$TARGET_DIR/etc/s6-linux-init/current/scripts/rc.init"
cp "$SRC/skel/rc.shutdown" "$TARGET_DIR/etc/s6-linux-init/current/scripts/rc.shutdown"
chmod +x "$TARGET_DIR/etc/s6-linux-init/current/scripts/rc.init" \
         "$TARGET_DIR/etc/s6-linux-init/current/scripts/rc.shutdown"

# 2) /init (initramfs-Entry) + /sbin/init -> s6
ln -sf /etc/s6-linux-init/current/bin/init "$TARGET_DIR/sbin/init"
ln -sf /etc/s6-linux-init/current/bin/init "$TARGET_DIR/init"

# 2b) Host-kompilierte Scripts/DB nutzen /usr/bin bzw. /usr/libexec, Target legt aber
#     execlineb in /bin und s6-rc-oneshot-run in /libexec ab -> Symlinks angleichen.
ln -sf /bin/execlineb "$TARGET_DIR/usr/bin/execlineb"
mkdir -p "$TARGET_DIR/usr/libexec"
ln -sf /libexec/s6-rc-oneshot-run "$TARGET_DIR/usr/libexec/s6-rc-oneshot-run"

# 3) s6-rc Service-DB kompilieren (Host-Tool)
rm -rf "$TARGET_DIR/etc/s6-rc/compiled"
mkdir -p "$TARGET_DIR/etc/s6-rc"
"$HOST_DIR/bin/s6-rc-compile" "$TARGET_DIR/etc/s6-rc/compiled" "$SRC/source"

echo "=== Post-build: s6 fertig ==="