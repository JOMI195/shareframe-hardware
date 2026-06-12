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
    echo "=== SHAREFRAME_BUILD_MODE=${SHAREFRAME_BUILD_MODE} ==="

    # Config profile (default prod); selects which config overlay the app merges.
    export SHAREFRAME_PROFILE="${SHAREFRAME_PROFILE:-prod}"
    case "${SHAREFRAME_PROFILE}" in
        dev|prod|prod.local) ;;
        *) echo "buildroot: invalid SHAREFRAME_PROFILE='${SHAREFRAME_PROFILE}' (use dev, prod, prod.local)" >&2; return 1 ;;
    esac
    echo "=== SHAREFRAME_PROFILE=${SHAREFRAME_PROFILE} ==="

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
    make -C "$src_dir" rpi-firmware-dirclean
    make -C "$src_dir" shareframe-init-dirclean
    make -C "$src_dir" linux-reconfigure
    for mk in br2-external/modules/*/*.mk br2-external/package/*/*.mk; do
        [ -e "$mk" ] || continue
        grep -qF 'eval $(host-' "$mk" && continue
        make -C "$src_dir" "$(basename "$mk" .mk)-reconfigure"
    done

    # Drop stale secret seeds: TARGET_DIR persists across incremental builds;
    # the active overlay (or the tracked .template) re-creates them.
    rm -f "$src_dir/output/target/usr/share/shareframe/.env.secrets.toml.default" \
          "$src_dir/output/target/usr/share/shareframe/wpa_supplicant.conf.default"

    make -C "$src_dir" -j"$(nproc)"

    echo "=== Extract generated files ==="
    local img="$src_dir/output/images"
    local artifact_label="${SHAREFRAME_VERSION:-${BUILD_SHA:-unknown}}"

    rm -rf "artifacts/deploy/$artifact_label" "artifacts/sdcard/$artifact_label"
    mkdir -p "artifacts/deploy/$artifact_label" "artifacts/sdcard/$artifact_label"

    # artifacts/deploy/<label>/: individual artifacts (QEMU, debugging).
    cp "$img/zImage"                  "artifacts/deploy/$artifact_label/"
    cp "$img/bcm2835-rpi-zero-w.dtb"  "artifacts/deploy/$artifact_label/"
    [ -f "$img/spi0-spidev.dtbo" ] && cp "$img/spi0-spidev.dtbo" "artifacts/deploy/$artifact_label/"
    cp "$img/rootfs.squashfs"         "artifacts/deploy/$artifact_label/"
    cp "$img/initramfs.cpio.gz"       "artifacts/deploy/$artifact_label/"
    ln -sfn "$artifact_label" artifacts/deploy/latest

    # artifacts/sdcard/<label>/: full SD image (one dd writes all partitions).
    if [ -f "$img/sdcard.img" ]; then
        cp "$img/sdcard.img" "artifacts/sdcard/$artifact_label/"
    else
        echo "WARN: sdcard.img not found — post-image.sh or genimage failed?"
    fi
    ln -sfn "$artifact_label" artifacts/sdcard/latest

    echo "=== Inspect (${artifact_label}) ==="
    file "$(realpath "artifacts/deploy/$artifact_label/zImage")"
    [ -f "artifacts/deploy/$artifact_label/rootfs.squashfs" ] && file "$(realpath "artifacts/deploy/$artifact_label/rootfs.squashfs")"
    [ -f "artifacts/sdcard/$artifact_label/sdcard.img" ] && file "$(realpath "artifacts/sdcard/$artifact_label/sdcard.img")"
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
        -kernel artifacts/deploy/latest/zImage \
        -dtb artifacts/deploy/latest/bcm2835-rpi-zero-w.dtb \
        -initrd artifacts/deploy/latest/initramfs.cpio.gz \
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

  # usage: ./automation.sh build [configs/<customer>] [--version X.Y.Z]
  local config_dir="" version=""
  while [ $# -gt 0 ]; do
      case "$1" in
          --version) version="$2"; shift 2 ;;
          *) config_dir="$1"; shift ;;
      esac
  done

  if [ -n "$version" ]; then
      validate_version "$version"
      export SHAREFRAME_VERSION="$version"
      echo "=== Version: $version ==="
  fi

  if [ -n "$config_dir" ]; then
      config_dir="${config_dir%/}"
      [ -d "$config_dir" ] || { echo "build: config dir '$config_dir' not found" >&2; return 1; }
      [ -f "$config_dir/config.env" ] || { echo "build: '$config_dir/config.env' not found" >&2; return 1; }
      echo "=== Config: $config_dir ==="
      # shellcheck disable=SC1090,SC1091
      set -a; . "$config_dir/config.env"; set +a
  fi

  local sha
  sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf 'CONFIG_LOCALVERSION="-%s"\n' "$sha" > br2-external/fragments/kernel-localversion.fragment
  export BUILD_SHA="$sha"

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
    # usage: ./automation.sh release <dev|prod> --version X.Y.Z [--criticality C] [--notes FILE]
    local mode="${1:-dev}"; shift || true
    local version=""
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) version="$2"; shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done

    [ -n "$version" ] || { echo "release: --version required" >&2; return 1; }
    validate_version "$version"
    [ -d "releases/${version}" ] || { echo "release: releases/${version}/ not found — create it first" >&2; return 1; }
    [ -f build/buildroot/output/images/rootfs.squashfs ] || {
        echo "release: no build found — run ./automation.sh build --version ${version} [configs/...] first" >&2; return 1; }

    case "$mode" in
        dev)
            echo "=== Release ${version} (dev) ==="
            scripts/make-release.sh --mode dev --version "$version" "${args[@]}"
            ;;
        prod)
            echo "=== Release ${version} (prod) ==="
            local keydir="${SHAREFRAME_RELEASE_KEYDIR:-$HOME/.shareframe-release-keys}"
            : "${SHAREFRAME_RELEASE_CERT:=$keydir/cert.pem}"
            : "${SHAREFRAME_RELEASE_KEY:=$keydir/key.pem}"
            [ -f "$SHAREFRAME_RELEASE_CERT" ] && [ -f "$SHAREFRAME_RELEASE_KEY" ] || {
                echo "release: prod keys missing in $keydir (scripts/gen-prod-keys.sh)" >&2; return 1; }
            SHAREFRAME_RELEASE_CERT="$SHAREFRAME_RELEASE_CERT" \
            SHAREFRAME_RELEASE_KEY="$SHAREFRAME_RELEASE_KEY" \
            scripts/make-release.sh --mode prod --version "$version" "${args[@]}"
            ;;
        *)
            echo "release: mode must be dev or prod" >&2
            return 1
            ;;
    esac
}

"${@:-build}"