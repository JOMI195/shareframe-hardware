#!/usr/bin/env bash
set -xe

BUILDROOT_VERSION="2026.02.2"
BUILDROOT_BASE_URL="https://buildroot.org/downloads/"

TOOLCHAIN_NAME="armv6-eabihf--musl--bleeding-edge-2025.08-1"
TOOLCHAIN_BASE_URL="https://toolchains.bootlin.com/downloads/releases/toolchains/armv6-eabihf/tarballs/"

PI4B="${PI4B:-base@shareframe-base}"
PI4B_SERIAL="${PI4B_SERIAL:-/dev/ttyACM0}"   # Raspberry Pi Debug Probe am 4B = CDC-ACM

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

    # SHAREFRAME_MODE: dev | prod (default). Picked up by:
    #   - post-image.sh -> sets dev_netboot=0|1 in compiled uboot.env
    #   - post-build.sh -> writes /etc/shareframe-mode (consumed by Phase 6 longrun)
    export SHAREFRAME_MODE="${SHAREFRAME_MODE:-prod}"
    echo "=== SHAREFRAME_MODE=${SHAREFRAME_MODE} ==="

    echo "=== Buildroot herunterladen und entpacken ==="
    local src_uri="$BUILDROOT_BASE_URL/buildroot-$BUILDROOT_VERSION.tar.gz"
    local sig_uri="$BUILDROOT_BASE_URL/buildroot-$BUILDROOT_VERSION.tar.gz.sign"
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

    echo "=== Buildroot bauen ==="
    make -C "$src_dir" shareframe-init-dirclean
    make -C "$src_dir" linux-reconfigure
    for mk in modules/*/*.mk package/*/*.mk; do
        [ -e "$mk" ] || continue
        grep -qF 'eval $(host-' "$mk" && continue
        make -C "$src_dir" "$(basename "$mk" .mk)-reconfigure"
    done

    make -C "$src_dir" -j"$(nproc)"

    echo "=== Generierte Dateien extrahieren ==="
    local img="$src_dir/output/images"
    rm -rf artifacts/deploy artifacts/sdcard
    mkdir -p artifacts/deploy artifacts/sdcard

    # --- artifacts/deploy/ : pro Kernel-Iteration ausgeliefert.
    # Im dev-mode laedt U-Boot diese via TFTP und schreibt rootfs.squashfs
    # in Slot A sowie zImage/dtb in /boot/A/ und initramfs/boot.scr/uboot.env
    # an FAT-Root. So sind boot.cmd / uboot-env Aenderungen ohne SD-Reflash
    # nach einem dev-mode reboot wirksam.
    cp "$img/zImage"                  artifacts/deploy/
    cp "$img/bcm2835-rpi-zero-w.dtb"  artifacts/deploy/
    cp "$img/rootfs.squashfs"         artifacts/deploy/
    cp "$img/initramfs.cpio.gz"       artifacts/deploy/
    [ -f "$img/boot.scr" ]      && cp "$img/boot.scr"      artifacts/deploy/
    [ -f "$img/uboot.env" ]     && cp "$img/uboot.env"     artifacts/deploy/

    # --- artifacts/sdcard/ : komplettes SD-Image (boot FAT + A/B + /data ext4)
    # via genimage (BR2_ROOTFS_POST_IMAGE_SCRIPT = board/raspberrypi0w/post-image.sh).
    # Einmaliges `dd if=sdcard.img of=/dev/sdX` legt alle Partitionen an.
    if [ -f "$img/sdcard.img" ]; then
        cp "$img/sdcard.img" artifacts/sdcard/
    else
        echo "WARN: sdcard.img nicht gefunden — post-image.sh oder genimage failed?"
    fi

    # --- artifacts/deploy/ : RAUC update bundle (signed). Dev keys via
    # scripts/gen-dev-keys.sh (run once). Bundle is what the future C++
    # download service fetches + passes to `rauc install`.
    if [ -f package/shareframe-rauc/files/cert.pem ] && [ -f package/shareframe-rauc/files/key.pem ]; then
        if ! ./scripts/make-bundle.sh; then
            echo "WARN: make-bundle.sh failed"
        fi
    else
        echo "INFO: dev keys missing — skipping RAUC bundle build. Run scripts/gen-dev-keys.sh first."
    fi

    echo "=== Auswertung ==="
    file "$(realpath artifacts/deploy/zImage)"
    [ -f artifacts/deploy/rootfs.squashfs ] && file "$(realpath artifacts/deploy/rootfs.squashfs)"
    [ -f artifacts/sdcard/sdcard.img ] && file "$(realpath artifacts/sdcard/sdcard.img)"
}

function qemu_rpi0() {
    # Quick-Verify ohne Hardware: bootet zImage + initramfs bis BusyBox-Login.
    # USB-Gadget/usb0/SSH sind in QEMU NICHT testbar (kein Host-Gegenstück) — die
    # "ip: can't find device usb0"-Meldungen sind hier normal.
    #
    # Konsole = ttyS1 (mini-UART, 0x20215040) wie auf echter Hardware (GPIO-UART zum 4B).
    # QEMU-only:
    #  - "-serial null -serial mon:stdio": legt die mini-UART (serial_hd(1)) auf stdio,
    #    sonst zeigt -nographic nur die PL011 und ttyS1 bliebe unsichtbar.
    #  - earlycon=uart8250,...,0x20215040: Early-Output auf der mini-UART.
    #  - initcall_blacklist=...power/wdt: QEMU modelliert den BCM2835-PM/Watchdog-
    #    Block nicht -> sonst Oops in bcm2835_power_probe bzw. Reboot-Loop.
    qemu-system-arm \
        -M raspi0 \
        -nographic \
        -serial null -serial mon:stdio \
        -kernel artifacts/deploy/zImage \
        -dtb artifacts/deploy/bcm2835-rpi-zero-w.dtb \
        -initrd artifacts/deploy/rootfs.cpio.gz \
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

    local src_dir="buildroot/src"
    local toolchain_dir="toolchain"
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

    if [ "$mode" = "toolchain" ]; then
        echo "=== Toolchain entfernen ==="
        rm -rf "$toolchain_dir/src"
        rm -f "$toolchain_dir/$TOOLCHAIN_NAME.tar.xz" "$toolchain_dir/$TOOLCHAIN_NAME.sha256"
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
    echo "=== Sende Dev-Netboot-Artefakte zum Pi 4B (TFTP) ==="

    local deploy_src_dir="artifacts/deploy"

    ssh "$PI4B" "mkdir -p /srv/tftp/pizero"
    scp \
        "$deploy_src_dir/zImage" \
        "$deploy_src_dir/bcm2835-rpi-zero-w.dtb" \
        "$deploy_src_dir/rootfs.squashfs" \
        "$deploy_src_dir/initramfs.cpio.gz" \
        "$PI4B:/srv/tftp/pizero/"

    true
}

function restart() {
    echo "=== Power-Cycle des Pi Zero über den 4B (uhubctl) ==="
    ssh "$PI4B" "reset-zero"
}

function connect_serial() {
    echo "=== Verbinde zur Zero-Serial-Konsole über den 4B ==="
    ssh -t "$PI4B" "picocom -b 115200 $PI4B_SERIAL"
}

"${@:-build}"