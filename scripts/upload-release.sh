#!/usr/bin/env bash
# Hand the latest release to the server. The server has no upload API (releases
# are created in the Django admin), so this prints exactly what to enter and,
# if SHAREFRAME_UPLOAD_SSH is set (user@host:/path), scps the bundle there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/artifacts/deploy"
META="${OUT_DIR}/release.json"

[ -f "${META}" ] || { echo "release.json missing; run scripts/make-release.sh first" >&2; exit 1; }
get() { sed -n "s/.*\"$1\": *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "${META}" | head -1; }

FILE="$(get file)"
BUNDLE="${OUT_DIR}/${FILE}"
[ -f "${BUNDLE}" ] || { echo "bundle ${BUNDLE} missing" >&2; exit 1; }

if [ "$(get mode)" != "prod" ]; then
	echo "WARN: bundle was signed with DEV keys — prod boards will reject it." >&2
fi

if [ -n "${SHAREFRAME_UPLOAD_SSH:-}" ]; then
	echo "=== scp ${FILE} -> ${SHAREFRAME_UPLOAD_SSH}"
	scp "${BUNDLE}" "${SHAREFRAME_UPLOAD_SSH}/"
fi

cat <<EOF

Django admin -> Frame updates -> Releases -> Add:
  version:     $(get version)
  criticality: $(get criticality)
  file:        ${BUNDLE}
  checksum:    $(get sha256)
  notes:       see ${META}
  groups:      assign the rollout groups, set is_active
EOF
