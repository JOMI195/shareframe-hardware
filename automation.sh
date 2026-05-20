#!/usr/bin/env bash
set -xe

BUILDROOT_VERSION="buildroot-2025.11.3"
BUILDROOT_BASE_URL="https://buildroot.org/downloads/"

TOOLCHAIN_NAME="armv6-eabihf--musl--stable-2025.08-1"
TOOLCHAIN_BASE_URL="https://toolchains.bootlin.com/downloads/releases/toolchains/armv6-eabihf/tarballs/"

[[ -d artifacts ]] || mkdir artifacts

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

# prepare kernel download and recall stored config file to kernel src/ dir
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
    echo "=== Toolchain herunterladen, prüfen, entpacken ==="
    local src_uri="$TOOLCHAIN_BASE_URL/$TOOLCHAIN_NAME.tar.xz"
    local sig_uri="$TOOLCHAIN_BASE_URL/$TOOLCHAIN_NAME.sha256"
    local src_dir="toolchain/src"
    local marker="bin/arm-buildroot-linux-musleabihf-gcc"

    prepare_src \
      "$TOOLCHAIN_BASE_URL/$TOOLCHAIN_NAME.tar.xz" \
      "$TOOLCHAIN_BASE_URL/$TOOLCHAIN_NAME.sha256" \
      "$src_dir" \
      "$marker"
}

function buildroot() {
    local config="buildroot-rpi0w"

    echo "=== Buildroot herunterladen und entpacken ==="
    local src_uri="$BUILDROOT_BASE_URL/$BUILDROOT_VERSION.tar.gz"
    local sig_uri="$BUILDROOT_BASE_URL/$BUILDROOT_VERSION.tar.gz.sign"
    local src_dir="buildroot/src"

    prepare_src \
      "$src_uri" \
      "$sig_uri" \
      "$src_dir"

    echo "=== Buildroot konfigurieren ==="
    make -C "$src_dir" \
      BR2_DEFCONFIG="$(realpath "$(dirname "$src_dir")/${config}.conf")" \
      BR2_EXTERNAL="$(realpath .)" \
      defconfig
    make -C "$src_dir" olddefconfig
#
#    echo "=== Buildroot bauen ==="
#    make -C "$src_dir" linux-reconfigure
#    make -C "$src_dir" -j"$(nproc)"
#
#    echo "=== Generierte Dateien extrahieren ==="
#    cp "$src_dir/output/images/Image" artifacts/Image
#    cp "$src_dir/output/images/rootfs.cpio.gz" artifacts/rootfs.cpio.gz
#    cp "$src_dir/output/images/bcm2835-rpi-zero-w.dtb" artifacts/
#    cp "$src_dir/output/images/rpi-firmware/start4.elf" artifacts/
#    cp "$src_dir/output/images/rpi-firmware/fixup4.dat" artifacts/
#
#    echo "=== Auswertung generierter Dateien ==="
#    local image_path rootfs_path
#    image_path="$(realpath artifacts/Image)"
#    rootfs_path="$(realpath artifacts/rootfs.cpio.gz)"
#    echo "Image:  $image_path"
#    file "$image_path"
#    echo "rootfs: $rootfs_path"
#    file "$rootfs_path"
}

function qemu_virt() {
    qemu-system-aarch64 \
      -M virt \
      -m 256 \
      -nographic \
      -kernel artifacts/Image \
      -initrd artifacts/rootfs.cpio.gz \
      -append "console=ttyAMA0" \
      -cpu cortex-a72
}

function qemu_rpi4() {
    qemu-system-aarch64 \
        -M raspi4b \
        -m 2G \
        -smp 4 \
        -nographic \
        -kernel artifacts/Image \
        -dtb artifacts/bcm2711-rpi-4-b.dtb \
        -initrd artifacts/rootfs.cpio.gz \
        -append "console=ttyAMA0,115200 root=/dev/ram0 earlycon clk_ignore_unused"
}

function clean() {
    local mode="none"
    for arg in "$@"; do
        case "$arg" in
            --linux)
                [ "$mode" != "none" ] && {
                    echo "clean: --linux and --buildroot are mutually exclusive" >&2
                    return 1
                }
                mode="linux"
                ;;
            --buildroot)
                [ "$mode" != "none" ] && {
                    echo "clean: --linux and --buildroot are mutually exclusive" >&2
                    return 1
                }
                mode="buildroot"
                ;;
            *)
                echo "clean: unknown option '$arg' (use --linux or --buildroot)" >&2
                return 1
                ;;
        esac
    done

    local src_dir="buildroot/src"
    echo "=== Aufräumen ==="

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

    rm -rf artifacts/ buildroot/src/output/
    rm -f buildroot/buildroot-*.tar.gz buildroot/buildroot-*.tar.gz.sign

    echo "=== Modul-Build-Artefakte entfernen ==="
    rm -rf modules/*/src/{.tmp_versions,*.o,*.ko,*.mod,*.mod.c,*.mod.o,Module.symvers,modules.order,.*.cmd}
}

function build() {
  echo "=== Bauen==="

  local sha
  sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf 'CONFIG_LOCALVERSION="-%s"\n' "$sha" > fragments/kernel-localversion.fragment
  export BUILD_SHA="$sha"

  toolchain
  buildroot
}

function deploy() {
    echo "=== Sende Artefakte zu Cluster PI ==="
    scp -P 10002 \
        artifacts/Image \
        artifacts/bcm2711-rpi-4-b.dtb \
        artifacts/rootfs.cpio.gz \
        artifacts/start4.elf \
        artifacts/fixup4.dat \
        m5/cmdline.txt \
        m5/config.txt \
        esys@141.37.31.100:/srv/tftp/
}

function restart() {
    echo "=== Starte Cluster PI neu ==="
    ssh esys-cluster "./enable_pi.sh false && sleep 2 && ./enable_pi.sh true"
}

function connect_serial() {
    echo "=== Verbinde zu Cluster PI über TT&C-Channel ==="
    ssh esys-cluster -L 3001:localhost:3001 -N &
    local pid=$!
    trap 'kill "$pid" 2>/dev/null' EXIT
    sleep 1
    nc localhost 3001
}

"${@:-build}"