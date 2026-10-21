#!/usr/bin/env bash
# Provision a flash-ready per-device image from a fleet build: copy sdcard.img
# and mcopy the device's factory/ files into the factory partition (p5).
# No rebuild, no root, no loop mounts — mtools on the image file.
# usage: provision-device.sh --device configs/per-device/<dev>
#        [--from <build-label|dir>] [--out <img>] [--root-passwd]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_BIN="${ROOT}/build/buildroot/output/host/bin"

MCOPY="${HOST_BIN}/mcopy"
[ -x "${MCOPY}" ] || MCOPY="$(command -v mcopy || true)"
[ -n "${MCOPY}" ] || { echo "provision-device: mtools (mcopy) not found" >&2; exit 1; }
MDIR="${MCOPY%mcopy}mdir"
[ -x "${MDIR}" ] || MDIR="$(command -v mdir || true)"

DEVICE="" FROM="latest" OUT="" GEN_PASSWD=0
while [ $# -gt 0 ]; do
	case "$1" in
		--device)      DEVICE="$2"; shift 2 ;;
		--from)        FROM="$2"; shift 2 ;;
		--out)         OUT="$2"; shift 2 ;;
		--root-passwd) GEN_PASSWD=1; shift ;;
		*) echo "provision-device: unknown arg $1" >&2; exit 1 ;;
	esac
done

[ -n "${DEVICE}" ] || { echo "provision-device: --device configs/per-device/<dev> required" >&2; exit 1; }
DEVICE="${DEVICE%/}"
[ -d "${DEVICE}" ] || DEVICE="${ROOT}/configs/per-device/${DEVICE}"
[ -d "${DEVICE}" ] || { echo "provision-device: device dir '${DEVICE}' not found" >&2; exit 1; }
FACTORY="${DEVICE}/factory"

# Optional: generate the root pw hash into the device dir first.
if [ "${GEN_PASSWD}" = 1 ]; then
	mkdir -p "${FACTORY}"
	read -r -s -p "root password for $(basename "${DEVICE}"): " pw; echo
	printf '%s' "${pw}" | openssl passwd -5 -stdin > "${FACTORY}/rootpw"
	echo "provision-device: wrote ${FACTORY}/rootpw"
fi

[ -f "${FACTORY}/.env.secrets.toml" ] || {
	echo "provision-device: ${FACTORY}/.env.secrets.toml missing — a device needs an identity" >&2; exit 1; }
grep -q '^ed25519_private_key[[:space:]]*=[[:space:]]*"[^"]' "${FACTORY}/.env.secrets.toml" || {
	echo "provision-device: no ed25519_private_key — run scripts/gen-device-key.sh --device ${DEVICE}" >&2; exit 1; }

BUILD="${FROM}"
[ -d "${BUILD}" ] || BUILD="${ROOT}/artifacts/builds/${FROM}"
[ -f "${BUILD}/sdcard.img" ] || { echo "provision-device: ${BUILD}/sdcard.img not found — build first" >&2; exit 1; }

json_str() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "${BUILD}/build.json" 2>/dev/null; }
VERSION="$(json_str version)"
[ -n "${OUT}" ] || OUT="${ROOT}/artifacts/flash/$(basename "${DEVICE}")-${VERSION:-unknown}.img"

# Factory partition (p5) byte offset from the image's partition table.
P5_START="$(sfdisk -J "${BUILD}/sdcard.img" | sed -n 's/.*"node": *"[^"]*5", *"start": *\([0-9]*\).*/\1/p')"
[ -z "${P5_START}" ] && P5_START="$(sfdisk -J "${BUILD}/sdcard.img" \
	| tr -d ' \n' | grep -o '"node":"[^"]*5","start":[0-9]*' | grep -o '[0-9]*$')"
[ -n "${P5_START}" ] || { echo "provision-device: p5 not found in image partition table" >&2; exit 1; }
OFFSET=$((P5_START * 512))

mkdir -p "$(dirname "${OUT}")"
cp "${BUILD}/sdcard.img" "${OUT}"

# Inject every factory file — schema-free, future files ride along.
injected=""
for f in "${FACTORY}"/* "${FACTORY}"/.[!.]*; do
	[ -f "$f" ] || continue
	"${MCOPY}" -i "${OUT}@@${OFFSET}" -o "$f" "::/$(basename "$f")"
	injected="${injected} $(basename "$f")"
done
[ -n "${injected}" ] || { echo "provision-device: no files in ${FACTORY}" >&2; rm -f "${OUT}"; exit 1; }

echo "Image:    ${OUT}"
echo "Build:    ${BUILD} (version ${VERSION:-unknown})"
echo "Injected:${injected}"
[ -n "${MDIR}" ] && "${MDIR}" -i "${OUT}@@${OFFSET}" ::/ || true
echo
echo "flash: dd if=${OUT} of=/dev/sdX bs=4M conv=fsync status=progress"
