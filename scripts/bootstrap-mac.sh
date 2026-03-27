#!/bin/bash
set -e

# Bootstrap script for new Mac Mini machines.
# Sets up SSH, power management, passwordless sudo, Homebrew, Colima (Docker), and Twingate-readiness.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/prannaykhtech/public/main/scripts/bootstrap-mac.sh | bash -s -- <hostname> <username>
#
# Example:
#   curl -fsSL https://raw.githubusercontent.com/prannaykhtech/public/main/scripts/bootstrap-mac.sh | bash -s -- <hostname> <username>

HOSTNAME="${1:?Usage: $0 <hostname> <username>}"
USERNAME="${2:?Usage: $0 <hostname> <username>}"

echo "============================================"
echo "  Mac Mini Bootstrap"
echo "  Hostname: $HOSTNAME"
echo "  Username: $USERNAME"
echo "============================================"
echo ""

# --- 1. Set hostname ---
echo "[1/7] Setting hostname to $HOSTNAME ..."
sudo scutil --set HostName "$HOSTNAME"
sudo scutil --set LocalHostName "$HOSTNAME"
sudo scutil --set ComputerName "$HOSTNAME"
echo "  Done."

# --- 2. Enable SSH (Remote Login) ---
echo "[2/7] Enabling SSH (Remote Login) ..."
# Try systemsetup first; fall back to launchctl if it fails (requires Full Disk Access)
if sudo systemsetup -setremotelogin on 2>/dev/null; then
    echo "  SSH enabled via systemsetup."
else
    echo "  systemsetup failed (needs Full Disk Access). Trying launchctl ..."
    sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
    # Verify
    if sudo launchctl list | grep -q "com.openssh.sshd"; then
        echo "  SSH enabled via launchctl."
    else
        echo "  WARNING: Could not enable SSH automatically."
        echo "  Please enable manually: System Settings > General > Sharing > Remote Login"
        echo "  Press Enter to continue after enabling SSH, or Ctrl+C to abort."
        read -r
    fi
fi

# --- 3. Power & sleep settings ---
echo "[3/7] Configuring power settings ..."
sudo pmset -a autorestart 1
sudo pmset -a sleep 0
sudo pmset -a disablesleep 1
sudo pmset -a displaysleep 10
sudo pmset -a womp 1           # Wake on network access
echo "  Auto-restart on power loss: ON"
echo "  Sleep: DISABLED"
echo "  Wake on LAN: ON"

# --- 4. Passwordless sudo ---
echo "[4/7] Setting up passwordless sudo for $USERNAME ..."
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/$USERNAME" > /dev/null
sudo chmod 440 "/etc/sudoers.d/$USERNAME"
echo "  Done."

# --- 5. Install Homebrew ---
echo "[5/7] Installing Homebrew ..."
if command -v /opt/homebrew/bin/brew &>/dev/null; then
    echo "  Homebrew already installed, skipping."
else
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"
if ! grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
    echo >> "$HOME/.zprofile"
    echo 'eval "$(/opt/homebrew/bin/brew shellenv zsh)"' >> "$HOME/.zprofile"
fi
echo "  Done."

# --- 6. Install Colima & Docker ---
echo "[6/7] Installing Colima & Docker CLI ..."
brew install colima docker 2>/dev/null || true
colima start 2>/dev/null || true

# Fix Docker credential store
mkdir -p "$HOME/.docker"
echo '{"auths":{},"currentContext":"colima"}' > "$HOME/.docker/config.json"

# Register Colima as boot service
sudo tee /Library/LaunchDaemons/com.colima.plist > /dev/null << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.colima</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/colima</string>
        <string>start</string>
        <string>--foreground</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>UserName</key>
    <string>$USERNAME</string>
    <key>StandardOutPath</key>
    <string>/tmp/colima.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/colima.stderr.log</string>
</dict>
</plist>
EOF
sudo chmod 644 /Library/LaunchDaemons/com.colima.plist
sudo chown root:wheel /Library/LaunchDaemons/com.colima.plist
sudo launchctl load /Library/LaunchDaemons/com.colima.plist 2>/dev/null || true
echo "  Colima installed and registered as boot service."

# --- 7. Print summary ---
echo ""
echo "[7/7] Verifying ..."
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "unknown")
if [ "$LAN_IP" = "unknown" ]; then
    LAN_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | head -1 | awk '{print $2}')
fi
DOCKER_OK=$(docker info >/dev/null 2>&1 && echo "YES" || echo "NO")
SSH_OK=$(sudo launchctl list 2>/dev/null | grep -q "com.openssh.sshd" && echo "YES" || echo "UNKNOWN")

echo ""
echo "============================================"
echo "  Bootstrap Complete"
echo "============================================"
echo "  Hostname:       $HOSTNAME"
echo "  Username:       $USERNAME"
echo "  LAN IP:         $LAN_IP"
echo "  SSH:            $SSH_OK"
echo "  Docker (Colima):$DOCKER_OK"
echo "  Passwordless sudo: YES"
echo "  Auto-restart:   YES"
echo "  Sleep:          DISABLED"
echo "============================================"
echo ""
echo "Next steps (from your laptop):"
echo "  1. Copy SSH key:  ssh-copy-id -i ~/.ssh/id_ed25519.pub -o AddressFamily=inet $USERNAME@$LAN_IP"
echo "  2. Test SSH:      ssh $USERNAME@$HOSTNAME.local"
echo "  3. Deploy Twingate connector (via remote SSH)"
echo ""
