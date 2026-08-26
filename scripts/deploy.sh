#!/usr/bin/env bash
# Interactive runner over the build -> release -> provision chain: prompts for
# whatever a flag did not supply, prints the config behind every pick, shows the
# exact commands, then runs automation.sh / provision-device.sh. No build logic
# of its own.
# usage: deploy.sh [--update|--sdcard|--full|--steps build,release,image]
#        [--config DIR] [--release NAME] [--version X.Y.Z] [--device NAME]
#        [--from LABEL] [--mode dev|prod] [--yes] [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

HOST_BIN="build/buildroot/output/host/bin"
DEV_KEYS="br2-external/package/shareframe-rauc/files"

STEPS="" CONFIG_DIR="" RELEASE_DIR="" VERSION="" DEVICE_DIR="" FROM="" MODE=""
YES=0 DRY=0 VERSION_GIVEN=0 FROM_GIVEN=0

die() { echo "deploy: $*" >&2; exit 1; }

usage() {
	sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
	cat <<'USAGE'

steps    build     ./automation.sh build <config> [--release <rel>|--version X.Y.Z]
         release   ./automation.sh release <mode> [--release <rel>] --from <label>
         image     scripts/provision-device.sh --device <dev> --from <label>

flows    --update  build,release      --sdcard  build,image      --full  all three
USAGE
}

# ---------------------------------------------------------------- small helpers

# read one var out of a config.env; subshell so nothing leaks into the wizard
env_get() {
	local file="$1" var="$2"
	[ -f "${file}" ] || return 0
	# shellcheck disable=SC1090,SC1091
	( set -a; . "${file}" >/dev/null 2>&1 || exit 0; set +a; printf '%s' "${!var-}" )
}

json_str() { sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null; }

or() { [ -n "$1" ] && printf '%s' "$1" || printf '%s' "$2"; }

has_step() { case " ${STEPS} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

field() { printf '  %-16s %s\n' "$1" "$2"; }

need_tty() { [ -t 0 ] || die "$1 not given and no terminal to ask on"; }

# numbered menu over MENU_LABELS; sets PICK_IDX (0-based)
PICK_IDX=0
menu_pick() {
	local prompt="$1" i choice
	[ "${#MENU_LABELS[@]}" -gt 0 ] || die "nothing to choose for ${prompt}"
	echo
	echo "${prompt}"
	for i in "${!MENU_LABELS[@]}"; do
		printf '  %2d) %s\n' "$((i + 1))" "${MENU_LABELS[$i]}"
	done
	while :; do
		read -r -p "> " choice || die "aborted"
		case "${choice}" in
			''|*[!0-9]*) ;;
			*)
				if [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#MENU_LABELS[@]}" ]; then
					PICK_IDX=$((choice - 1)); return 0
				fi
				;;
		esac
		echo "pick 1..${#MENU_LABELS[@]}"
	done
}

validate_version() {
	[[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version '$1' — expected X.Y.Z"
}

# ------------------------------------------------------------- what a pick holds

show_config() {
	local d="$1" f="$1/config.env" v ca
	echo
	echo "config: ${d}"
	v="$(env_get "${f}" SHAREFRAME_CONFIG_LABEL)"
	field label "$(or "${v}" "$(basename "${d}") (from dir name)")"
	field "build mode" "$(or "$(env_get "${f}" SHAREFRAME_BUILD_MODE)" "prod (default)")"
	field profile "$(or "$(env_get "${f}" SHAREFRAME_PROFILE)" "prod (default)")"
	field epd "$(or "$(env_get "${f}" SHAREFRAME_EPD)" "OFF")"
	[ -n "$(env_get "${f}" SHAREFRAME_ROOT_PASSWD)" ] && field "root passwd" "set" || field "root passwd" "UNSET"
	ca="${d}/overlay/etc/rauc/ca.cert.pem"
	if [ ! -f "${ca}" ]; then
		field "rauc ca cert" "MISSING (${ca})"
	elif grep -q "BEGIN CERTIFICATE" "${ca}"; then
		field "rauc ca cert" "ok"
	else
		field "rauc ca cert" "NOT A PEM CERTIFICATE (${ca})"
	fi
	v="$(env_get "${f}" SHAREFRAME_BOARD_OVERRIDE_SRCDIR)"
	[ -n "${v}" ] && field "board override" "${v}"
	v="$(env_get "${f}" SHAREFRAME_DASHBOARD_FRONTEND_OVERRIDE_SRCDIR)"
	[ -n "${v}" ] && field "dash override" "${v}"
	return 0
}

show_release() {
	local d="$1" f="$1/config.env" hooks=""
	echo
	echo "release: ${d}"
	field version "$(or "$(env_get "${f}" SHAREFRAME_VERSION)" "UNSET")"
	field criticality "$(or "$(env_get "${f}" SHAREFRAME_CRITICALITY)" "Minor (default)")"
	[ -f "${d}/pre.sh" ] && hooks="pre.sh"
	[ -f "${d}/post.sh" ] && hooks="${hooks:+${hooks} }post.sh"
	field hooks "$(or "${hooks}" "none")"
	if [ -f "${d}/notes.md" ]; then
		field notes "$(head -n1 "${d}/notes.md")"
	else
		field notes "none"
	fi
	return 0
}

show_build() {
	local d="$1" j="$1/build.json" bundles b
	echo
	echo "build: ${d}"
	field version "$(json_str "${j}" version)"
	field mode "$(json_str "${j}" build_mode)"
	field profile "$(json_str "${j}" profile)"
	field epd "$(json_str "${j}" epd)"
	field "built at" "$(json_str "${j}" built_at) ($(json_str "${j}" os_sha))"
	[ -f "${d}/sdcard.img" ] && field sdcard.img "present" || field sdcard.img "MISSING (no image step possible)"
	bundles=""
	for b in "${d}"/releases/*.raucb; do
		[ -f "${b}" ] || continue
		bundles="${bundles}$(basename "${b}") "
	done
	field releases "$(or "${bundles}" "none yet")"
	return 0
}

show_device() {
	local d="$1" files
	echo
	echo "device: ${d}"
	files="$( [ -d "${d}/factory" ] && cd "${d}/factory" && ls -1A | tr '\n' ' ' || true)"
	field "factory files" "$(or "${files}" "NONE")"
	[ -f "${d}/factory/rootpw" ] && field "root passwd" "from factory/rootpw" || field "root passwd" "falls back to the baked one"
	return 0
}

release_keys() {
	# same resolution automation.sh:436 and make-release.sh:56 use
	local keydir="${SHAREFRAME_RELEASE_KEYDIR:-${HOME}/.shareframe-release-keys}"
	if [ "$1" = prod ]; then
		CERT="${SHAREFRAME_RELEASE_CERT:-${keydir}/cert.pem}"
		KEY="${SHAREFRAME_RELEASE_KEY:-${keydir}/key.pem}"
	else
		CERT="${SHAREFRAME_RELEASE_CERT:-${DEV_KEYS}/cert.pem}"
		KEY="${SHAREFRAME_RELEASE_KEY:-${DEV_KEYS}/key.pem}"
	fi
}

show_mode() {
	release_keys "$1"
	echo
	echo "mode: $1"
	field cert "${CERT} $([ -f "${CERT}" ] && echo ok || echo MISSING)"
	field key "${KEY} $([ -f "${KEY}" ] && echo ok || echo MISSING)"
	[ "$1" = prod ] && field boards "prod boards accept prod-signed bundles only" \
		|| field boards "dev-signed — prod boards reject these"
	return 0
}

# ------------------------------------------------------------------- arg parsing

while [ $# -gt 0 ]; do
	case "$1" in
		--steps)   STEPS="$(printf '%s' "$2" | tr ',' ' ')"; shift 2 ;;
		--update)  STEPS="build release"; shift ;;
		--sdcard)  STEPS="build image"; shift ;;
		--full)    STEPS="build release image"; shift ;;
		--config)  CONFIG_DIR="$2"; shift 2 ;;
		--release) RELEASE_DIR="$2"; shift 2 ;;
		--version) VERSION="$2"; VERSION_GIVEN=1; shift 2 ;;
		--device)  DEVICE_DIR="$2"; shift 2 ;;
		--from)    FROM="$2"; FROM_GIVEN=1; shift 2 ;;
		--mode)    MODE="$2"; shift 2 ;;
		--yes|-y)  YES=1; shift ;;
		--dry-run) DRY=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "deploy: unknown arg $1" >&2; usage >&2; exit 1 ;;
	esac
done

for s in ${STEPS}; do
	case "${s}" in build|release|image) ;; *) die "unknown step '${s}' (build, release, image)" ;; esac
done

# bare names resolve like the existing scripts do
[ -n "${CONFIG_DIR}" ] && CONFIG_DIR="${CONFIG_DIR%/}"
[ -n "${RELEASE_DIR}" ] && { RELEASE_DIR="${RELEASE_DIR%/}"; [ -d "${RELEASE_DIR}" ] || RELEASE_DIR="releases/${RELEASE_DIR}"; }
[ -n "${DEVICE_DIR}" ] && { DEVICE_DIR="${DEVICE_DIR%/}"; [ -d "${DEVICE_DIR}" ] || DEVICE_DIR="configs/per-device/${DEVICE_DIR}"; }
[ -n "${VERSION}" ] && validate_version "${VERSION}"
[ -n "${MODE}" ] && case "${MODE}" in dev|prod) ;; *) die "mode must be dev or prod" ;; esac

# ------------------------------------------------------------------- step choice

if [ -z "${STEPS}" ]; then
	need_tty "--steps"
	MENU_LABELS=(
		"fleet update      build + sign an OTA bundle"
		"sd card image     build + provision a device image"
		"full              build + bundle + device image"
		"release only      sign a build that already exists"
		"image only        provision from a build that already exists"
		"build only        just build"
	)
	menu_pick "what do you want to do?"
	case "${PICK_IDX}" in
		0) STEPS="build release" ;;
		1) STEPS="build image" ;;
		2) STEPS="build release image" ;;
		3) STEPS="release" ;;
		4) STEPS="image" ;;
		5) STEPS="build" ;;
	esac
fi

has_step build || has_step release || has_step image || die "no steps selected"
has_step build && [ "${FROM_GIVEN}" = 1 ] && die "--from and the build step are mutually exclusive (the build defines the label)"

# --------------------------------------------------------------- config + version

if has_step build; then
	if [ -z "${CONFIG_DIR}" ]; then
		need_tty "--config"
		MENU_LABELS=(); CFG=()
		for d in configs/fleet/*/ configs/per-device/*/; do
			[ -f "${d}config.env" ] || continue
			d="${d%/}"
			ann="mode $(or "$(env_get "${d}/config.env" SHAREFRAME_BUILD_MODE)" prod)"
			[ -f "${d}/overlay/etc/rauc/ca.cert.pem" ] && ann="${ann}, ca" || ann="${ann}, NO ca"
			[ "$(basename "${d}")" = example ] && ann="${ann}, TEMPLATE"
			CFG+=("${d}")
			MENU_LABELS+=("$(printf '%-40s %s' "${d}" "${ann}")")
		done
		menu_pick "build config:"
		CONFIG_DIR="${CFG[${PICK_IDX}]}"
	fi
	[ -d "${CONFIG_DIR}" ] || die "config dir '${CONFIG_DIR}' not found"
	[ -f "${CONFIG_DIR}/config.env" ] || die "'${CONFIG_DIR}/config.env' not found"
	show_config "${CONFIG_DIR}"
fi

# a release dir is the version source for build, and carries notes/hooks for release
pick_release_dir() {
	MENU_LABELS=(); REL=()
	for d in releases/*/; do
		d="${d%/}"
		[ -f "${d}/config.env" ] || continue
		REL+=("${d}")
		MENU_LABELS+=("$(printf '%-24s version %-10s %s' "${d}" \
			"$(or "$(env_get "${d}/config.env" SHAREFRAME_VERSION)" -)" \
			"$(or "$(env_get "${d}/config.env" SHAREFRAME_CRITICALITY)" Minor)")")
	done
}

# an image-only run needs no release config: its version comes from build.json
if { has_step build || has_step release; } && [ -z "${RELEASE_DIR}" ] && [ "${VERSION_GIVEN}" = 0 ]; then
	need_tty "--release / --version"
	pick_release_dir
	if has_step build; then
		MENU_LABELS+=("enter a version by hand" "no version (git SHA — QEMU/dev only)")
	else
		MENU_LABELS+=("none (criticality Minor, no notes, no hooks)")
	fi
	menu_pick "release config:"
	if [ "${PICK_IDX}" -lt "${#REL[@]}" ]; then
		RELEASE_DIR="${REL[${PICK_IDX}]}"
	elif has_step build && [ "${PICK_IDX}" = "${#REL[@]}" ]; then
		read -r -p "version (X.Y.Z): " VERSION
		validate_version "${VERSION}"; VERSION_GIVEN=1
	fi
fi

if [ -n "${RELEASE_DIR}" ]; then
	[ -d "${RELEASE_DIR}" ] || die "release dir '${RELEASE_DIR}' not found"
	[ -f "${RELEASE_DIR}/config.env" ] || die "'${RELEASE_DIR}/config.env' not found"
	show_release "${RELEASE_DIR}"
	REL_VERSION="$(env_get "${RELEASE_DIR}/config.env" SHAREFRAME_VERSION)"
	if [ "${VERSION_GIVEN}" = 1 ] && [ -n "${REL_VERSION}" ] && [ "${REL_VERSION}" != "${VERSION}" ]; then
		die "--version ${VERSION} contradicts ${RELEASE_DIR}/config.env (${REL_VERSION})"
	fi
	[ -n "${REL_VERSION}" ] && VERSION="${REL_VERSION}"
	if has_step build && [ -z "${VERSION}" ]; then
		die "${RELEASE_DIR}/config.env sets no SHAREFRAME_VERSION"
	fi
fi
[ -n "${VERSION}" ] && validate_version "${VERSION}"

# ------------------------------------------------------------------ stored build

if has_step build; then
	label="$(env_get "${CONFIG_DIR}/config.env" SHAREFRAME_CONFIG_LABEL)"
	label="$(or "${label}" "$(basename "${CONFIG_DIR}")")"
	FROM="${label}-$(or "${VERSION}" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)")"
	BUILD_DIR="artifacts/builds/${FROM}"
	BUILD_IS_NEW=1
elif has_step release || has_step image; then
	if [ -z "${FROM}" ]; then
		need_tty "--from"
		MENU_LABELS=(); BLD=()
		latest="$(readlink artifacts/builds/latest 2>/dev/null || true)"
		for d in artifacts/builds/*/; do
			d="${d%/}"
			[ -L "${d}" ] && continue
			[ -f "${d}/build.json" ] || continue
			name="$(basename "${d}")"
			ann="$(json_str "${d}/build.json" build_mode), $(json_str "${d}/build.json" built_at)"
			[ "${name}" = "${latest}" ] && ann="${ann}  <- latest"
			BLD+=("${name}")
			MENU_LABELS+=("$(printf '%-34s %s' "${name}" "${ann}")")
		done
		menu_pick "stored build:"
		FROM="${BLD[${PICK_IDX}]}"
	fi
	BUILD_DIR="${FROM}"
	[ -d "${BUILD_DIR}" ] || BUILD_DIR="artifacts/builds/${FROM}"
	[ -d "${BUILD_DIR}" ] || die "build '${FROM}' not found in artifacts/builds/"
	[ -f "${BUILD_DIR}/build.json" ] || die "${BUILD_DIR}/build.json missing"
	FROM="$(basename "${BUILD_DIR}")"
	BUILD_IS_NEW=0
	show_build "${BUILD_DIR}"
	BUILD_VERSION="$(json_str "${BUILD_DIR}/build.json" version)"
	BUILD_MODE="$(json_str "${BUILD_DIR}/build.json" build_mode)"
	[ -n "${VERSION}" ] && [ "${VERSION}" != "${BUILD_VERSION}" ] && \
		die "release version ${VERSION} != build version ${BUILD_VERSION} (make-release refuses this)"
	VERSION="${BUILD_VERSION}"
fi

# -------------------------------------------------------------------- mode/device

if has_step release; then
	if [ -z "${MODE}" ]; then
		need_tty "--mode"
		MENU_LABELS=("prod   signed with the offline keys — what fielded boards accept" \
			"dev    signed with the repo dev keys — prod boards reject it")
		menu_pick "signing mode:"
		[ "${PICK_IDX}" = 0 ] && MODE=prod || MODE=dev
	fi
	show_mode "${MODE}"
fi

if has_step image; then
	if [ -z "${DEVICE_DIR}" ]; then
		need_tty "--device"
		MENU_LABELS=(); DEV=()
		for d in configs/per-device/*/; do
			d="${d%/}"
			[ -f "${d}/factory/.env.secrets.toml" ] || continue
			DEV+=("${d}")
			ann="$(cd "${d}/factory" && ls -1A | tr '\n' ' ' || true)"
			[ "$(basename "${d}")" = example ] && ann="TEMPLATE — ${ann}"
			MENU_LABELS+=("$(printf '%-34s %s' "$(basename "${d}")" "${ann}")")
		done
		menu_pick "device:"
		DEVICE_DIR="${DEV[${PICK_IDX}]}"
	fi
	[ -d "${DEVICE_DIR}" ] || die "device dir '${DEVICE_DIR}' not found"
	[ -f "${DEVICE_DIR}/factory/.env.secrets.toml" ] || \
		die "${DEVICE_DIR}/factory/.env.secrets.toml missing — a device needs an identity"
	show_device "${DEVICE_DIR}"
fi

# ---------------------------------------------------------------------- preflight

if has_step build; then
	bmode="$(or "$(env_get "${CONFIG_DIR}/config.env" SHAREFRAME_BUILD_MODE)" prod)"
	if [ "${bmode}" = prod ]; then
		[ "$(or "$(env_get "${CONFIG_DIR}/config.env" SHAREFRAME_PROFILE)" prod)" = prod ] || \
			die "prod build needs SHAREFRAME_PROFILE=prod in ${CONFIG_DIR}/config.env"
		[ -n "$(env_get "${CONFIG_DIR}/config.env" SHAREFRAME_ROOT_PASSWD)" ] || \
			die "prod build needs SHAREFRAME_ROOT_PASSWD in ${CONFIG_DIR}/config.env"
		ca="${CONFIG_DIR}/overlay/etc/rauc/ca.cert.pem"
		[ -f "${ca}" ] || die "prod build needs the CA cert at ${ca}"
		grep -q "BEGIN CERTIFICATE" "${ca}" || die "${ca} is not a PEM certificate"
	fi
	# automation.sh:141 refuses to overwrite a build that already carries bundles
	[ -z "$(ls -A "artifacts/builds/${FROM}/releases" 2>/dev/null)" ] || \
		die "artifacts/builds/${FROM} already has signed releases — bump the version, or drop the build step (--steps release --from ${FROM})"
	BUILD_MODE="${bmode}"
fi

if has_step release; then
	[ "${MODE}" = prod ] && [ "${BUILD_MODE}" != prod ] && \
		die "a prod release needs a prod-mode build ('${FROM}' is build_mode=${BUILD_MODE})"
	release_keys "${MODE}"
	[ -f "${CERT}" ] || die "signing cert missing: ${CERT}"
	[ -f "${KEY}" ] || die "signing key missing: ${KEY}"
	if ! has_step build && [ ! -x "${HOST_BIN}/rauc" ] && ! command -v rauc >/dev/null; then
		die "no rauc — build the buildroot host tree first, or install rauc"
	fi
fi

if has_step image; then
	if ! has_step build; then
		[ -f "${BUILD_DIR}/sdcard.img" ] || die "${BUILD_DIR}/sdcard.img not found — that build carries no image"
		[ -x "${HOST_BIN}/mcopy" ] || command -v mcopy >/dev/null || die "mtools (mcopy) not found"
	fi
fi

# ------------------------------------------------------------------------ summary

CMD_BUILD=(./automation.sh build "${CONFIG_DIR}")
if [ -n "${RELEASE_DIR}" ]; then
	CMD_BUILD+=(--release "${RELEASE_DIR}")
elif [ -n "${VERSION}" ]; then
	CMD_BUILD+=(--version "${VERSION}")
fi
CMD_RELEASE=(./automation.sh release "${MODE}")
[ -n "${RELEASE_DIR}" ] && CMD_RELEASE+=(--release "${RELEASE_DIR}")
CMD_RELEASE+=(--from "${FROM}")
CMD_IMAGE=(scripts/provision-device.sh --device "${DEVICE_DIR}" --from "${FROM}")

echo
echo "================================ summary ================================"
field steps "$(printf '%s' "${STEPS}" | sed 's/ / -> /g')"
has_step build && field config "${CONFIG_DIR}"
[ -n "${RELEASE_DIR}" ] && field release "${RELEASE_DIR}"
field version "$(or "${VERSION}" "git SHA (no version baked)")"
has_step release && field mode "${MODE}"
has_step image && field device "$(basename "${DEVICE_DIR}")"
field "build dir" "artifacts/builds/${FROM}$([ "${BUILD_IS_NEW}" = 1 ] && echo '  (new)' || echo '  (existing)')"
has_step release && field bundle "artifacts/builds/${FROM}/releases/shareframe-${VERSION}-${MODE}.raucb"
has_step image && field image "artifacts/flash/$(basename "${DEVICE_DIR}")-${VERSION}.img"
echo
n=0
for s in ${STEPS}; do
	n=$((n + 1))
	case "${s}" in
		build)   printf '  %d) %s\n' "${n}" "${CMD_BUILD[*]}" ;;
		release) printf '  %d) %s\n' "${n}" "${CMD_RELEASE[*]}" ;;
		image)   printf '  %d) %s\n' "${n}" "${CMD_IMAGE[*]}" ;;
	esac
done
echo "========================================================================="

[ "${DRY}" = 1 ] && { echo; echo "dry run — nothing executed"; exit 0; }

if [ "${YES}" != 1 ]; then
	need_tty "confirmation"
	echo
	read -r -p "run? [y/N] " ans
	case "${ans}" in y|Y|yes) ;; *) die "aborted" ;; esac
fi

# ----------------------------------------------------------------------- run them

run_step() {
	local name="$1"; shift
	echo
	echo "############################ ${name} ############################"
	printf '+ %s\n' "$*"
	"$@" || die "${name} failed"
}

for s in ${STEPS}; do
	case "${s}" in
		build)   run_step build "${CMD_BUILD[@]}" ;;
		release) run_step release "${CMD_RELEASE[@]}" ;;
		image)   run_step image "${CMD_IMAGE[@]}" ;;
	esac
done

echo
echo "=============================== done ===================================="
has_step build && field build "artifacts/builds/${FROM}"
if has_step release; then
	b="artifacts/builds/${FROM}/releases/shareframe-${VERSION}-${MODE}.raucb"
	field bundle "${b}"
	[ -f "${b}.sha256" ] && field sha256 "$(cut -d' ' -f1 "${b}.sha256")  -> server 'checksum' field"
fi
if has_step image; then
	img="artifacts/flash/$(basename "${DEVICE_DIR}")-${VERSION}.img"
	field image "${img}"
	echo
	echo "flash: dd if=${img} of=/dev/sdX bs=4M conv=fsync status=progress"
fi
