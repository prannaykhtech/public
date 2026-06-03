#!/usr/bin/env bash
# jetson-flash.sh -- Recover/flash a Jetson Orin from an Ubuntu host via USB recovery mode,
# pre-seeded for headless first boot (default user, hostname, SSH key, passwordless sudo).
#
# RUN ON: an Ubuntu x86_64 host (20.04 / 22.04 / 24.04) with a USB-C cable from the host's
# USB 3.x port to the Jetson's RECOVERY USB-C port, and the Jetson in Force Recovery Mode.
#
# DOES NOT REQUIRE: NVIDIA developer login, SDK Manager, or a GUI. Pure CLI.
#
# Default target: Jetson AGX Orin Developer Kit, JetPack 6.2.1 (L4T R36.4.4).
#
# REQUIRED env vars:
#   JETSON_HOSTNAME        e.g. guild-orin-1
#   JETSON_PASS            console password for the seeded user (>= 8 chars).
#                          SSH should use keys; this is fallback only.
#
# OPTIONAL env vars:
#   JETSON_USER            (default: guild)
#   JETSON_AUTHORIZED_KEY  path to an SSH public key file to install into authorized_keys
#                          (default: $HOME/.ssh/id_ed25519.pub on the flashing host)
#   JETSON_BOARD           (default: jetson-agx-orin-devkit)
#   L4T_RELEASE            (default: 36.4.4)
#   L4T_REPO_DIR           (default: r36_release_v4.4)
#   WORK_DIR               (default: $HOME/jetson-flash/<release>)
#   ASSUME_YES=1           skip the "press ENTER" confirmation
#   SKIP_USB3_CHECK=1      skip the USB-3 link-speed assertion (not recommended)
#
# Force-redo flags (default: skip steps that are already done):
#   FORCE_REINSTALL_PREREQS=1   re-run apt install for host packages
#   FORCE_REEXTRACT=1           wipe Linux_for_Tegra/ and re-extract from tarballs
#   FORCE_REAPPLY=1             re-run apply_binaries.sh
#   FORCE_RESEED_USER=1         re-run l4t_create_default_user.sh
#   FORCE_REPREQ=1              re-run tools/l4t_flash_prerequisites.sh
#
# Other supported boards (override JETSON_BOARD):
#   jetson-orin-nano-devkit            (Orin Nano Dev Kit, NVMe)
#   jetson-orin-nano-devkit-super      (Orin Nano "Super" Dev Kit)
#   jetson-agx-orin-devkit
#   jetson-orin-nx-devkit              (with appropriate carrier)
#
# Usage:
#   JETSON_HOSTNAME=guild-orin-1 JETSON_PASS='somepass' \
#     bash <(curl -fsSL https://raw.githubusercontent.com/prannaykhtech/public/main/scripts/jetson-flash.sh)
#
# Steps:
#   1. preflight: ubuntu host, root sudo, Jetson in recovery on USB 3.x port, ModemManager off
#   2. install host prerequisites
#   3. download BSP + sample rootfs (cached in WORK_DIR; resumes partial downloads)
#   4. extract BSP, extract rootfs into Linux_for_Tegra/rootfs/
#   5. apply_binaries.sh
#   6. pre-seed user via l4t_create_default_user.sh (skips oem-config wizard)
#   7. drop SSH authorized_keys + passwordless sudo into rootfs
#   8. l4t_flash_prerequisites.sh
#   9. flash.sh <board> internal
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

JETSON_USER="${JETSON_USER:-guild}"
JETSON_AUTHORIZED_KEY="${JETSON_AUTHORIZED_KEY:-$HOME/.ssh/id_ed25519.pub}"

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

require_env() {
    local name="$1"
    local val="${!name:-}"
    [ -n "$val" ] || die "$name must be set."
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
    log "user:       $JETSON_USER@${JETSON_HOSTNAME:-<unset>}"
    log "ssh key:    $JETSON_AUTHORIZED_KEY"

    [ "$(uname -m)" = "x86_64" ] || die "must run on x86_64 (got $(uname -m))."
    [ "$(uname -s)" = "Linux" ] || die "must run on Linux."

    require_env JETSON_HOSTNAME
    require_env JETSON_PASS
    [ "${#JETSON_PASS}" -ge 8 ] || die "JETSON_PASS must be >= 8 chars."

    if ! command -v sudo >/dev/null; then die "sudo is required."; fi
    sudo -n true 2>/dev/null || die "passwordless sudo required (or run as root)."

    if [ -n "$JETSON_AUTHORIZED_KEY" ] && [ ! -f "$JETSON_AUTHORIZED_KEY" ]; then
        die "JETSON_AUTHORIZED_KEY=$JETSON_AUTHORIZED_KEY does not exist. Provide a valid public key file or unset to skip SSH key setup."
    fi
    if [ -n "$JETSON_AUTHORIZED_KEY" ] && ! grep -qE '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2)' "$JETSON_AUTHORIZED_KEY"; then
        die "JETSON_AUTHORIZED_KEY=$JETSON_AUTHORIZED_KEY does not look like a valid SSH public key."
    fi

    if ! lsusb | grep -q "0955:7023"; then
        log "lsusb output:"
        lsusb | sed 's/^/  /'
        die "Jetson not visible in recovery mode. Expected USB device 0955:7023 (NVIDIA APX). Hold REC + tap POWER on the Jetson, connect USB-C from the recovery port to this host."
    fi
    log "Jetson detected: $(lsusb | grep '0955:7023')"

    if [ "${SKIP_USB3_CHECK:-0}" != "1" ]; then
        local jetson_speed
        jetson_speed=$(lsusb -t 2>/dev/null | awk '
            /Bus / {bus=$0; next}
            /0955|usbfs/ {print bus; exit}
        ' || true)
        local jetson_line
        jetson_line=$(lsusb -t 2>/dev/null | grep -E "0955" || true)
        local link_speed
        link_speed=$(echo "$jetson_line" | grep -oE '[0-9]+M' | head -1 || true)
        if [ -z "$link_speed" ]; then
            link_speed=$(lsusb -v -d 0955:7023 2>/dev/null | awk '/bcdUSB/ {print $2; exit}' || true)
        fi
        log "Jetson link speed (lsusb -t): ${link_speed:-unknown}"
        case "$link_speed" in
            10000M|5000M)
                log "USB 3.x link OK."
                ;;
            480M|480|"")
                log ""
                log "WARNING: Jetson is connected at USB 2 speed (480M) or unknown."
                log "  Flashing usually fails on USB 2 with 'timeout in USB write'."
                log "  Move the host-side USB-C cable to a USB 3.x port (typically the small USB-C"
                log "  port on the desktop, or a blue/red USB-A port). Re-trigger recovery and re-run."
                log "  To override (not recommended), set SKIP_USB3_CHECK=1."
                die "USB-3 link speed assertion failed (link=$link_speed)."
                ;;
        esac
    fi

    if systemctl is-active --quiet ModemManager 2>/dev/null; then
        log "Stopping ModemManager (steals Jetson recovery handshake)."
        sudo systemctl stop ModemManager || true
    fi

    log "Disabling USB autosuspend on host."
    for f in /sys/bus/usb/devices/usb*/power/control; do
        echo on | sudo tee "$f" >/dev/null 2>&1 || true
    done

    confirm_or_abort
}

# ---------- step 2: host prereqs ----------
HOST_PKGS=(
    wget curl ca-certificates
    qemu-user-static
    lbzip2
    abootimg
    python3 python3-pip
    sshpass
    libxml2-utils
    binutils
    tar bzip2 xz-utils
    whois
)

install_prereqs() {
    log "=== host prerequisites ==="
    local missing=()
    for p in "${HOST_PKGS[@]}"; do
        if ! dpkg-query -W -f='${Status}\n' "$p" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$p")
        fi
    done
    if [ "${FORCE_REINSTALL_PREREQS:-0}" = "1" ]; then
        missing=("${HOST_PKGS[@]}")
    fi
    if [ ${#missing[@]} -eq 0 ]; then
        log "  all ${#HOST_PKGS[@]} packages already installed; skipping apt."
        return 0
    fi
    log "  missing: ${missing[*]}"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    log "  installed."
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
    log "=== extract BSP + rootfs ==="
    cd "$WORK_DIR"

    local bsp_marker="Linux_for_Tegra/flash.sh"
    local rootfs_marker="Linux_for_Tegra/rootfs/usr/bin/dpkg"

    if [ "${FORCE_REEXTRACT:-0}" = "1" ] && [ -d "Linux_for_Tegra" ]; then
        log "  FORCE_REEXTRACT=1: removing existing Linux_for_Tegra/."
        sudo rm -rf "Linux_for_Tegra"
    fi

    if [ -f "$bsp_marker" ]; then
        log "  BSP already extracted ($bsp_marker present); skipping."
    else
        log "  extracting BSP..."
        tar xpf "downloads/$BSP_TARBALL"
        [ -f "$bsp_marker" ] || die "BSP extract failed -- $bsp_marker missing."
    fi

    if [ -f "$rootfs_marker" ]; then
        log "  rootfs already extracted ($rootfs_marker present); skipping."
    else
        log "  extracting sample rootfs..."
        cd Linux_for_Tegra/rootfs
        sudo tar xpf "$WORK_DIR/downloads/$ROOTFS_TARBALL"
        sudo chown -R root:root "$WORK_DIR/Linux_for_Tegra/rootfs"
        cd "$WORK_DIR"
        [ -f "$rootfs_marker" ] || die "rootfs extract failed -- $rootfs_marker missing."
    fi
}

# Clean up chroot leftovers from a previous (interrupted) apply_binaries.sh:
# stale /dev nodes that mknod re-collides on, and stale bind mounts under rootfs/.
cleanup_chroot_state() {
    local rootfs="$WORK_DIR/Linux_for_Tegra/rootfs"
    [ -d "$rootfs" ] || return 0

    # unmount anything still bound under rootfs/
    if mount | grep -q "$rootfs"; then
        log "  unmounting stale chroot mounts under rootfs/"
        mount | awk -v r="$rootfs" '$3 ~ r {print $3}' | tac | xargs -r sudo umount -lf
    fi

    # remove device nodes apply_binaries tries to recreate via mknod
    for d in random urandom null zero console tty full ptmx; do
        sudo rm -f "$rootfs/dev/$d" 2>/dev/null || true
    done
}

# ---------- step 5: apply_binaries ----------
apply_binaries() {
    log "=== apply_binaries.sh ==="
    cd "$WORK_DIR/Linux_for_Tegra"
    local marker=".apply_binaries.done"
    if [ "${FORCE_REAPPLY:-0}" != "1" ] && [ -f "$marker" ]; then
        log "  apply_binaries already done ($marker present); skipping."
        return 0
    fi
    cleanup_chroot_state
    sudo ./apply_binaries.sh
    sudo touch "$marker"
}

# ---------- step 6: pre-seed default user (skip oem-config) ----------
preseed_user() {
    log "=== pre-seed default user $JETSON_USER@$JETSON_HOSTNAME ==="
    cd "$WORK_DIR/Linux_for_Tegra"
    if [ ! -x tools/l4t_create_default_user.sh ]; then
        die "tools/l4t_create_default_user.sh missing -- BSP layout unexpected."
    fi

    local rootfs_passwd="rootfs/etc/passwd"
    local rootfs_hostname="rootfs/etc/hostname"
    if [ "${FORCE_RESEED_USER:-0}" != "1" ] \
       && [ -f "$rootfs_passwd" ] \
       && grep -q "^${JETSON_USER}:" "$rootfs_passwd" \
       && [ -f "$rootfs_hostname" ] \
       && [ "$(cat "$rootfs_hostname" 2>/dev/null)" = "$JETSON_HOSTNAME" ]; then
        log "  user '$JETSON_USER' and hostname '$JETSON_HOSTNAME' already in rootfs; skipping."
        return 0
    fi

    sudo ./tools/l4t_create_default_user.sh \
        -u "$JETSON_USER" \
        -p "$JETSON_PASS" \
        -n "$JETSON_HOSTNAME" \
        --accept-license
    log "  default user '$JETSON_USER' seeded with hostname '$JETSON_HOSTNAME'; oem-config wizard disabled."
}

# ---------- step 7: ssh key + passwordless sudo into rootfs ----------
seed_remote_access() {
    log "=== seed SSH authorized_keys + passwordless sudo ==="
    local ROOTFS="$WORK_DIR/Linux_for_Tegra/rootfs"
    local USER_HOME="$ROOTFS/home/$JETSON_USER"

    if [ ! -d "$USER_HOME" ]; then
        die "$USER_HOME missing -- pre-seed step did not create user home."
    fi

    # SSH key
    if [ -n "$JETSON_AUTHORIZED_KEY" ] && [ -f "$JETSON_AUTHORIZED_KEY" ]; then
        local AK="$USER_HOME/.ssh/authorized_keys"
        if [ -f "$AK" ] && sudo cmp -s "$JETSON_AUTHORIZED_KEY" "$AK"; then
            log "  ssh authorized_keys already installed and matches; skipping."
        else
            log "  installing ssh public key from $JETSON_AUTHORIZED_KEY"
            sudo mkdir -p "$USER_HOME/.ssh"
            sudo cp "$JETSON_AUTHORIZED_KEY" "$AK"
            sudo chmod 700 "$USER_HOME/.ssh"
            sudo chmod 600 "$AK"
            # The l4t_create_default_user.sh sets uid 1000 / gid 1000 for the seeded user.
            sudo chown -R 1000:1000 "$USER_HOME/.ssh"
        fi
    else
        log "  no SSH key provided; skipping authorized_keys setup."
    fi

    # passwordless sudo
    local SUDOERS_DIR="$ROOTFS/etc/sudoers.d"
    local SUDOERS_FILE="$SUDOERS_DIR/$JETSON_USER"
    local SUDOERS_LINE="$JETSON_USER ALL=(ALL) NOPASSWD: ALL"
    if [ -f "$SUDOERS_FILE" ] && sudo grep -qxF "$SUDOERS_LINE" "$SUDOERS_FILE"; then
        log "  sudoers entry for '$JETSON_USER' already present; skipping."
    else
        log "  installing /etc/sudoers.d/$JETSON_USER (NOPASSWD: ALL)"
        sudo mkdir -p "$SUDOERS_DIR"
        echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" >/dev/null
        sudo chmod 0440 "$SUDOERS_FILE"
        sudo chown 0:0 "$SUDOERS_FILE"
    fi

    # Make sure ssh is enabled at boot. On JP6 sample rootfs, openssh-server is
    # already installed; mask the multi-user wait by ensuring the service is
    # enabled in the offline rootfs.
    if [ -d "$ROOTFS/etc/systemd/system/multi-user.target.wants" ]; then
        if [ -f "$ROOTFS/lib/systemd/system/ssh.service" ] && \
           [ ! -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/ssh.service" ]; then
            log "enabling ssh.service in rootfs"
            sudo ln -sf /lib/systemd/system/ssh.service \
                "$ROOTFS/etc/systemd/system/multi-user.target.wants/ssh.service"
        fi
    fi

    log "remote access seeded."
}

# ---------- step 8: l4t_flash_prerequisites ----------
flash_prereqs() {
    log "=== l4t_flash_prerequisites.sh ==="
    cd "$WORK_DIR/Linux_for_Tegra"
    local marker=".l4t_flash_prereqs.done"
    if [ "${FORCE_REPREQ:-0}" != "1" ] && [ -f "$marker" ]; then
        log "  l4t_flash_prerequisites already done ($marker present); skipping."
        return 0
    fi
    if [ -x tools/l4t_flash_prerequisites.sh ]; then
        sudo ./tools/l4t_flash_prerequisites.sh
        sudo touch "$marker"
    else
        log "  tools/l4t_flash_prerequisites.sh not present (older L4T?), skipping."
    fi
}

# ---------- step 9: flash ----------
flash_device() {
    log "=== flash $JETSON_BOARD ==="
    cd "$WORK_DIR/Linux_for_Tegra"
    if ! lsusb | grep -q "0955:7023"; then
        die "Jetson no longer in recovery mode. Re-trigger recovery and re-run flash."
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
    preseed_user
    seed_remote_access
    flash_prereqs
    flash_device

    cat <<EOF

============================================================
  FLASH COMPLETE
============================================================
  Board:       $JETSON_BOARD
  Release:     L4T $L4T_RELEASE
  Hostname:    $JETSON_HOSTNAME
  User:        $JETSON_USER (passwordless sudo)
  SSH key:     $([ -f "$JETSON_AUTHORIZED_KEY" ] && echo "$JETSON_AUTHORIZED_KEY -> authorized_keys" || echo "(none)")
  Log:         $LOG_FILE

Next steps:
  1. Disconnect the recovery USB-C cable from the Jetson.
  2. Power-cycle the Jetson (it auto-reboots after a successful flash).
  3. The Jetson boots straight to multi-user (no oem-config wizard) and
     gets a DHCP lease on Ethernet.
  4. From your laptop, connect:
       ssh $JETSON_USER@$JETSON_HOSTNAME.local
     (or, once the Twingate connector is reinstalled,
       ssh $JETSON_USER@$JETSON_HOSTNAME.internal)
  5. Install JetPack SDK components on the Jetson:
       sudo apt update
       sudo apt install -y nvidia-jetpack
       echo 'export PATH=/usr/local/cuda/bin:\$PATH' >> ~/.bashrc
       echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH' >> ~/.bashrc
  6. Re-deploy the Twingate connector (see twingate.md in the inventory repo).

============================================================
EOF
}

main "$@"
