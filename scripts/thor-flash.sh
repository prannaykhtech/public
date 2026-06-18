#!/usr/bin/env bash
# thor-flash.sh -- Flash a Jetson AGX Thor (T5000 / T4000) from an Ubuntu host via USB
# recovery mode, pre-seeded for headless first boot (default user, hostname, SSH key,
# passwordless sudo).
#
# RUN ON: an Ubuntu x86_64 host (22.04 / 24.04) with a USB-C cable from the host's
# USB 3.x port to the Thor dev kit's J81 RECOVERY USB-C port, with Thor in Force
# Recovery Mode.
#
# DOES NOT REQUIRE: NVIDIA developer login, SDK Manager, or a GUI. Pure CLI.
#
# Default target: Jetson AGX Thor Developer Kit (T5000, 128GB), JetPack 7.2 (L4T R39.2.0).
#
# THIS IS THE THOR ANALOGUE OF jetson-flash.sh (which targets Orin). Thor differs from
# Orin in several important ways, all baked in here:
#   * Recovery USB PID is 0955:7026 (T5000 128GB) / 0955:7226 (T4000 64GB), not 0955:7023.
#   * apply_binaries.sh MUST be run with --openrm (Thor uses the OpenRM stack / SBSA).
#   * Thor is flashed ONLY via l4t_initrd_flash.sh (QSPI-NOR + NVMe); flash.sh is not
#     supported. "internal" here means the on-board NVMe.
#   * Thor does NOT auto-reboot after a successful flash -- you power-cycle it manually.
#   * The BSP assumes NVMe > 234 GiB. For a smaller drive, set EXT_NUM_SECTORS
#     (see below).
#
# REQUIRED env vars:
#   THOR_HOSTNAME          e.g. guild-thor-1
#   THOR_PASS              console password for the seeded user (>= 8 chars).
#                          SSH should use keys; this is fallback only.
#
# OPTIONAL env vars:
#   THOR_USER              (default: guild)
#   THOR_AUTHORIZED_KEY    path to an SSH public key file to install into authorized_keys
#                          (default: $HOME/.ssh/id_ed25519.pub on the flashing host)
#   THOR_BOARD             (default: jetson-agx-thor-devkit; use jetson-agx-thor-t4000
#                          for the 64GB T4000 module)
#   L4T_RELEASE            (default: 39.2.0)        JetPack 7.2
#   L4T_REPO_DIR           (default: r39_Release_v2.0)
#   EXT_NUM_SECTORS        for NVMe drives < 234 GiB: <drive size in bytes> / 512
#                          (passed straight through to l4t_initrd_flash.sh)
#   WORK_DIR               (default: $HOME/thor-flash/<release>)
#   ASSUME_YES=1           skip the "press ENTER" confirmation
#   SKIP_USB3_CHECK=1      skip the USB-3 link-speed assertion (not recommended -- the
#                          initrd flash pushes a multi-GB NVMe image and is painfully
#                          slow over USB 2)
#
# CLI flags:
#   --clean-apply          unmount stale chroot mounts, kill leftover qemu processes,
#                          remove stale dpkg locks, wipe rootfs/ and the apply markers,
#                          then re-extract rootfs and re-run apply_binaries.sh --openrm.
#                          Use this if a previous run corrupted the rootfs (e.g. broken
#                          setuid). Keeps the BSP extract and the cached tarballs.
#   --help                 print usage
#
# Force-redo env flags (default: skip steps that are already done):
#   FORCE_REINSTALL_PREREQS=1   re-run apt install for host packages
#   FORCE_REEXTRACT=1           wipe Linux_for_Tegra/ and re-extract from tarballs
#   FORCE_REAPPLY=1             re-run apply_binaries.sh --openrm
#   FORCE_RESEED_USER=1         re-run l4t_create_default_user.sh
#   FORCE_REPREQ=1              re-run tools/l4t_flash_prerequisites.sh
#
# To flash a different JetPack 7 patch level (e.g. JetPack 7.0 / L4T R38.2.1):
#   L4T_RELEASE=38.2.1 L4T_REPO_DIR=r38_Release_v2.1 \
#     THOR_HOSTNAME=... THOR_PASS=... bash <(curl -fsSL .../thor-flash.sh)
#
# Usage:
#   THOR_HOSTNAME=guild-thor-1 THOR_PASS='somepass' \
#     bash <(curl -fsSL https://raw.githubusercontent.com/prannaykhtech/public/main/scripts/thor-flash.sh)
#
# Steps:
#   1. preflight: ubuntu host, root sudo, Thor in recovery on USB 3.x port, ModemManager off
#   2. install host prerequisites
#   3. download BSP + sample rootfs (cached in WORK_DIR; resumes partial downloads)
#   4. extract BSP, extract rootfs into Linux_for_Tegra/rootfs/
#   5. l4t_flash_prerequisites.sh        (Thor runs this before apply_binaries)
#   6. apply_binaries.sh --openrm
#   7. pre-seed user via l4t_create_default_user.sh (skips oem-config wizard)
#   8. drop SSH authorized_keys + passwordless sudo into rootfs
#   9. l4t_initrd_flash.sh <board> internal   (QSPI-NOR + NVMe)
#
# Total time: ~40-75 min depending on bandwidth (downloads ~5 GB, initrd flash ~20-30 min).
#
# Logs: $WORK_DIR/flash-<timestamp>.log

set -euo pipefail

# ---------- defaults / overrides ----------
THOR_BOARD="${THOR_BOARD:-jetson-agx-thor-devkit}"
L4T_RELEASE="${L4T_RELEASE:-39.2.0}"
L4T_REPO_DIR="${L4T_REPO_DIR:-r39_Release_v2.0}"
WORK_DIR="${WORK_DIR:-$HOME/thor-flash/$L4T_RELEASE}"

THOR_USER="${THOR_USER:-guild}"
THOR_AUTHORIZED_KEY="${THOR_AUTHORIZED_KEY:-$HOME/.ssh/id_ed25519.pub}"

# JetPack 7 / Thor tarball naming uses CamelCase + capital R, unlike the lowercase
# JetPack 6 / Orin naming. e.g. Jetson_Linux_R39.2.0_aarch64.tbz2
BSP_TARBALL="Jetson_Linux_R${L4T_RELEASE}_aarch64.tbz2"
ROOTFS_TARBALL="Tegra_Linux_Sample-Root-Filesystem_R${L4T_RELEASE}_aarch64.tbz2"
BSP_URL="https://developer.nvidia.com/downloads/embedded/L4T/${L4T_REPO_DIR}/release/${BSP_TARBALL}"
ROOTFS_URL="https://developer.nvidia.com/downloads/embedded/L4T/${L4T_REPO_DIR}/release/${ROOTFS_TARBALL}"

# Thor recovery USB PIDs: 7026 = T5000 (128GB), 7226 = T4000 (64GB).
RECOVERY_PID_RE='0955:(7026|7226)'

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
    log "target:     $THOR_BOARD"
    log "release:    L4T $L4T_RELEASE ($L4T_REPO_DIR)"
    log "work dir:   $WORK_DIR"
    log "user:       $THOR_USER@${THOR_HOSTNAME:-<unset>}"
    log "ssh key:    $THOR_AUTHORIZED_KEY"

    [ "$(uname -m)" = "x86_64" ] || die "must run on x86_64 (got $(uname -m))."
    [ "$(uname -s)" = "Linux" ] || die "must run on Linux."

    require_env THOR_HOSTNAME
    require_env THOR_PASS
    [ "${#THOR_PASS}" -ge 8 ] || die "THOR_PASS must be >= 8 chars."

    if ! command -v sudo >/dev/null; then die "sudo is required."; fi
    sudo -n true 2>/dev/null || die "passwordless sudo required (or run as root)."

    if [ -n "$THOR_AUTHORIZED_KEY" ] && [ ! -f "$THOR_AUTHORIZED_KEY" ]; then
        die "THOR_AUTHORIZED_KEY=$THOR_AUTHORIZED_KEY does not exist. Provide a valid public key file or unset to skip SSH key setup."
    fi
    if [ -n "$THOR_AUTHORIZED_KEY" ] && ! grep -qE '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2)' "$THOR_AUTHORIZED_KEY"; then
        die "THOR_AUTHORIZED_KEY=$THOR_AUTHORIZED_KEY does not look like a valid SSH public key."
    fi

    if ! lsusb | grep -qE "$RECOVERY_PID_RE"; then
        log "lsusb output:"
        lsusb | sed 's/^/  /'
        die "Thor not visible in recovery mode. Expected USB device 0955:7026 (T5000) or 0955:7226 (T4000), NVIDIA APX. Power off, hold the Force Recovery button, tap Power, release Force Recovery, with USB-C from the J81 recovery port to this host."
    fi
    log "Thor detected: $(lsusb | grep -E "$RECOVERY_PID_RE")"

    if [ "${SKIP_USB3_CHECK:-0}" != "1" ]; then
        local thor_line link_speed pid
        thor_line=$(lsusb -t 2>/dev/null | grep -E "0955" || true)
        link_speed=$(echo "$thor_line" | grep -oE '[0-9]+M' | head -1 || true)
        if [ -z "$link_speed" ]; then
            pid=$(lsusb | grep -oE "$RECOVERY_PID_RE" | head -1)
            local bcd
            bcd=$(lsusb -v -d "$pid" 2>/dev/null | awk '/bcdUSB/ {print $2; exit}' || true)
            case "$bcd" in
                3.*) link_speed="5000M" ;;
                2.*) link_speed="480M" ;;
                1.*) link_speed="12M" ;;
                *)   link_speed="unknown" ;;
            esac
        fi
        log "Thor link speed: $link_speed"
        case "$link_speed" in
            10000M|5000M)
                log "  USB 3.x link OK."
                ;;
            480M|12M|unknown)
                log ""
                log "  WARNING: Thor is connected at USB 2 speed or lower."
                log "  The Thor flash uses l4t_initrd_flash.sh, which transfers a multi-GB NVMe"
                log "  image over the link. On USB 2 this is extremely slow and prone to timeouts."
                log "  Move the host-side USB-C cable to a USB 3.x port and re-trigger recovery."
                log "  To proceed anyway, set SKIP_USB3_CHECK=1."
                die "USB link speed below USB 3 (got $link_speed). Set SKIP_USB3_CHECK=1 to override."
                ;;
        esac
    fi

    if systemctl is-active --quiet ModemManager 2>/dev/null; then
        log "Stopping ModemManager (steals Thor recovery handshake)."
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
    lz4
    device-tree-compiler
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

    local bsp_marker="Linux_for_Tegra/apply_binaries.sh"
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
        # Extract as root so ownership/permissions in the tarball are preserved
        # (including setuid bits on /usr/bin/sudo, /bin/su, /usr/bin/mount, etc.).
        # DO NOT chown -R root:root afterwards -- chown strips setuid by design,
        # which silently breaks the chrooted apply_binaries and the on-target sudo.
        sudo tar xpf "$WORK_DIR/downloads/$ROOTFS_TARBALL" \
            -C "$WORK_DIR/Linux_for_Tegra/rootfs"
        [ -f "$rootfs_marker" ] || die "rootfs extract failed -- $rootfs_marker missing."

        # Sanity check: the sample rootfs should ship sudo as setuid root.
        local sudo_path="$WORK_DIR/Linux_for_Tegra/rootfs/usr/bin/sudo"
        if [ -f "$sudo_path" ] && ! sudo find "$sudo_path" -perm -4000 -user root | grep -q .; then
            die "post-extract: $sudo_path is not setuid-root. Tarball or extraction is bad."
        fi
    fi
}

# Clean up chroot leftovers from a previous (interrupted) apply_binaries.sh:
#   - bind mounts under rootfs/ (proc, sys, dev/pts)
#   - /dev nodes that mknod re-collides on
#   - dpkg/apt lock files held by a now-dead chroot dpkg
cleanup_chroot_state() {
    local rootfs="$WORK_DIR/Linux_for_Tegra/rootfs"
    [ -d "$rootfs" ] || return 0

    if mount | grep -q "$rootfs"; then
        log "  unmounting stale chroot mounts under rootfs/"
        mount | awk -v r="$rootfs" '$3 ~ r {print $3}' | tac | xargs -r sudo umount -lf
    fi

    for d in random urandom null zero console tty full ptmx; do
        sudo rm -f "$rootfs/dev/$d" 2>/dev/null || true
    done

    # Stale dpkg/apt locks from a previous chroot-dpkg that was killed.
    # These are normally owned by a now-dead PID; safe to remove on the host.
    for lock in \
        var/lib/dpkg/lock \
        var/lib/dpkg/lock-frontend \
        var/lib/apt/lists/lock \
        var/cache/apt/archives/lock; do
        sudo rm -f "$rootfs/$lock" 2>/dev/null || true
    done

    # Kill any qemu-aarch64-static or chroot-rooted dpkg processes still alive
    # from a previous apply_binaries that was Ctrl-C'd.
    if pgrep -f "qemu-aarch64-static.*$rootfs" >/dev/null 2>&1; then
        log "  killing leftover qemu-aarch64-static processes from previous run"
        sudo pkill -9 -f "qemu-aarch64-static.*$rootfs" || true
    fi
}

# ---------- step 5: l4t_flash_prerequisites ----------
# Thor runs this before apply_binaries (per the JetPack 7 Quick Start).
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
        die "tools/l4t_flash_prerequisites.sh missing -- BSP layout unexpected."
    fi
}

# ---------- step 6: apply_binaries (--openrm for Thor) ----------
apply_binaries() {
    log "=== apply_binaries.sh --openrm ==="
    cd "$WORK_DIR/Linux_for_Tegra"
    local marker=".apply_binaries.done"
    if [ "${FORCE_REAPPLY:-0}" != "1" ] && [ -f "$marker" ]; then
        log "  apply_binaries already done ($marker present); skipping."
        return 0
    fi
    cleanup_chroot_state
    sudo ./apply_binaries.sh --openrm
    sudo touch "$marker"
}

# ---------- step 7: pre-seed default user (skip oem-config) ----------
preseed_user() {
    log "=== pre-seed default user $THOR_USER@$THOR_HOSTNAME ==="
    cd "$WORK_DIR/Linux_for_Tegra"
    if [ ! -x tools/l4t_create_default_user.sh ]; then
        die "tools/l4t_create_default_user.sh missing -- BSP layout unexpected."
    fi

    local rootfs_passwd="rootfs/etc/passwd"
    local rootfs_hostname="rootfs/etc/hostname"
    if [ "${FORCE_RESEED_USER:-0}" != "1" ] \
       && [ -f "$rootfs_passwd" ] \
       && grep -q "^${THOR_USER}:" "$rootfs_passwd" \
       && [ -f "$rootfs_hostname" ] \
       && [ "$(cat "$rootfs_hostname" 2>/dev/null)" = "$THOR_HOSTNAME" ]; then
        log "  user '$THOR_USER' and hostname '$THOR_HOSTNAME' already in rootfs; skipping."
        return 0
    fi

    sudo ./tools/l4t_create_default_user.sh \
        -u "$THOR_USER" \
        -p "$THOR_PASS" \
        -n "$THOR_HOSTNAME" \
        --accept-license
    log "  default user '$THOR_USER' seeded with hostname '$THOR_HOSTNAME'; oem-config wizard disabled."
}

# ---------- step 8: ssh key + passwordless sudo into rootfs ----------
seed_remote_access() {
    log "=== seed SSH authorized_keys + passwordless sudo ==="
    local ROOTFS="$WORK_DIR/Linux_for_Tegra/rootfs"
    local USER_HOME="$ROOTFS/home/$THOR_USER"

    if [ ! -d "$USER_HOME" ]; then
        die "$USER_HOME missing -- pre-seed step did not create user home."
    fi

    # SSH key
    if [ -n "$THOR_AUTHORIZED_KEY" ] && [ -f "$THOR_AUTHORIZED_KEY" ]; then
        local AK="$USER_HOME/.ssh/authorized_keys"
        if [ -f "$AK" ] && sudo cmp -s "$THOR_AUTHORIZED_KEY" "$AK"; then
            log "  ssh authorized_keys already installed and matches; skipping."
        else
            log "  installing ssh public key from $THOR_AUTHORIZED_KEY"
            sudo mkdir -p "$USER_HOME/.ssh"
            sudo cp "$THOR_AUTHORIZED_KEY" "$AK"
            sudo chmod 700 "$USER_HOME/.ssh"
            sudo chmod 600 "$AK"
            # l4t_create_default_user.sh sets uid 1000 / gid 1000 for the seeded user.
            sudo chown -R 1000:1000 "$USER_HOME/.ssh"
        fi
    else
        log "  no SSH key provided; skipping authorized_keys setup."
    fi

    # passwordless sudo
    local SUDOERS_DIR="$ROOTFS/etc/sudoers.d"
    local SUDOERS_FILE="$SUDOERS_DIR/$THOR_USER"
    local SUDOERS_LINE="$THOR_USER ALL=(ALL) NOPASSWD: ALL"
    if [ -f "$SUDOERS_FILE" ] && sudo grep -qxF "$SUDOERS_LINE" "$SUDOERS_FILE"; then
        log "  sudoers entry for '$THOR_USER' already present; skipping."
    else
        log "  installing /etc/sudoers.d/$THOR_USER (NOPASSWD: ALL)"
        sudo mkdir -p "$SUDOERS_DIR"
        echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" >/dev/null
        sudo chmod 0440 "$SUDOERS_FILE"
        sudo chown 0:0 "$SUDOERS_FILE"
    fi

    # Make sure ssh is enabled at boot. The sample rootfs ships openssh-server
    # installed but the service can be disabled by default; enable it offline.
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

# Locate the initrd flash script (top-level symlink or under tools/kernel_flash).
initrd_flash_path() {
    if [ -x "$WORK_DIR/Linux_for_Tegra/l4t_initrd_flash.sh" ]; then
        echo "./l4t_initrd_flash.sh"
    elif [ -x "$WORK_DIR/Linux_for_Tegra/tools/kernel_flash/l4t_initrd_flash.sh" ]; then
        echo "./tools/kernel_flash/l4t_initrd_flash.sh"
    else
        die "l4t_initrd_flash.sh not found (looked at top level and tools/kernel_flash/)."
    fi
}

# ---------- step 9: flash (initrd, QSPI-NOR + NVMe) ----------
flash_device() {
    log "=== flash $THOR_BOARD (initrd, QSPI-NOR + NVMe) ==="
    cd "$WORK_DIR/Linux_for_Tegra"
    if ! lsusb | grep -qE "$RECOVERY_PID_RE"; then
        die "Thor no longer in recovery mode. Re-trigger recovery and re-run flash."
    fi
    local flash_sh
    flash_sh=$(initrd_flash_path)
    log "  using $flash_sh"
    if [ -n "${EXT_NUM_SECTORS:-}" ]; then
        log "  EXT_NUM_SECTORS=$EXT_NUM_SECTORS (small-NVMe override)"
        sudo EXT_NUM_SECTORS="$EXT_NUM_SECTORS" "$flash_sh" "$THOR_BOARD" internal
    else
        sudo "$flash_sh" "$THOR_BOARD" internal
    fi
    log "=== flash complete ==="
}

# ---------- --clean-apply ----------
# Wipe rootfs + apply marker + chroot leftovers so the next run cleanly
# re-extracts the sample rootfs and re-runs apply_binaries.sh. Keeps the
# BSP extract and the cached tarballs (those aren't corrupted).
clean_apply() {
    log "=== --clean-apply ==="
    local lft="$WORK_DIR/Linux_for_Tegra"

    if [ ! -d "$lft" ]; then
        log "  $lft not present; nothing to clean."
        return 0
    fi

    cleanup_chroot_state

    if [ -d "$lft/rootfs" ]; then
        log "  removing $lft/rootfs (will be re-extracted from cached tarball)"
        sudo rm -rf "$lft/rootfs"
        mkdir -p "$lft/rootfs"
    fi

    sudo rm -f "$lft/.apply_binaries.done" "$lft/.l4t_flash_prereqs.done" 2>/dev/null

    log "  ready for clean apply_binaries on next run."
}

usage() {
    cat <<EOF
usage: thor-flash.sh [--clean-apply] [--help]

  --clean-apply   wipe rootfs + apply markers, unmount stale chroot mounts,
                  kill stale qemu processes, and remove stale dpkg locks before
                  proceeding. Use this if a previous run was interrupted or
                  left rootfs in a corrupted state (e.g. setuid bits stripped).
  --help          this message

See the script header for required and optional environment variables.
EOF
}

# ---------- driver ----------
main() {
    local DO_CLEAN_APPLY=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --clean-apply) DO_CLEAN_APPLY=1; shift ;;
            -h|--help)     usage; exit 0 ;;
            *) die "unknown argument: $1 (try --help)" ;;
        esac
    done

    ensure_log
    log "log: $LOG_FILE"

    preflight
    install_prereqs
    download

    if [ "$DO_CLEAN_APPLY" = "1" ]; then
        clean_apply
    fi

    extract
    flash_prereqs
    apply_binaries
    preseed_user
    seed_remote_access
    flash_device

    cat <<EOF

============================================================
  FLASH COMPLETE
============================================================
  Board:       $THOR_BOARD
  Release:     L4T $L4T_RELEASE
  Hostname:    $THOR_HOSTNAME
  User:        $THOR_USER (passwordless sudo)
  SSH key:     $([ -f "$THOR_AUTHORIZED_KEY" ] && echo "$THOR_AUTHORIZED_KEY -> authorized_keys" || echo "(none)")
  Log:         $LOG_FILE

Next steps:
  1. Thor does NOT auto-reboot after a successful flash. Disconnect the
     recovery USB-C cable and power-cycle the dev kit.
  2. On reboot, select the NVMe drive from the UEFI boot menu if it is not
     already the default boot device.
  3. The board boots straight to multi-user (no oem-config wizard) and gets a
     DHCP lease on Ethernet.
  4. From your laptop, connect:
       ssh $THOR_USER@$THOR_HOSTNAME.local
     (or, once a Twingate connector is deployed,
       ssh $THOR_USER@$THOR_HOSTNAME.internal)
  5. Install JetPack SDK components on the Thor:
       sudo apt update
       sudo apt install -y nvidia-jetpack
       echo 'export PATH=/usr/local/cuda/bin:\$PATH' >> ~/.bashrc
       echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH' >> ~/.bashrc
  6. Deploy the Twingate connector (see twingate.md in the inventory repo).

============================================================
EOF
}

main "$@"
