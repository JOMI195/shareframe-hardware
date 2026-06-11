# slot-install post hook — runs in the OLD system AFTER the target boot slot is
# written, before reboot. Embedded inside the bundle's slot-install boot case:
#   ${mnt} = mounted boot FAT (p1), ${bn} = target slot subdir (A or B).
# For run-every-update idempotent work use system-migrations instead (see
# br2-external/overlay/usr/share/shareframe/system-migrations/). Remove if unused.
echo "[release example post.sh] wrote slot ${bn} on boot FAT ${mnt}"
