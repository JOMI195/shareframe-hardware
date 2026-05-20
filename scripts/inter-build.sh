#!/bin/bash
# Inter-build (Post-fakeroot): Anpassungen mit simulierten Root-Rechten
set -e

TARGET_DIR="$1"

echo "=== Inter-build: fakeroot-Kontext aktiv ==="
echo "    TARGET_DIR=$TARGET_DIR"
echo "    EUID=$(id -u)   (im fakeroot scheinbar 0)"
# Stub — kann später z.B. an /etc/fstab anhängen