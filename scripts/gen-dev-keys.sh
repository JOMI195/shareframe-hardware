#!/usr/bin/env bash
# Generate RAUC dev signing CA + leaf cert + key. Run once; files are gitignored.
# Drops:
#   br2-external/package/shareframe-rauc/files/ca.cert.pem
#   br2-external/package/shareframe-rauc/files/cert.pem
#   br2-external/package/shareframe-rauc/files/key.pem
# The CA cert becomes /etc/rauc/ca.cert.pem on the target (trust anchor).
# cert.pem + key.pem stay host-side; used by scripts/make-bundle.sh.
set -euo pipefail

OUT=br2-external/package/shareframe-rauc/files
mkdir -p "${OUT}"

if [ -f "${OUT}/ca.cert.pem" ] && [ -f "${OUT}/cert.pem" ] && [ -f "${OUT}/key.pem" ]; then
	echo "Dev keys already present in ${OUT}/. Refusing to overwrite."
	echo "Delete them first if you really want to regenerate."
	exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# 1. CA (self-signed)
openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
	-keyout "${work}/ca.key.pem" -out "${work}/ca.cert.pem" \
	-days 7300 -nodes \
	-subj "/CN=shareframe-dev-ca"

# 2. Leaf signing cert (signed by CA)
openssl req -new -newkey ec:<(openssl ecparam -name prime256v1) \
	-keyout "${work}/key.pem" -out "${work}/cert.csr" \
	-nodes \
	-subj "/CN=shareframe-dev-signer"

openssl x509 -req -in "${work}/cert.csr" \
	-CA "${work}/ca.cert.pem" -CAkey "${work}/ca.key.pem" \
	-CAcreateserial -out "${work}/cert.pem" -days 3650

install -m 0644 "${work}/ca.cert.pem" "${OUT}/ca.cert.pem"
install -m 0644 "${work}/cert.pem"    "${OUT}/cert.pem"
install -m 0600 "${work}/key.pem"     "${OUT}/key.pem"

echo "Dev keys written to ${OUT}/:"
ls -l "${OUT}/ca.cert.pem" "${OUT}/cert.pem" "${OUT}/key.pem"
