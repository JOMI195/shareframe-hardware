#!/usr/bin/env bash
# Build a RAUC bundle (.raucb) from the latest rootfs.squashfs + kernel +
# initramfs artifacts. Signs with the dev key. Drops shareframe-<ver>.raucb in
# artifacts/deploy/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG_DIR="${ROOT}/buildroot/src/output/images"
HOST_BIN="${ROOT}/buildroot/src/output/host/bin"
KEYS_DIR="${ROOT}/package/shareframe-rauc/files"

[ -x "${HOST_BIN}/rauc" ] || { echo "host-rauc missing; build first"; exit 1; }
[ -f "${KEYS_DIR}/cert.pem" ] || { echo "Dev keys missing; run scripts/gen-dev-keys.sh"; exit 1; }
[ -f "${KEYS_DIR}/key.pem"  ] || { echo "Dev keys missing; run scripts/gen-dev-keys.sh"; exit 1; }
[ -f "${IMG_DIR}/rootfs.squashfs" ] || { echo "rootfs.squashfs missing; build first"; exit 1; }

VERSION="${BUILD_SHA:-$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || date +%s)}"
OUT_BUNDLE="${ROOT}/artifacts/deploy/shareframe-${VERSION}.raucb"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

cat > "${work}/manifest.raucm" <<EOF
[update]
compatible=shareframe-pi0w
version=${VERSION}

[bundle]
format=plain

[image.rootfs]
filename=rootfs.squashfs
EOF

cp "${IMG_DIR}/rootfs.squashfs" "${work}/rootfs.squashfs"

mkdir -p "${ROOT}/artifacts/deploy"
rm -f "${OUT_BUNDLE}"
"${HOST_BIN}/rauc" bundle \
	--cert="${KEYS_DIR}/cert.pem" \
	--key="${KEYS_DIR}/key.pem" \
	"${work}" "${OUT_BUNDLE}"

echo "Bundle: ${OUT_BUNDLE}"
ls -lh "${OUT_BUNDLE}"
