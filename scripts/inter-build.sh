#!/bin/bash
# Inter-build (post-fakeroot): adjustments with simulated root privileges.
set -e

TARGET_DIR="$1"

echo "=== Inter-build: fakeroot context active ==="
echo "    TARGET_DIR=$TARGET_DIR"
echo "    EUID=$(id -u)   (appears as 0 under fakeroot)"
# Stub — could later append to /etc/fstab, etc.