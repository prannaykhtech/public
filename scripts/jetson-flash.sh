#!/usr/bin/env bash
# jetson-flash.sh -- Recover/flash a Jetson Orin from an Ubuntu host via USB recovery mode.
#
# RUN ON: an Ubuntu x86_64 host (20.04 / 22.04 / 24.04) with a USB-C cable to the Jetson's
# recovery port and the Jetson in Force Recovery Mode.
#
# DOES NOT REQUIRE: NVIDIA developer login, SDK Manager, or a GUI. Pure CLI.
#
# Default target: Jetson AGX Orin Developer Kit, JetPack 6.2.1 (L4T R36.4.4).
# Override via env vars:
#   JETSON_BOARD          (default: jetson-agx-orin-devkit)
#   L4T_RELEASE           (default: 36.4.4)
#   L4T_REPO_DIR          (default: r36_release_v4.4)
#   WORK_DIR              (default: $HOME/jetson-flash/<release>)
#
# Other supported boards (override JETSON_BOARD):
#   jetson-orin-nano-devkit            (Orin Nano Dev Kit, NVMe)
#   jetson-orin-nano-devkit-super      (Orin Nano "Super" Dev Kit)
#   jetson-agx-orin-devkit
#   jetson-orin-nx-devkit              (with appropriate carrier)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/prannaykhtech/public/main/scripts/jetson-flash.sh | bash
#   # or with overrides:
#   curl -fsSL .../jetson-flash.sh | JETSON_BOARD=jetson-orin-nano-devkit L4T_RELEASE=36.4.4 bash
#
# Steps:
#   1. preflight: ubuntu host, root sudo, Jetson visible in lsusb (0955:7023 APX)
#   2. install host prerequisites
#   3. download BSP + sample rootfs (cached in WORK_DIR; resumes partial downloads)
#   4. extract BSP, extract rootfs into Linux_for_Tegra/rootfs/
#   5. run apply_binaries.sh
#   6. run l4t_flash_prerequisites.sh (newer L4T versions)
#   7. run flash.sh <board> internal
#
# Total time: ~30-60 min depending on bandwidth (downloads ~3 GB, flash ~15-20 min).
#
# Logs: $WORK_DIR/flash-<timestamp>.log

set -euo pipefail

# ---------- defaults / overrides ----------
JETSON_BOARD="${JETSON_BOARD:-jetson-agx-orin-devkit}"
L4T_RELEASE="${L4T_RELEASE:-36.4.4}"
L4T_REPO_DIR="${L4T_REPO_DIR:-r36_release_v4.4}"
WORK_DIR="${WORK_DIR:-$HOME/jetson-flash/$L4T_RELEASE}"

BSP_TARBALL="jetson_linux_r${L4T_RELEASE}_aarch64.tbz2"
ROOTFS_TARBALL="tegra_linux_sample-root-filesystem_r${L4T_RELEASE}_aarch64.tbz2"
BSP_URL="https://developer.nvidia.com/downloads/embedded/l4t/${L4T_REPO_DIR}/release/${BSP_TARBALL}"
ROOTFS_URL="https://developer.nvidia.com/downloads/embedded/l4t/${L4T_REPO_DIR}/release/${ROOTFS_TARBALL}"

LOG_FILE="$WORK_DIR/flash-$(date -u +%Y%m%dT%H%M%SZ).log"

# ---------- helpers ----------
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

confirm_or_abort() {
    if [ "${ASSUME_YES:-0}" = "1" ]; then return 0; fi
    log "Press ENTER to continue, Ctrl-C to abort."
    read -r _
}

ensure_log() {
    mkdir -p "$WORK_DIR"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# ---------- step 1: preflight ----------
preflight() {
    log "=== preflight ==="
    log "host:       $(uname -n)"
    log "kernel:     $(uname -r)"
    log "arch:       $(uname -m)"
    log "ubuntu:     $(lsb_release -ds 2>/dev/null || echo unknown)"
    log "target:     $JETSON_BOARD"
    log "release:    L4T $L4T_RELEASE ($L4T_REPO_DIR)"
    log "work dir:   $WORK_DIR"

    [ "$(uname -m)" = "x86_64" ] || die "must run on x86_64 (got $(uname -m))."
    [ "$(uname -s)" = "Linux" ] || die "must run on Linux."

    if ! command -v sudo >/dev/null; then die "sudo is required."; fi
    sudo -n true 2>/dev/null || die "passwordless sudo required (or run script as root)."

    if ! lsusb | grep -q "0955:7023"; then
        log "lsusb output:"
        lsusb | sed 's/^/  /'
        die "Jetson not visible in recovery mode. Expected USB device 0955:7023 (NVIDIA APX). Put Jetson in Force Recovery Mode (hold REC, tap POWER) and connect USB-C from recovery port to this host."
    fi
    log "Jetson detected: $(lsusb | grep '0955:7023')"
    confirm_or_abort
}

# ---------- step 2: host prereqs ----------
install_prereqs() {
    log "=== install host prerequisites ==="
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        wget curl ca-certificates \
        qemu-user-static \
        lbzip2 \
        abootimg \
        python3 python3-pip \
        sshpass \
        libxml2-utils \
        binutils \
        sudo \
        tar bzip2 xz-utils
    log "prereqs installed."
}

# ---------- step 3: download BSP + rootfs ----------
download() {
    log "=== download BSP and rootfs ==="
    mkdir -p "$WORK_DIR/downloads"
    cd "$WORK_DIR/downloads"

    for spec in "$BSP_TARBALL|$BSP_URL" "$ROOTFS_TARBALL|$ROOTFS_URL"; do
        local f="${spec%%|*}"
        local u="${spec##*|}"
        if [ -f "$f" ]; then
            local sz
            sz=$(stat -c%s "$f")
            if [ "$sz" -gt 100000000 ]; then
                log "  $f present (${sz} bytes), skipping."
                continue
            else
                log "  $f present but suspiciously small (${sz} bytes), re-downloading."
                rm -f "$f"
            fi
        fi
        log "  downloading $f from $u"
        wget --continue --show-progress --progress=dot:giga "$u" || die "download failed: $u"
    done
}

# ---------- step 4: extract ----------
extract() {
    log "=== extract BSP ==="
    cd "$WORK_DIR"
    if [ -d "Linux_for_Tegra" ]; then
        log "  Linux_for_Tegra/ exists; removing for clean extract."
        sudo rm -rf "Linux_for_Tegra"
    fi
    tar xpf "downloads/$BSP_TARBALL"
    [ -d Linux_for_Tegra ] || die "Linux_for_Tegra/ missing after BSP extract."

    log "=== extract sample rootfs ==="
    cd Linux_for_Tegra/rootfs
    sudo tar xpf "$WORK_DIR/downloads/$ROOTFS_TARBALL"
    sudo chown -R root:root "$WORK_DIR/Linux_for_Tegra/rootfs"
    cd "$WORK_DIR"
}

# ---------- step 5: apply_binaries ----------
apply_binaries() {
    log "=== apply_binaries.sh ==="
    cd "$WORK_DIR/Linux_for_Tegra"
    sudo ./apply_binaries.sh
}

# ---------- step 6: l4t_flash_prerequisites ----------
flash_prereqs() {
    log "=== l4t_flash_prerequisites.sh ==="
    cd "$WORK_DIR/Linux_for_Tegra"
    if [ -x tools/l4t_flash_prerequisites.sh ]; then
        sudo ./tools/l4t_flash_prerequisites.sh
    else
        log "  tools/l4t_flash_prerequisites.sh not present (older L4T?), skipping."
    fi
}

# ---------- step 7: flash ----------
flash_device() {
    log "=== flash $JETSON_BOARD ==="
    cd "$WORK_DIR/Linux_for_Tegra"
    if ! lsusb | grep -q "0955:7023"; then
        die "Jetson no longer in recovery mode. Re-trigger recovery and re-run."
    fi
    sudo ./flash.sh "$JETSON_BOARD" internal
    log "=== flash complete ==="
}

# ---------- driver ----------
main() {
    ensure_log
    log "log: $LOG_FILE"

    preflight
    install_prereqs
    download
    extract
    apply_binaries
    flash_prereqs
    flash_device

    cat <<EOF

============================================================
  FLASH COMPLETE
============================================================
  Board:    $JETSON_BOARD
  Release:  L4T $L4T_RELEASE
  Log:      $LOG_FILE

Next steps on the Jetson:
  1. Disconnect the recovery USB-C cable.
  2. Reboot or power-cycle the Jetson.
  3. The first boot runs Ubuntu's oem-config wizard:
       - if you have a monitor + keyboard, complete it interactively.
       - otherwise, see Linux_for_Tegra/tools/l4t_create_default_user.sh
         to pre-seed a user before flashing (re-flash required).
  4. After first-boot user creation, enable SSH (already on by default
     in JetPack 6.x) and connect via LAN.
  5. Install SDK components (CUDA, cuDNN, TensorRT, OpenCV, VPI):
       sudo apt update
       sudo apt install -y nvidia-jetpack
       echo 'export PATH=/usr/local/cuda/bin:\$PATH' >> ~/.bashrc
       echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH' >> ~/.bashrc

To pre-seed username/password instead of running oem-config (recommended
for headless flashing), run BEFORE the flash step:

  sudo ./tools/l4t_create_default_user.sh \\
      -u <username> -p <password> -n <hostname> --accept-license

Then call this script with FLASH_PRESEEDED=1 to skip extraction next time.

============================================================
EOF
}

main "$@"
