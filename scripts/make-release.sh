#!/usr/bin/env bash
# Build a signed RAUC bundle (verity) from a stored build dir: rootfs.squashfs +
# boot.tar + hook.sh. Decoupled from the live Buildroot tree, so one build can be
# released dev + prod, or days later, without rebuilding.
# usage: make-release.sh --from <build-dir|label> [--release-dir DIR]
#        [--mode dev|prod] [--criticality C] [--notes FILE]
# Version comes from the build's build.json (single source) — never overridden here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_BIN="${ROOT}/build/buildroot/output/host/bin"
DEV_KEYS="${ROOT}/br2-external/package/shareframe-rauc/files"

# criticality must match the server's choices: Critical|Important|Minor|Patch
FROM="" REL_DIR="" MODE="dev" CRITICALITY="" NOTES_FILE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--from)        FROM="$2"; shift 2 ;;
		--release-dir) REL_DIR="$2"; shift 2 ;;
		--mode)        MODE="$2"; shift 2 ;;
		--criticality) CRITICALITY="$2"; shift 2 ;;
		--notes)       NOTES_FILE="$2"; shift 2 ;;
		*) echo "make-release: unknown arg $1" >&2; exit 1 ;;
	esac
done

# Resolve the build dir (a bare label lives under artifacts/builds/).
[ -n "${FROM}" ] || { echo "make-release: --from <build-dir|label> required" >&2; exit 1; }
[ -d "${FROM}" ] || FROM="${ROOT}/artifacts/builds/${FROM}"
[ -d "${FROM}" ] || { echo "make-release: build dir '${FROM}' not found" >&2; exit 1; }
for f in build.json rootfs.squashfs boot.tar; do
	[ -f "${FROM}/${f}" ] || { echo "make-release: ${FROM}/${f} missing; build first" >&2; exit 1; }
done

json_str() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "${FROM}/build.json"; }
BUILD_VERSION="$(json_str version)"
CONFIG="$(json_str config)"
# Provenance: which hardware + app commits went into this bundle.
OS_SHA="$(json_str os_sha)"
APP_SHA="$(json_str app_sha)"

# Release config (optional): version + criticality live in its config.env.
if [ -n "${REL_DIR}" ]; then
	[ -d "${REL_DIR}" ] || { echo "make-release: release dir '${REL_DIR}' not found" >&2; exit 1; }
	if [ -f "${REL_DIR}/config.env" ]; then
		# shellcheck disable=SC1090,SC1091
		. "${REL_DIR}/config.env"
		[ -n "${SHAREFRAME_VERSION:-}" ] && [ "${SHAREFRAME_VERSION}" != "${BUILD_VERSION}" ] && {
			echo "make-release: release version ${SHAREFRAME_VERSION} != build version ${BUILD_VERSION}" >&2; exit 1; }
		[ -z "${CRITICALITY}" ] && CRITICALITY="${SHAREFRAME_CRITICALITY:-}"
	fi
fi

# Bundle version is the baked build version — single source, the build.json.
VERSION="${BUILD_VERSION}"
[ -n "${VERSION}" ] || { echo "make-release: build.json has no version" >&2; exit 1; }
[ -n "${CRITICALITY}" ] || CRITICALITY="Minor"

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

# rauc tool: prefer Buildroot's host build; fall back to a system rauc so a
# release survives a buildroot clean (rauc is a tool, not a build deliverable).
RAUC="${HOST_BIN}/rauc"
if [ ! -x "${RAUC}" ]; then
	RAUC="$(command -v rauc || true)"
	[ -x "${RAUC}" ] && echo "make-release: WARNING using system rauc (${RAUC}); verity format may differ from the buildroot host rauc" >&2
fi
[ -x "${RAUC}" ] || { echo "make-release: no rauc (buildroot host tree or system rauc)" >&2; exit 1; }
[ -f "${CERT}" ] && [ -f "${KEY}" ] || { echo "signing cert/key missing (${CERT})" >&2; exit 1; }

OUT_DIR="${FROM}/releases"
OUT_BUNDLE="${OUT_DIR}/shareframe-${VERSION}-${MODE}.raucb"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

cp "${FROM}/rootfs.squashfs" "${work}/rootfs.squashfs"
cp "${FROM}/boot.tar"        "${work}/boot.tar"

{
	cat <<'HOOK'
#!/bin/sh
set -e
case "$1" in
	install-check)
		command -v shareframe-update-verify >/dev/null 2>&1 && shareframe-update-verify backup || true
HOOK
	if [ -n "${REL_DIR}" ] && [ -f "${REL_DIR}/pre.sh" ]; then
		echo "		# --- ${REL_DIR}/pre.sh ---"
		sed 's/^/\t\t/' "${REL_DIR}/pre.sh"
	fi
	cat <<'HOOK'
		;;
	slot-install)
		# replace target slot's subdir (A/ or B/) on boot FAT (p1)
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
				tar -xf "${RAUC_IMAGE_NAME}" -C "${mnt}/${bn}.new"
				sed -i "s/rauc\.slot=[A-Z@SLOT]*/rauc.slot=${bn}/" "${mnt}/${bn}.new/cmdline.txt"
				rm -rf "${mnt}/${bn}"
				mv "${mnt}/${bn}.new" "${mnt}/${bn}"
HOOK
	if [ -n "${REL_DIR}" ] && [ -f "${REL_DIR}/post.sh" ]; then
		echo "				# --- ${REL_DIR}/post.sh (\${mnt}=boot FAT, \${bn}=target slot) ---"
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
"${RAUC}" bundle \
	--cert="${CERT}" \
	--key="${KEY}" \
	"${work}" "${OUT_BUNDLE}"

SHA256=$(sha256sum "${OUT_BUNDLE}" | cut -d' ' -f1)
# sidecar in sha256sum format; the hash string goes into the server's checksum field
( cd "${OUT_DIR}" && sha256sum "$(basename "${OUT_BUNDLE}")" > "$(basename "${OUT_BUNDLE}").sha256" )
SIZE=$(stat -c%s "${OUT_BUNDLE}")
json_escape() {
	awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, ""); printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }' "$1"
}
NOTES=""
[ -n "${NOTES_FILE}" ] && [ -f "${NOTES_FILE}" ] && NOTES="$(json_escape "${NOTES_FILE}")"
[ -z "${NOTES}" ] && [ -n "${REL_DIR}" ] && [ -f "${REL_DIR}/notes.md" ] && NOTES="$(json_escape "${REL_DIR}/notes.md")"

cat > "${OUT_DIR}/release-${VERSION}-${MODE}.json" <<EOF
{
  "version": "${VERSION}",
  "config": "${CONFIG}",
  "os_sha": "${OS_SHA}",
  "app_sha": "${APP_SHA}",
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
echo "Metadata: ${OUT_DIR}/release-${VERSION}-${MODE}.json"
echo
echo "sha256 (-> server 'checksum' field): ${SHA256}"
ls -lh "${OUT_BUNDLE}"
