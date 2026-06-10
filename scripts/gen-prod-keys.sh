#!/usr/bin/env bash
# Generate the PROD RAUC signing CA + leaf cert + key into a directory OUTSIDE
# the repo (default ~/.shareframe-release-keys). The private key must never
# enter the repo or the image; only ca.cert.pem is copied into the prod config
# profile (configs/<profile>/overlay/etc/rauc/ca.cert.pem) as trust anchor.
#
# Builds then sign with:
#   SHAREFRAME_RELEASE_CERT=$KEYDIR/cert.pem \
#   SHAREFRAME_RELEASE_KEY=$KEYDIR/key.pem  scripts/make-release.sh --mode prod
set -euo pipefail

KEYDIR="${1:-$HOME/.shareframe-release-keys}"
mkdir -p "${KEYDIR}"
chmod 0700 "${KEYDIR}"

if [ -f "${KEYDIR}/key.pem" ]; then
	echo "Prod keys already present in ${KEYDIR}/. Refusing to overwrite."
	exit 0
fi

# CA (offline trust anchor, 20y)
openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
	-keyout "${KEYDIR}/ca.key.pem" -out "${KEYDIR}/ca.cert.pem" \
	-days 7300 -nodes \
	-subj "/CN=shareframe-release-ca"

# Leaf signing cert (10y)
openssl req -new -newkey ec:<(openssl ecparam -name prime256v1) \
	-keyout "${KEYDIR}/key.pem" -out "${KEYDIR}/cert.csr" \
	-nodes \
	-subj "/CN=shareframe-release-signer"
openssl x509 -req -in "${KEYDIR}/cert.csr" \
	-CA "${KEYDIR}/ca.cert.pem" -CAkey "${KEYDIR}/ca.key.pem" \
	-CAcreateserial -out "${KEYDIR}/cert.pem" -days 3650
rm -f "${KEYDIR}/cert.csr"
chmod 0600 "${KEYDIR}/key.pem" "${KEYDIR}/ca.key.pem"

echo "Prod keys in ${KEYDIR}/ (keep offline, back up ca.key.pem + key.pem):"
ls -l "${KEYDIR}"
echo
echo "Trust anchor for prod images: copy ${KEYDIR}/ca.cert.pem to"
echo "  configs/<profile>/overlay/etc/rauc/ca.cert.pem"
