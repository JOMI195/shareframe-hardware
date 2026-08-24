#!/usr/bin/env bash
# Derive a WPA2 PSK for a per-device factory/wpa_supplicant.conf block.
# SSID is read from a prompt, never argv: shell word-splitting and history
# expansion on SSIDs like "FRITZ!Box 5590 VR" silently produce a valid-looking
# but wrong PSK (the SSID is the PBKDF2 salt, and it is never validated).
# usage: wifi-psk.sh [--priority N] [--verify <64-hex>] [--selftest]
set -euo pipefail

PRIORITY="" VERIFY="" SELFTEST=0
while [ $# -gt 0 ]; do
	case "$1" in
		--priority) PRIORITY="$2"; shift 2 ;;
		--verify)   VERIFY="$2"; shift 2 ;;
		--selftest) SELFTEST=1; shift ;;
		*) echo "wifi-psk: unknown arg $1" >&2; exit 1 ;;
	esac
done

command -v python3 >/dev/null || { echo "wifi-psk: python3 not found" >&2; exit 1; }

# PBKDF2-SHA1(passphrase, ssid, 4096, 32) — inputs via env, never argv (ps-visible).
derive() {
	PSK_SSID="$1" PSK_PASS="$2" python3 -c '
import hashlib, os
ssid = os.environb[b"PSK_SSID"]
pw = os.environb[b"PSK_PASS"]
print(hashlib.pbkdf2_hmac("sha1", pw, ssid, 4096, 32).hex())'
}

nbytes() { printf '%s' "$1" | wc -c; }

if [ "${SELFTEST}" = 1 ]; then
	# IEEE 802.11i Annex H.4 test vector.
	want="f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"
	got="$(derive "IEEE" "password")"
	[ "${got}" = "${want}" ] || { echo "wifi-psk: selftest FAILED  got ${got}  want ${want}" >&2; exit 1; }
	echo "wifi-psk: selftest OK (${got})"
	exit 0
fi

[ -z "${PRIORITY}" ] || case "${PRIORITY}" in
	*[!0-9]*|"") echo "wifi-psk: --priority must be a number" >&2; exit 1 ;;
esac

if [ -n "${VERIFY}" ]; then
	VERIFY="$(printf '%s' "${VERIFY}" | tr 'A-F' 'a-f')"
	case "${VERIFY}" in
		*[!0-9a-f]*) echo "wifi-psk: --verify must be 64 hex chars" >&2; exit 1 ;;
	esac
	[ "$(nbytes "${VERIFY}")" = 64 ] || { echo "wifi-psk: --verify must be 64 hex chars" >&2; exit 1; }
fi

# IFS= or read strips the very leading/trailing spaces this is meant to catch.
IFS= read -r -p "ssid: " ssid
len="$(nbytes "${ssid}")"
echo "ssid: [${ssid}] (${len} bytes)"
[ "${len}" -ge 1 ] || { echo "wifi-psk: ssid is empty" >&2; exit 1; }
[ "${len}" -le 32 ] || { echo "wifi-psk: ssid is ${len} bytes, max 32" >&2; exit 1; }

# Anything not bare printable-ASCII is where a bad paste hides — show the bytes.
case "${ssid}" in
	" "*|*" "|*[!\ -~]*)
		echo "wifi-psk: ssid has leading/trailing space or non-printable bytes:"
		printf '%s' "${ssid}" | od -An -tx1c
		IFS= read -r -p "hash this ssid anyway? type yes: " ok
		[ "${ok}" = "yes" ] || { echo "wifi-psk: aborted" >&2; exit 1; }
		;;
esac

IFS= read -r -s -p "passphrase: " pass; echo
IFS= read -r -s -p "passphrase (again): " pass2; echo
[ "${pass}" = "${pass2}" ] || { echo "wifi-psk: passphrases do not match" >&2; exit 1; }

plen="$(nbytes "${pass}")"
[ "${plen}" -ge 8 ] && [ "${plen}" -le 63 ] \
	|| { echo "wifi-psk: passphrase is ${plen} bytes, must be 8..63" >&2; exit 1; }
case "${pass}" in
	*[!\ -~]*) echo "wifi-psk: passphrase must be printable ASCII" >&2; exit 1 ;;
esac

psk="$(derive "${ssid}" "${pass}")"

if [ -n "${VERIFY}" ]; then
	if [ "${psk}" = "${VERIFY}" ]; then
		echo "MATCH    ${psk}"
		exit 0
	fi
	echo "MISMATCH"
	echo "  given:    ${VERIFY}"
	echo "  computed: ${psk}"
	exit 1
fi

echo
echo "network={"
printf '    ssid="%s"\n' "${ssid}"
echo "    psk=${psk}"
[ -z "${PRIORITY}" ] || echo "    priority=${PRIORITY}"
echo "}"
