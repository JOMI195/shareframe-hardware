#!/usr/bin/env bash
# Generate a board's ed25519 identity on this host and write the private seed
# into the device's factory/.env.secrets.toml. Prints only the public key and
# frame id; paste the public key into the Frame admin of the server.
# usage: gen-device-key.sh --device configs/per-device/<dev> [--force]
#        gen-device-key.sh --selftest
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DEVICE="" FORCE=0 SELFTEST=0
while [ $# -gt 0 ]; do
	case "$1" in
		--device)   DEVICE="$2"; shift 2 ;;
		--force)    FORCE=1; shift ;;
		--selftest) SELFTEST=1; shift ;;
		*) echo "gen-device-key: unknown arg $1" >&2; exit 1 ;;
	esac
done

command -v openssl >/dev/null || { echo "gen-device-key: openssl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "gen-device-key: python3 not found" >&2; exit 1; }

# PKCS#8 wrapper around a raw 32-byte seed, so openssl can derive the public key.
public_key() {
	{ printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20'
	  printf '%s' "$1" | base64 -d; } \
		| openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64
}

# Must match frames.keys.public_key_fingerprint (server) and FrameIdentity (board).
fingerprint() {
	PUBLIC_KEY="$1" python3 -c '
import base64, hashlib, os
digest = hashlib.sha256(base64.b64decode(os.environ["PUBLIC_KEY"])).digest()[:10]
b32 = base64.b32encode(digest).decode().rstrip("=")
print("-".join(b32[i:i + 4] for i in range(0, len(b32), 4)))'
}

if [ "${SELFTEST}" = 1 ]; then
	# seed-frame-alice-living from shareframe seed-data.
	seed="4Lt78vIuTn62C9832MKfPzKN89RoMzyudfu1W4+0V6M="
	want_pub="MOGhe35ZWAgo0NLXew7cbwdmq36+kDwFmo/xd8VSbVY="
	want_id="FYCW-W4X7-NWOC-FSOO"
	pub="$(public_key "${seed}")"
	id="$(fingerprint "${pub}")"
	[ "${pub}" = "${want_pub}" ] && [ "${id}" = "${want_id}" ] || {
		echo "gen-device-key: selftest FAILED  got ${pub} ${id}  want ${want_pub} ${want_id}" >&2; exit 1; }
	echo "gen-device-key: selftest OK (${id})"
	exit 0
fi

[ -n "${DEVICE}" ] || { echo "gen-device-key: --device configs/per-device/<dev> required" >&2; exit 1; }
DEVICE="${DEVICE%/}"
[ -d "${DEVICE}" ] || DEVICE="${ROOT}/configs/per-device/${DEVICE}"
[ -d "${DEVICE}" ] || { echo "gen-device-key: device dir '${DEVICE}' not found (cp -r configs/per-device/example first)" >&2; exit 1; }
case "$(cd "${DEVICE}" && pwd)" in
	*/configs/per-device/example) echo "gen-device-key: example is tracked, never put a key there" >&2; exit 1 ;;
esac

SECRETS="${DEVICE}/factory/.env.secrets.toml"
mkdir -p "${DEVICE}/factory"
touch "${SECRETS}"
chmod 0600 "${SECRETS}"
grep -q '^ed25519_private_key[[:space:]]*=' "${SECRETS}" \
	|| printf 'ed25519_private_key = ""\n' >> "${SECRETS}"

if grep -q '^ed25519_private_key[[:space:]]*=[[:space:]]*"[^"]' "${SECRETS}" && [ "${FORCE}" != 1 ]; then
	echo "gen-device-key: ${SECRETS} already has a key. Refusing to overwrite (--force replaces it," >&2
	echo "  the board then needs a reflash and the new public key in the admin)." >&2
	exit 1
fi

seed="$(openssl rand -base64 32)"
pub="$(public_key "${seed}")"
id="$(fingerprint "${pub}")"

sed -i "s|^ed25519_private_key[[:space:]]*=.*|ed25519_private_key = \"${seed}\"|" "${SECRETS}"

echo "Frame id:   ${id}"
echo "Public key: ${pub}"
echo "Seed in:    ${SECRETS}"
echo
echo "Paste the public key into the Frame admin (add or change frame)."
