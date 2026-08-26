#!/usr/bin/env bash
set -xe

BUILDROOT_VERSION="2026.02.2"
BUILDROOT_BASE_URL="https://buildroot.org/downloads/"

TOOLCHAIN_NAME="armv6-eabihf--musl--bleeding-edge-2025.08-1"
TOOLCHAIN_BASE_URL="https://toolchains.bootlin.com/downloads/releases/toolchains/armv6-eabihf/tarballs/"

PI4B="${PI4B:-base@shareframe-base}"
PI4B_SERIAL="${PI4B_SERIAL:-/dev/ttyACM0}"   # Pi Debug Probe on the 4B = CDC-ACM

[[ -d artifacts ]] || mkdir artifacts
[[ -d build ]] || mkdir build

validate_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "Invalid version format '$1' — expected X.Y.Z" >&2; return 1; }
}

# resolve a release name (or path) to its dir; bare names live under releases/
resolve_release_dir() {
    local r="${1%/}"
    [ -d "$r" ] && { printf '%s' "$r"; return 0; }
    [ -d "releases/$r" ] && { printf '%s' "releases/$r"; return 0; }
    echo "release '$1' not found (looked at '$1' and 'releases/$1')" >&2
    return 1
}

# download given uri and return name of downloaded file
function get_uri_prefetch() {
    local dir="${2:-.}"
    local filename
    filename="$dir/$(basename "$1")"
    wget -nv -P "$dir" "$1"
    printf "%s" "$filename"
}

# verify signature, fetch missing key from keyserver on demand
function gpg_verify_fetch() {
    local sigfile="$1"
    local status missing
    status="$(gpg --status-fd 1 --verify "$sigfile" 2>/dev/null || true)"
    missing="$(printf '%s\n' "$status" | awk '/^\[GNUPG:\] NO_PUBKEY/ {print $3; exit}')"
    if [ -n "$missing" ]; then
        gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$missing"
    fi
    gpg --verify "$sigfile"
}

# download + verify + extract a source tarball into src_dir
function prepare_src() {
    local src_uri="$1"
    local sig_uri="$2"
    local src_dir="$3"
    local marker="${4:-Makefile}"

    local download_dir
    download_dir="$(dirname "$src_dir")"

    if [ ! -f "$src_dir/$marker" ]; then
        mkdir -p "$src_dir"
        local tarball sigfile

        tarball="$(get_uri_prefetch "$src_uri" "$download_dir")"
        sigfile="$(get_uri_prefetch "$sig_uri" "$download_dir")"

        case "$sig_uri" in
            *.sign)
                gpg_verify_fetch "$sigfile"
                ( cd "$download_dir" && grep '^SHA256' "$(basename "$sigfile")" | awk '{print $2 "  " $3}' | sha256sum -c - )
                ;;
            *.sha256)
                ( cd "$download_dir" && sha256sum -c "$(basename "$sigfile")" )
                ;;
            *)
                echo "prepare_src: unknown sig format: $sig_uri" >&2
                return 1
                ;;
        esac

        tar -C "$src_dir" --strip-components=1 -xavf "$tarball" || { rm -Rf "$src_dir"; return 1; }
    fi
}

function toolchain() {
    echo "=== Download, verify, extract toolchain ==="
    local src_uri="$TOOLCHAIN_BASE_URL/$TOOLCHAIN_NAME.tar.xz"
    local sig_uri="$TOOLCHAIN_BASE_URL/$TOOLCHAIN_NAME.sha256"
    local src_dir="build/toolchain"
    local marker="bin/arm-buildroot-linux-musleabihf-gcc"

    prepare_src \
      "$TOOLCHAIN_BASE_URL/$TOOLCHAIN_NAME.tar.xz" \
      "$TOOLCHAIN_BASE_URL/$TOOLCHAIN_NAME.sha256" \
      "$src_dir" \
      "$marker"
}

function buildroot() {
    local config="buildroot-rpi0w"
    local config_dir="${1:-}"

    # Build flavor (default prod); dev adds verbose firmware UART logging.
    export SHAREFRAME_BUILD_MODE="${SHAREFRAME_BUILD_MODE:-prod}"
    case "${SHAREFRAME_BUILD_MODE}" in
        dev|prod) ;;
        *) echo "buildroot: invalid SHAREFRAME_BUILD_MODE='${SHAREFRAME_BUILD_MODE}' (use dev or prod)" >&2; return 1 ;;
    esac
    echo "=== SHAREFRAME_BUILD_MODE=${SHAREFRAME_BUILD_MODE} ==="

    # Config profile (default prod); selects which config overlay the app merges.
    export SHAREFRAME_PROFILE="${SHAREFRAME_PROFILE:-prod}"
    case "${SHAREFRAME_PROFILE}" in
        dev|prod|prod.local) ;;
        *) echo "buildroot: invalid SHAREFRAME_PROFILE='${SHAREFRAME_PROFILE}' (use dev, prod, prod.local)" >&2; return 1 ;;
    esac
    echo "=== SHAREFRAME_PROFILE=${SHAREFRAME_PROFILE} ==="

    # A prod image must be deployable: matching profile, a trust anchor to verify
    # updates, and a real root login. Fail fast before the long build.
    if [ "${SHAREFRAME_BUILD_MODE}" = prod ]; then
        [ "${SHAREFRAME_PROFILE}" = prod ] || {
            echo "buildroot: prod build requires SHAREFRAME_PROFILE=prod (got '${SHAREFRAME_PROFILE}')" >&2; return 1; }
        [ -n "${SHAREFRAME_ROOT_PASSWD:-}" ] || {
            echo "buildroot: prod build requires SHAREFRAME_ROOT_PASSWD (set it in config.env)" >&2; return 1; }
        [ -n "$config_dir" ] && [ -f "$config_dir/overlay/etc/rauc/ca.cert.pem" ] || {
            echo "buildroot: prod build requires the CA cert at $config_dir/overlay/etc/rauc/ca.cert.pem" >&2; return 1; }
        grep -q "BEGIN CERTIFICATE" "$config_dir/overlay/etc/rauc/ca.cert.pem" || {
            echo "buildroot: $config_dir/overlay/etc/rauc/ca.cert.pem is not a PEM certificate" >&2; return 1; }
    fi

    # Build identity, resolved up front so the rebuild guard runs before the long
    # build. The staging step below reuses these.
    local version="${SHAREFRAME_VERSION:-${OS_SHA:-unknown}}"
    local label="${SHAREFRAME_CONFIG_LABEL:-default}-${version}"
    local dir="artifacts/builds/$label"

    # Never silently destroy a build that already carries signed bundles; bump the
    # version (versions are unique) or remove the dir on purpose.
    [ -z "$(ls -A "$dir/releases" 2>/dev/null)" ] || {
        echo "buildroot: $dir already has signed releases — bump the version or 'rm -rf $dir' to rebuild" >&2; return 1; }

    echo "=== Download and extract Buildroot ==="
    local src_uri="$BUILDROOT_BASE_URL/buildroot-$BUILDROOT_VERSION.tar.gz"
    local sig_uri="$BUILDROOT_BASE_URL/buildroot-$BUILDROOT_VERSION.tar.gz.sign"
    local src_dir="build/buildroot"

    prepare_src \
      "$src_uri" \
      "$sig_uri" \
      "$src_dir"

    echo "=== Configure Buildroot ==="
    make -C "$src_dir" \
      BR2_DEFCONFIG="$(realpath "br2-external/configs/${config}.conf")" \
      BR2_EXTERNAL="$(realpath br2-external)" \
      defconfig

    # Reset local.mk each build so no override leaks from a previous build.
    : > "$src_dir/local.mk"
    if [ -n "$config_dir" ] && [ -d "$config_dir/overlay" ]; then
        # Last-wins: tracked overlay first, config overlay layered on top.
        printf 'BR2_ROOTFS_OVERLAY="../../br2-external/overlay %s"\n' \
            "$(realpath "$config_dir/overlay")" >> "$src_dir/.config"
        echo "=== Second overlay: $(realpath "$config_dir/overlay") ==="
    fi
    # Baked into rootfs /etc/shadow (not /data); every update overwrites it.
    if [ -n "${SHAREFRAME_ROOT_PASSWD:-}" ]; then
        printf 'BR2_TARGET_GENERIC_ROOT_PASSWD="%s"\n' "$SHAREFRAME_ROOT_PASSWD" >> "$src_dir/.config"
        echo "=== Root password: set from config ==="
    fi
    if [ -n "${SHAREFRAME_BOARD_OVERRIDE_SRCDIR:-}" ]; then
        printf 'SHAREFRAME_BOARD_OVERRIDE_SRCDIR = %s\n' \
            "$SHAREFRAME_BOARD_OVERRIDE_SRCDIR" >> "$src_dir/local.mk"
        echo "=== Override shareframe-board: $SHAREFRAME_BOARD_OVERRIDE_SRCDIR ==="
    fi
    if [ -n "${SHAREFRAME_DASHBOARD_FRONTEND_OVERRIDE_SRCDIR:-}" ]; then
        printf 'SHAREFRAME_DASHBOARD_FRONTEND_OVERRIDE_SRCDIR = %s\n' \
            "$SHAREFRAME_DASHBOARD_FRONTEND_OVERRIDE_SRCDIR" >> "$src_dir/local.mk"
        echo "=== Override dashboard-frontend: $SHAREFRAME_DASHBOARD_FRONTEND_OVERRIDE_SRCDIR ==="
    fi

    make -C "$src_dir" olddefconfig

    echo "=== Build Buildroot ==="
    # Drop stale config overlays before reinstall
    rm -f "$src_dir"/output/target/etc/shareframe/config.*.toml
    make -C "$src_dir" rpi-firmware-dirclean
    make -C "$src_dir" shareframe-init-dirclean
    make -C "$src_dir" linux-reconfigure
    for mk in br2-external/modules/*/*.mk br2-external/package/*/*.mk; do
        [ -e "$mk" ] || continue
        grep -qF 'eval $(host-' "$mk" && continue
        make -C "$src_dir" "$(basename "$mk" .mk)-reconfigure"
    done

    make -C "$src_dir" -j"$(nproc)"

    echo "=== Extract generated files ==="
    local img="$src_dir/output/images"

    # Self-contained per build; release reads here, not the live tree, so a later
    # build can't clobber an earlier build's release inputs.
    rm -rf "$dir"
    mkdir -p "$dir/qemu"

    # Release inputs.
    cp "$img/rootfs.squashfs" "$dir/rootfs.squashfs"
    tar -C "$img/bootslot-tree" -cf "$dir/boot.tar" .

    # Flash image (one dd writes all partitions).
    if [ -f "$img/sdcard.img" ]; then
        cp "$img/sdcard.img" "$dir/sdcard.img"
    else
        echo "WARN: sdcard.img not found — post-image.sh or genimage failed?"
    fi

    # QEMU / debugging bits.
    cp "$img/zImage"                  "$dir/qemu/"
    cp "$img/bcm2835-rpi-zero-w.dtb"  "$dir/qemu/"
    [ -f "$img/spi0-spidev.dtbo" ] && cp "$img/spi0-spidev.dtbo" "$dir/qemu/"
    cp "$img/initramfs.cpio.gz"       "$dir/qemu/"

    # Manifest: release reads version and mode from here.
    cat > "$dir/build.json" <<EOF
{
  "label": "${label}",
  "config": "${SHAREFRAME_CONFIG_LABEL:-default}",
  "version": "${version}",
  "os_sha": "${OS_SHA:-unknown}",
  "app_sha": "${APP_SHA:-unknown}",
  "build_mode": "${SHAREFRAME_BUILD_MODE:-prod}",
  "profile": "${SHAREFRAME_PROFILE:-prod}",
  "epd": "${SHAREFRAME_EPD:-OFF}",
  "built_at": "$(date --iso-8601=seconds)",
  "built_by": "$(whoami)@$(hostname)"
}
EOF

    ln -sfn "$label" artifacts/builds/latest

    echo "=== Inspect (${label}) ==="
    file "$(realpath "$dir/qemu/zImage")"
    file "$(realpath "$dir/rootfs.squashfs")"
    [ -f "$dir/sdcard.img" ] && file "$(realpath "$dir/sdcard.img")"
}

function qemu_rpi0() {
    # Headless boot to BusyBox login; no hardware. usb0/SSH untestable in QEMU
    # ("can't find device usb0" is normal). Console on the mini-UART (ttyS1) as on
    # real hardware; the second -serial puts it on stdio. initcall_blacklist skips
    # the BCM2835 power/watchdog blocks QEMU doesn't model (else Oops/reboot loop).
    qemu-system-arm \
        -M raspi0 \
        -nographic \
        -serial null -serial mon:stdio \
        -kernel artifacts/builds/latest/qemu/zImage \
        -dtb artifacts/builds/latest/qemu/bcm2835-rpi-zero-w.dtb \
        -initrd artifacts/builds/latest/qemu/initramfs.cpio.gz \
        -append "earlycon=uart8250,mmio32,0x20215040 console=ttyS1,115200 root=/dev/ram0 rw initcall_blacklist=bcm2835_power_driver_init,bcm2835_wdt_driver_init"
}

function clean() {
    local mode="none"
    for arg in "$@"; do
        case "$arg" in
            --linux)
                [ "$mode" != "none" ] && {
                    echo "clean: --linux, --buildroot, and --toolchain are mutually exclusive" >&2
                    return 1
                }
                mode="linux"
                ;;
            --buildroot)
                [ "$mode" != "none" ] && {
                    echo "clean: --linux, --buildroot, and --toolchain are mutually exclusive" >&2
                    return 1
                }
                mode="buildroot"
                ;;
            --toolchain)
                [ "$mode" != "none" ] && {
                    echo "clean: --linux, --buildroot, and --toolchain are mutually exclusive" >&2
                    return 1
                }
                mode="toolchain"
                ;;
            *)
                echo "clean: unknown option '$arg' (use --linux, --buildroot, or --toolchain)" >&2
                return 1
                ;;
        esac
    done

    local src_dir="build/buildroot"
    echo "=== Clean ==="

    if [ -d "$src_dir" ]; then
        case "$mode" in
            linux)
                echo "=== linux-dirclean ==="
                make -C "$src_dir" linux-dirclean
                ;;
            buildroot)
                echo "=== buildroot clean ==="
                make -C "$src_dir" clean
                ;;
        esac
    fi

    if [ "$mode" = "toolchain" ]; then
        echo "=== Remove toolchain ==="
        rm -rf "build/toolchain"
        rm -f "build/$TOOLCHAIN_NAME.tar.xz" "build/$TOOLCHAIN_NAME.sha256"
    fi

    rm -rf artifacts/ build/buildroot/output/
    rm -f build/buildroot-*.tar.gz build/buildroot-*.tar.gz.sign

    echo "=== Remove module build artifacts ==="
    rm -rf br2-external/modules/*/src/{.tmp_versions,*.o,*.ko,*.mod,*.mod.c,*.mod.o,Module.symvers,modules.order,.*.cmd}
}

function build() {
  echo "=== Build ==="

  # usage: ./automation.sh build [configs/fleet/<env>|<config-dir>] [--release <name>|--version X.Y.Z]
  # Per-device identity is NOT baked anymore — flash images come from
  # scripts/provision-device.sh on top of a fleet build.
  local config_dir="" version="" release=""
  while [ $# -gt 0 ]; do
      case "$1" in
          --version) version="$2"; shift 2 ;;
          --release) release="$2"; shift 2 ;;
          *) config_dir="$1"; shift ;;
      esac
  done

  [ -n "$version" ] && [ -n "$release" ] && {
      echo "build: --version and --release are mutually exclusive" >&2; return 1; }

  # --release: the version is read from the release config (single source).
  if [ -n "$release" ]; then
      local rel_dir
      rel_dir="$(resolve_release_dir "$release")" || return 1
      [ -f "$rel_dir/config.env" ] || { echo "build: '$rel_dir/config.env' not found" >&2; return 1; }
      # shellcheck disable=SC1090,SC1091
      set -a; . "$rel_dir/config.env"; set +a
      version="${SHAREFRAME_VERSION:-}"
      [ -n "$version" ] || { echo "build: '$rel_dir/config.env' sets no SHAREFRAME_VERSION" >&2; return 1; }
      echo "=== Release config: $rel_dir (version $version) ==="
  fi

  if [ -n "$config_dir" ]; then
      config_dir="${config_dir%/}"
      [ -d "$config_dir" ] || { echo "build: config dir '$config_dir' not found" >&2; return 1; }
      [ -f "$config_dir/config.env" ] || { echo "build: '$config_dir/config.env' not found" >&2; return 1; }
      echo "=== Config: $config_dir ==="
      # shellcheck disable=SC1090,SC1091
      set -a; . "$config_dir/config.env"; set +a
      # Identity falls back to the dir name when config.env left the label unset.
      export SHAREFRAME_CONFIG_LABEL="${SHAREFRAME_CONFIG_LABEL:-$(basename "$config_dir")}"
  fi

  # Bake the version last so neither config nor release env can shadow it.
  if [ -n "$version" ]; then
      validate_version "$version"
      export SHAREFRAME_VERSION="$version"
      echo "=== Version: $version ==="
  fi

  # Argless build = QEMU/dev iteration; default to dev so the prod guards (cert,
  # password) don't block it. A config build or an explicit env override stays put.
  [ -z "$config_dir" ] && [ -z "${SHAREFRAME_BUILD_MODE:-}" ] && export SHAREFRAME_BUILD_MODE=dev

  local sha
  sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf 'CONFIG_LOCALVERSION="-%s"\n' "$sha" > br2-external/fragments/kernel-localversion.fragment
  export OS_SHA="$sha"

  # App identity: the sibling checkout Buildroot rsyncs (SITE_METHOD=local pins
  # nothing), so record which app commit actually went into the image.
  local app_src="${SHAREFRAME_BOARD_OVERRIDE_SRCDIR:-../shareframe-board}"
  export APP_SHA="$(git -C "$app_src" describe --always --abbrev=7 --dirty --exclude='*' 2>/dev/null || echo unknown)"
  echo "=== App SHA: ${APP_SHA} (${app_src}) ==="

  toolchain
  buildroot "$config_dir"
}

function restart() {
    echo "=== Power-cycle the Pi Zero via the 4B (uhubctl) ==="
    ssh "$PI4B" "reset-zero"
}

function connect_serial() {
    echo "=== Connect to the Zero serial console via the 4B ==="
    ssh -t "$PI4B" "picocom -b 115200 $PI4B_SERIAL"
}

function release() {
    # usage: ./automation.sh release <dev|prod> [--release <name>] [--from <label>] [--notes FILE]
    # Signs a stored build (artifacts/builds/<label>/); run it dev+prod or later,
    # never rebuilds. Version comes from the build; --release adds criticality/notes/hooks.
    local mode="${1:-dev}"; shift || true
    local release="" from="latest" notes=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --release) release="$2"; shift 2 ;;
            --from)    from="$2"; shift 2 ;;
            --notes)   notes="$2"; shift 2 ;;
            *) echo "release: unknown arg '$1'" >&2; return 1 ;;
        esac
    done

    local build_dir="artifacts/builds/${from}"
    [ -d "$build_dir" ] || { echo "release: build '${from}' not found in artifacts/builds/ — run build first" >&2; return 1; }
    [ -f "$build_dir/build.json" ] || { echo "release: $build_dir/build.json missing" >&2; return 1; }

    # Guard prod integrity from the build manifest.
    local b_mode
    b_mode="$(sed -n 's/.*"build_mode": *"\([^"]*\)".*/\1/p' "$build_dir/build.json")"
    [ "$mode" = prod ] && [ "$b_mode" != prod ] && {
        echo "release: prod release needs a prod-mode build ('${from}' is build_mode=${b_mode})" >&2; return 1; }

    local args=(--mode "$mode" --from "$build_dir")
    if [ -n "$release" ]; then
        local rel_dir
        rel_dir="$(resolve_release_dir "$release")" || return 1
        [ -f "$rel_dir/config.env" ] || { echo "release: '$rel_dir/config.env' not found" >&2; return 1; }
        args+=(--release-dir "$rel_dir")
    fi
    [ -n "$notes" ] && args+=(--notes "$notes")

    case "$mode" in
        dev)
            echo "=== Release ${from} (dev) ==="
            scripts/make-release.sh "${args[@]}"
            ;;
        prod)
            echo "=== Release ${from} (prod) ==="
            local keydir="${SHAREFRAME_RELEASE_KEYDIR:-$HOME/.shareframe-release-keys}"
            : "${SHAREFRAME_RELEASE_CERT:=$keydir/cert.pem}"
            : "${SHAREFRAME_RELEASE_KEY:=$keydir/key.pem}"
            [ -f "$SHAREFRAME_RELEASE_CERT" ] && [ -f "$SHAREFRAME_RELEASE_KEY" ] || {
                echo "release: prod keys missing in $keydir (scripts/gen-prod-keys.sh)" >&2; return 1; }
            SHAREFRAME_RELEASE_CERT="$SHAREFRAME_RELEASE_CERT" \
            SHAREFRAME_RELEASE_KEY="$SHAREFRAME_RELEASE_KEY" \
            scripts/make-release.sh "${args[@]}"
            ;;
        *)
            echo "release: mode must be dev or prod" >&2
            return 1
            ;;
    esac
}

"${@:-build}"