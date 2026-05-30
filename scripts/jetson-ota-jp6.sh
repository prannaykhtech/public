#!/usr/bin/env bash
# jetson-ota-jp6.sh -- Apt-based OTA upgrade from JetPack 5.x to a pinned JetPack 6.x.
#
# RUN ON: a Jetson Orin device currently on JetPack 5.x (Ubuntu 20.04, L4T r35.x).
# DO NOT RUN: on JetPack 4 / Xavier / Nano / Thor.
#
# RUN INSIDE tmux. Across reboots, re-run the same command -- the script picks up where it left off
# via a state file at /var/lib/jetson-ota-jp6/state.
#
#   ssh guild@<host>
#   tmux new -s ota
#   curl -fsSL https://raw.githubusercontent.com/prannaykhtech/public/main/scripts/jetson-ota-jp6.sh | sudo bash -s --
#   # (machine reboots automatically when needed; reconnect, re-attach tmux, re-run the same line)
#
# RISK: cross-major OTA (JP5 -> JP6) is not officially supported by NVIDIA via apt.
# Bootloader/QSPI is rewritten. If it fails mid-flash, recovery requires a host PC + USB-C
# in Force Recovery Mode. There is no remote recovery path for that failure mode.
#
# Pinned target:
#   JetPack    : 6.2.2
#   L4T        : R36.4 (suite "r36.4" in the apt repo)
#   nvidia-jetpack version pin: 6.2.2+b77   (set via TARGET_JETPACK_VERSION below)
# If the pinned version is no longer in the apt repo when you run this, override with:
#   TARGET_JETPACK_VERSION=<version> ./jetson-ota-jp6.sh
#
# Logs: /var/log/jetson-ota-jp6/<timestamp>.log (also tee'd to stdout)
# State: /var/lib/jetson-ota-jp6/state -- one of: fresh, sources_swapped, dist_upgraded, jetpack_installed, done
#
# What it does, in order:
#   1. pre-flight: confirm Orin + JP5 + free disk + power notes
#   2. snapshot dpkg/apt state to log dir
#   3. swap apt sources from r35.x -> r36.4 (Ubuntu 22.04 jammy in upstream sources)
#   4. apt update + dist-upgrade for the BSP layer; reboot
#   5. install nvidia-jetpack pinned to TARGET_JETPACK_VERSION; reboot
#   6. verify: nv_tegra_release shows R36.4, nvidia-jetpack installed, nvcc + tensorrt present
#
# Idempotent across reboots. Safe to re-run.

set -euo pipefail

# ---------- pinned versions ----------
TARGET_JETPACK_MAJOR_MINOR="6.2"
TARGET_JETPACK_VERSION="${TARGET_JETPACK_VERSION:-6.2.2+b77}"
TARGET_L4T_SUITE="r36.4"
TARGET_UBUNTU_CODENAME="jammy"
EXPECTED_RELEASE_PREFIX="R36"

# ---------- paths ----------
STATE_DIR="/var/lib/jetson-ota-jp6"
STATE_FILE="$STATE_DIR/state"
LOG_DIR="/var/log/jetson-ota-jp6"
LOG_FILE="$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ).log"

# ---------- helpers ----------
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" = "0" ] || die "must run as root (use sudo)."
}

read_state() {
    [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "fresh"
}

write_state() {
    mkdir -p "$STATE_DIR"
    echo "$1" > "$STATE_FILE"
    log "state -> $1"
}

ensure_log_dir() {
    mkdir -p "$LOG_DIR"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

confirm_or_abort() {
    if [ "${ASSUME_YES:-0}" = "1" ]; then return 0; fi
    log "Press ENTER to continue, Ctrl-C to abort."
    read -r _
}

reboot_now() {
    log "Rebooting in 10s. Reconnect, re-attach tmux ('tmux attach -t ota'), and re-run the same command."
    sleep 10
    /sbin/reboot
    exit 0
}

# ---------- step 0: pre-flight ----------
preflight() {
    log "=== preflight ==="

    local model
    model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
    log "model: $model"
    case "$model" in
        *Orin*) ;;
        *) die "this script targets Jetson Orin family. Detected: $model" ;;
    esac

    if [ ! -f /etc/nv_tegra_release ]; then
        die "/etc/nv_tegra_release missing -- not an L4T system."
    fi
    log "current BSP: $(head -1 /etc/nv_tegra_release)"

    if grep -qE "^# R3[6-9] " /etc/nv_tegra_release; then
        log "already on R36+; preflight will let later steps decide if work remains."
    elif ! grep -qE "^# R35 " /etc/nv_tegra_release; then
        die "expected current BSP R35 (JP5). Refusing to proceed."
    fi

    local free_gb
    free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
    log "free disk on /: ${free_gb} GB"
    [ "${free_gb:-0}" -ge 10 ] || die "need at least 10 GB free on /, have ${free_gb} GB."

    if ! curl -sfI https://repo.download.nvidia.com/jetson/ >/dev/null; then
        die "cannot reach repo.download.nvidia.com -- check network."
    fi
    log "network ok."

    log "POWER WARNING: do not power-cycle the device while this is running."
    log "BRICK WARNING: cross-major OTA may fail. Recovery requires USB-C + host PC."
    confirm_or_abort
}

# ---------- step 1: snapshot ----------
snapshot() {
    log "=== snapshot ==="
    ensure_log_dir
    dpkg -l | tee "$LOG_DIR/dpkg-pre.txt" >/dev/null
    cp -a /etc/apt/sources.list.d "$LOG_DIR/sources.list.d.pre" 2>/dev/null || true
    log "snapshot saved to $LOG_DIR/"
}

# ---------- step 2: swap apt sources ----------
swap_sources() {
    log "=== swap apt sources to $TARGET_L4T_SUITE ==="

    local nv_src=/etc/apt/sources.list.d/nvidia-l4t-apt-source.list
    [ -f "$nv_src" ] || die "$nv_src missing."

    cp -a "$nv_src" "$nv_src.bak.$(date +%s)"

    cat > "$nv_src" <<EOF
# JetPack ${TARGET_JETPACK_MAJOR_MINOR} -- pinned by jetson-ota-jp6.sh
deb https://repo.download.nvidia.com/jetson/common ${TARGET_L4T_SUITE} main
deb https://repo.download.nvidia.com/jetson/t234   ${TARGET_L4T_SUITE} main
EOF
    log "wrote new $nv_src:"
    sed 's/^/  /' "$nv_src"

    if [ -f /etc/apt/sources.list ]; then
        sed -i.bak.$(date +%s) -E 's/(focal)/jammy/g' /etc/apt/sources.list
        log "switched ubuntu suite focal -> jammy in /etc/apt/sources.list"
    fi
    for f in /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] || continue
        case "$f" in
            *nvidia-l4t-apt-source.list*|*.bak.*) continue ;;
        esac
        if grep -q "focal" "$f"; then
            sed -i.bak.$(date +%s) -E 's/(focal)/jammy/g' "$f"
            log "switched focal -> jammy in $f"
        fi
    done

    apt-get update
    log "apt update ok."
}

# ---------- step 3: dist-upgrade BSP ----------
dist_upgrade_bsp() {
    log "=== dist-upgrade (kernel + BSP + userland to 22.04) ==="

    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        -y dist-upgrade

    log "dist-upgrade done. BSP: $(head -1 /etc/nv_tegra_release || echo unknown)"
}

# ---------- step 4: install nvidia-jetpack ----------
install_jetpack() {
    log "=== install nvidia-jetpack=$TARGET_JETPACK_VERSION ==="

    apt-get update

    if ! apt-cache madison nvidia-jetpack | awk '{print $3}' | grep -qx "$TARGET_JETPACK_VERSION"; then
        log "WARN: nvidia-jetpack=$TARGET_JETPACK_VERSION not found in apt repo. Available:"
        apt-cache madison nvidia-jetpack || true
        die "pinned version unavailable. Override with TARGET_JETPACK_VERSION=<version> and re-run."
    fi

    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        -y install \
        "nvidia-jetpack=$TARGET_JETPACK_VERSION"

    log "nvidia-jetpack installed."
}

# ---------- step 5: verify ----------
verify() {
    log "=== verify ==="
    head -1 /etc/nv_tegra_release || true
    dpkg -l nvidia-jetpack | tail -1 || true
    if [ -x /usr/local/cuda/bin/nvcc ]; then
        /usr/local/cuda/bin/nvcc --version | tail -2
    else
        log "WARN: /usr/local/cuda/bin/nvcc missing."
    fi
    if dpkg -l | grep -q "^ii  libnvinfer"; then
        dpkg -l | grep "^ii  libnvinfer" | awk '{print $2, $3}' | head -3
    else
        log "WARN: libnvinfer not installed."
    fi
    log "free disk: $(df -h / | tail -1)"
}

# ---------- driver ----------
main() {
    require_root
    ensure_log_dir
    log "log file: $LOG_FILE"
    log "target: JetPack $TARGET_JETPACK_MAJOR_MINOR ($TARGET_JETPACK_VERSION) / L4T $TARGET_L4T_SUITE"

    local s
    s=$(read_state)
    log "starting state: $s"

    case "$s" in
        fresh|sources_swapped|dist_upgraded|jetpack_installed|done) ;;
        *) die "unknown state: $s" ;;
    esac

    if [ "$s" = "fresh" ]; then
        preflight
        snapshot
        swap_sources
        write_state sources_swapped
        s=sources_swapped
    fi

    if [ "$s" = "sources_swapped" ]; then
        dist_upgrade_bsp
        write_state dist_upgraded
        log "BSP dist-upgrade complete -- rebooting before installing nvidia-jetpack."
        reboot_now
    fi

    if [ "$s" = "dist_upgraded" ]; then
        install_jetpack
        write_state jetpack_installed
        log "nvidia-jetpack installed -- rebooting to settle drivers."
        reboot_now
    fi

    if [ "$s" = "jetpack_installed" ]; then
        verify
        write_state done
        log "=== DONE. JetPack $TARGET_JETPACK_VERSION up. ==="
        return 0
    fi

    if [ "$s" = "done" ]; then
        log "already done. State file says 'done'. Re-run with: rm $STATE_FILE  to start over."
        verify
        return 0
    fi
}

main "$@"
