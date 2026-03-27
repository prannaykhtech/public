#!/bin/bash
set -e

# Bootstrap script for new Linux machines (Ubuntu/Debian and RHEL/Fedora).
# Sets up SSH, power management, passwordless sudo, Docker Engine, and Twingate-readiness.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/prannaykhtech/public/main/scripts/bootstrap-linux.sh | bash -s -- <hostname> <username>
#
# Example:
#   curl -fsSL https://raw.githubusercontent.com/prannaykhtech/public/main/scripts/bootstrap-linux.sh | bash -s -- <hostname> <username>

HOSTNAME="${1:?Usage: $0 <hostname> <username>}"
USERNAME="${2:?Usage: $0 <hostname> <username>}"

# Detect package manager
if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
else
    echo "ERROR: No supported package manager found (apt, dnf, yum)."
    exit 1
fi

echo "============================================"
echo "  Linux Bootstrap"
echo "  Hostname: $HOSTNAME"
echo "  Username: $USERNAME"
echo "  Package manager: $PKG_MANAGER"
echo "============================================"
echo ""

# --- 1. Set hostname ---
echo "[1/7] Setting hostname to $HOSTNAME ..."
sudo hostnamectl set-hostname "$HOSTNAME"
if ! grep -q "$HOSTNAME" /etc/hosts; then
    echo "127.0.1.1 $HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
fi
echo "  Done."

# --- 2. Enable SSH ---
echo "[2/7] Enabling SSH ..."
if [ "$PKG_MANAGER" = "apt" ]; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq openssh-server > /dev/null
elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
    sudo $PKG_MANAGER install -y -q openssh-server > /dev/null
fi
sudo systemctl enable ssh sshd 2>/dev/null || true
sudo systemctl start ssh sshd 2>/dev/null || true
echo "  SSH enabled and started."

# --- 3. Power & sleep settings ---
echo "[3/7] Configuring power settings ..."
# Disable suspend/hibernate/sleep
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
# Disable lid close suspend (for mini PCs / laptops used as servers)
if [ -f /etc/systemd/logind.conf ]; then
    sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
    sudo sed -i 's/^#\?HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
    sudo systemctl restart systemd-logind 2>/dev/null || true
fi
echo "  Sleep/suspend/hibernate: DISABLED"
echo "  Note: Auto-restart on power loss is typically a BIOS/UEFI setting."
echo "        Set 'Restore on AC Power Loss' to 'Power On' in BIOS."

# --- 4. Passwordless sudo ---
echo "[4/7] Setting up passwordless sudo for $USERNAME ..."
# Create user if it doesn't exist
if ! id "$USERNAME" &>/dev/null; then
    sudo useradd -m -s /bin/bash "$USERNAME"
    sudo usermod -aG sudo "$USERNAME" 2>/dev/null || sudo usermod -aG wheel "$USERNAME" 2>/dev/null || true
    echo "  Created user $USERNAME."
fi
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/$USERNAME" > /dev/null
sudo chmod 440 "/etc/sudoers.d/$USERNAME"
echo "  Done."

# --- 5. Install essential packages ---
echo "[5/7] Installing essential packages ..."
if [ "$PKG_MANAGER" = "apt" ]; then
    sudo apt-get install -y -qq curl wget git ca-certificates gnupg lsb-release avahi-daemon > /dev/null
elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
    sudo $PKG_MANAGER install -y -q curl wget git ca-certificates gnupg avahi > /dev/null
fi
# Enable mDNS (.local hostname resolution)
sudo systemctl enable avahi-daemon 2>/dev/null || true
sudo systemctl start avahi-daemon 2>/dev/null || true
echo "  Done. mDNS enabled ($HOSTNAME.local will resolve on LAN)."

# --- 6. Install Docker Engine ---
echo "[6/7] Installing Docker Engine ..."
if command -v docker &>/dev/null; then
    echo "  Docker already installed, skipping."
else
    if [ "$PKG_MANAGER" = "apt" ]; then
        sudo install -m 0755 -d /etc/apt/keyrings
        DISTRO=$(. /etc/os-release && echo "$ID")
        curl -fsSL "https://download.docker.com/linux/$DISTRO/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DISTRO $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
    elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        sudo $PKG_MANAGER install -y -q dnf-plugins-core > /dev/null 2>&1 || true
        sudo $PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null || \
        sudo $PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
        sudo $PKG_MANAGER install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
    fi
fi
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker "$USERNAME"
echo "  Docker installed and enabled at boot."
echo "  User $USERNAME added to docker group (re-login required for non-sudo docker)."

# --- 7. Print summary ---
echo ""
echo "[7/7] Verifying ..."
LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
DOCKER_OK=$(sudo docker info >/dev/null 2>&1 && echo "YES" || echo "NO")
SSH_OK=$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo "UNKNOWN")

echo ""
echo "============================================"
echo "  Bootstrap Complete"
echo "============================================"
echo "  Hostname:        $HOSTNAME"
echo "  Username:        $USERNAME"
echo "  LAN IP:          $LAN_IP"
echo "  SSH:             $SSH_OK"
echo "  Docker:          $DOCKER_OK"
echo "  Passwordless sudo: YES"
echo "  Sleep/suspend:   DISABLED"
echo "============================================"
echo ""
echo "Next steps (from your laptop):"
echo "  1. Copy SSH key:  ssh-copy-id -i ~/.ssh/id_ed25519.pub $USERNAME@$LAN_IP"
echo "  2. Test SSH:      ssh $USERNAME@$HOSTNAME.local"
echo "  3. Deploy Twingate connector (via remote SSH)"
echo ""
