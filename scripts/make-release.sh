#!/usr/bin/env bash
# Build a signed RAUC release bundle (verity) from the latest build artifacts:
#   rootfs.squashfs (rootfs slot) + boot.tar (boot slot file set) + hook.sh.
# Optional per-release scripts releases/<version>/{pre,post}.sh ship inside the
# signed bundle (pre: install-check, old system, may abort; post: after boot
# slot is written, old system). Drops shareframe-<version>.raucb +
# release.json into artifacts/release/<version>/.
#
# usage: make-release.sh [--version X] [--mode dev|prod] [--criticality C] [--notes FILE]
#   keys: SHAREFRAME_RELEASE_CERT / SHAREFRAME_RELEASE_KEY (prod; keep offline)
#         default = dev keys in package/shareframe-rauc/files/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG_DIR="${ROOT}/buildroot/src/output/images"
HOST_BIN="${ROOT}/buildroot/src/output/host/bin"
DEV_KEYS="${ROOT}/package/shareframe-rauc/files"

# criticality must match the server's choices: Critical|Important|Minor|Patch
VERSION="" MODE="dev" CRITICALITY="Minor" NOTES_FILE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--version)     VERSION="$2"; shift 2 ;;
		--mode)        MODE="$2"; shift 2 ;;
		--criticality) CRITICALITY="$2"; shift 2 ;;
		--notes)       NOTES_FILE="$2"; shift 2 ;;
		*) echo "make-release: unknown arg $1" >&2; exit 1 ;;
	esac
done

if [ -z "${VERSION}" ]; then
	VERSION_TOML="${SHAREFRAME_BOARD_OVERRIDE_SRCDIR:-${ROOT}/../shareframe-board}/VERSION.toml"
	[ -f "${VERSION_TOML}" ] && VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "${VERSION_TOML}")"
fi
[ -n "${VERSION}" ] || VERSION="${BUILD_SHA:-$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || date +%s)}"

case "${MODE}" in
	prod)
		CERT="${SHAREFRAME_RELEASE_CERT:?prod mode needs SHAREFRAME_RELEASE_CERT}"
		KEY="${SHAREFRAME_RELEASE_KEY:?prod mode needs SHAREFRAME_RELEASE_KEY}"
		;;
	dev)
		CERT="${SHAREFRAME_RELEASE_CERT:-${DEV_KEYS}/cert.pem}"
		KEY="${SHAREFRAME_RELEASE_KEY:-${DEV_KEYS}/key.pem}"
		;;
	*) echo "make-release: mode must be dev or prod" >&2; exit 1 ;;
esac

[ -x "${HOST_BIN}/rauc" ] || { echo "host-rauc missing; build first" >&2; exit 1; }
[ -f "${CERT}" ] && [ -f "${KEY}" ] || { echo "signing cert/key missing (${CERT})" >&2; exit 1; }
[ -f "${IMG_DIR}/rootfs.squashfs" ] || { echo "rootfs.squashfs missing; build first" >&2; exit 1; }
[ -d "${IMG_DIR}/bootslot-tree" ] || { echo "bootslot-tree missing; build first (post-image.sh stages it)" >&2; exit 1; }

OUT_DIR="${ROOT}/artifacts/release/${VERSION}"
OUT_BUNDLE="${OUT_DIR}/shareframe-${VERSION}.raucb"
REL_DIR="${ROOT}/releases/${VERSION}"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

cp "${IMG_DIR}/rootfs.squashfs" "${work}/rootfs.squashfs"
# per-slot kernel set (slot-neutral: cmdline.txt ships rauc.slot=@SLOT@, the
# slot-install hook substitutes the target slot)
tar -C "${IMG_DIR}/bootslot-tree" -cf "${work}/boot.tar" .

# hook.sh: fixed cmdline fix-up + optional per-release pre/post scripts.
{
	cat <<'HOOK'
#!/bin/sh
set -e
case "$1" in
	install-check)
		# RAUC already enforced manifest<->system compatible. Extra checks below.
		# back up per-device /data files before the slot is written (old system)
		command -v shareframe-update-verify >/dev/null 2>&1 && shareframe-update-verify backup || true
HOOK
	if [ -f "${REL_DIR}/pre.sh" ]; then
		echo "		# --- releases/${VERSION}/pre.sh ---"
		sed 's/^/\t\t/' "${REL_DIR}/pre.sh"
	fi
	cat <<'HOOK'
		;;
	slot-install)
		# full-custom install of the boot image: replace the target slot's
		# subdir (A/ or B/) on the shared boot FAT (p1)
		case "${RAUC_SLOT_CLASS}" in
			boot)
				bn="${RAUC_SLOT_BOOTNAME}"
				[ -n "${bn}" ] || { echo "hook: no RAUC_SLOT_BOOTNAME" >&2; exit 1; }
				mnt=/run/shareframe/boot-install
				mkdir -p "${mnt}"
				mount -t vfat -o rw,noatime /dev/mmcblk0p1 "${mnt}"
				trap 'umount "${mnt}" 2>/dev/null || true' EXIT
				rm -rf "${mnt}/${bn}.new"
				mkdir -p "${mnt}/${bn}.new"
				tar -xf "${RAUC_BUNDLE_MOUNT_POINT}/${RAUC_IMAGE_NAME}" -C "${mnt}/${bn}.new"
				sed -i "s/rauc\.slot=[A-Z@SLOT]*/rauc.slot=${bn}/" "${mnt}/${bn}.new/cmdline.txt"
				rm -rf "${mnt}/${bn}"
				mv "${mnt}/${bn}.new" "${mnt}/${bn}"
HOOK
	if [ -f "${REL_DIR}/post.sh" ]; then
		echo "				# --- releases/${VERSION}/post.sh (\${mnt}=boot FAT, \${bn}=target slot) ---"
		sed 's/^/\t\t\t\t/' "${REL_DIR}/post.sh"
	fi
	cat <<'HOOK'
				sync
				umount "${mnt}"
				;;
		esac
		;;
esac
HOOK
} > "${work}/hook.sh"
chmod +x "${work}/hook.sh"

cat > "${work}/manifest.raucm" <<EOF
[update]
compatible=shareframe-pi0w
version=${VERSION}

[bundle]
format=verity

[hooks]
filename=hook.sh
hooks=install-check

[image.rootfs]
filename=rootfs.squashfs

[image.boot]
filename=boot.tar
hooks=install
EOF

mkdir -p "${OUT_DIR}"
rm -f "${OUT_BUNDLE}"
"${HOST_BIN}/rauc" bundle \
	--cert="${CERT}" \
	--key="${KEY}" \
	"${work}" "${OUT_BUNDLE}"

SHA256=$(sha256sum "${OUT_BUNDLE}" | cut -d' ' -f1)
# sidecar in sha256sum format; the hash string goes into the server's checksum field
( cd "${OUT_DIR}" && sha256sum "$(basename "${OUT_BUNDLE}")" > "$(basename "${OUT_BUNDLE}").sha256" )
SIZE=$(stat -c%s "${OUT_BUNDLE}")
NOTES=""
[ -n "${NOTES_FILE}" ] && [ -f "${NOTES_FILE}" ] && NOTES="$(sed 's/\\/\\\\/g; s/"/\\"/g' "${NOTES_FILE}" | tr '\n' ' ')"
[ -z "${NOTES}" ] && [ -f "${REL_DIR}/notes.md" ] && NOTES="$(sed 's/\\/\\\\/g; s/"/\\"/g' "${REL_DIR}/notes.md" | tr '\n' ' ')"

cat > "${OUT_DIR}/release.json" <<EOF
{
  "version": "${VERSION}",
  "criticality": "${CRITICALITY}",
  "file": "$(basename "${OUT_BUNDLE}")",
  "sha256": "${SHA256}",
  "size": ${SIZE},
  "mode": "${MODE}",
  "release_date": "$(date --iso-8601=seconds)",
  "release_notes": "${NOTES}"
}
EOF

echo "Bundle:   ${OUT_BUNDLE}"
echo "Checksum: ${OUT_BUNDLE}.sha256"
echo "Metadata: ${OUT_DIR}/release.json"
echo
echo "sha256 (-> Server-Feld 'checksum'): ${SHA256}"
ls -lh "${OUT_BUNDLE}"
