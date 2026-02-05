#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" ]]; then
  echo "Run via sudo from a real user: sudo $0"
  exit 1
fi

USER_HOME="$(dscl . -read /Users/"$TARGET_USER" NFSHomeDirectory | awk '{print $2}')"
BREW="/usr/local/bin/brew"

run_as_user() {
  sudo -u "$TARGET_USER" env -i \
    HOME="$USER_HOME" \
    USER="$TARGET_USER" \
    LOGNAME="$TARGET_USER" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash -lc "$*"
}

if [[ -z "${REALVNC_VNC_PASSWORD:-}" ]]; then
  echo "REALVNC_VNC_PASSWORD is required (set it in .env)."
  exit 1
fi

if [[ ! -x "$BREW" ]]; then
  echo "Homebrew not found at $BREW. Run brew step first."
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale CLI not found. Run tailscale step first."
  exit 1
fi

TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [[ -z "$TS_IP" ]]; then
  echo "No Tailscale IPv4 detected. Ensure Tailscale is running/logged in, then rerun."
  exit 1
fi

LISTEN_IP="${REALVNC_LISTEN_IP:-$TS_IP}"

echo "Installing RealVNC Server (brew cask) as user: $TARGET_USER"
run_as_user "$BREW list --cask vnc-server >/dev/null 2>&1 || $BREW install --cask vnc-server"

# vncpasswd is installed by RealVNC Server
VNC_PASSWD_BIN="/usr/bin/vncpasswd"
if [[ ! -x "$VNC_PASSWD_BIN" ]]; then
  # Some installs place tools under /usr/local/bin or in the app bundle; try PATH
  VNC_PASSWD_BIN="$(command -v vncpasswd || true)"
fi

if [[ -z "${VNC_PASSWD_BIN:-}" || ! -x "$VNC_PASSWD_BIN" ]]; then
  echo "vncpasswd tool not found. RealVNC install may not have completed correctly."
  exit 1
fi

echo "Configuring RealVNC Server to listen only on: $LISTEN_IP"
echo "Setting VNC password (VNC Password auth)..."

# Feed password twice to vncpasswd.
# vncpasswd stores the encoded password in the appropriate config file. :contentReference[oaicite:4]{index=4}
printf '%s\n%s\n' "$REALVNC_VNC_PASSWORD" "$REALVNC_VNC_PASSWORD" | sudo "$VNC_PASSWD_BIN" -service

# Set listen addresses for direct connections (Enterprise parameter). :contentReference[oaicite:5]{index=5}
# RealVNC supports setting parameters via its config/registry; on macOS it stores config under /Library/Preferences.
# We’ll write a small config drop-in using vncserver parameters mechanism where supported.
#
# NOTE: RealVNC has multiple modes; for fleet consistency, we rely on Service Mode.
PARAMS_FILE="/Library/Preferences/com.realvnc.vncserver.plist"

# Use defaults to write to plist
sudo /usr/bin/defaults write com.realvnc.vncserver IpListenAddresses -string "$LISTEN_IP"

# Ensure direct connections are enabled (default is usually enabled, but we make it explicit)
sudo /usr/bin/defaults write com.realvnc.vncserver AllowDirectConnections -bool true

echo "Restarting RealVNC services..."
# These launchd labels are listed in the cask uninstall stanza and are commonly present. :contentReference[oaicite:6]{index=6}
for svc in com.realvnc.vncserver com.realvnc.vncserver.peruser com.realvnc.vncagent.prelogin com.realvnc.vncagent.peruser; do
  sudo launchctl kickstart -k system/"$svc" >/dev/null 2>&1 || true
done

echo
echo "RealVNC installed."
echo "Tailscale IP: $TS_IP"
echo "Listening IP: $LISTEN_IP"
echo "Connect with any VNC client to: ${LISTEN_IP}:5900"
echo
echo "macOS permissions note:"
echo "You must grant Screen Recording + Accessibility permissions to RealVNC Server or you'll get a blank/limited session."
