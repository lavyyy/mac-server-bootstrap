#!/usr/bin/env bash
set -euo pipefail

OSXVNC_VERSION="${OSXVNC_VERSION:-5.3.2}"
OSXVNC_PORT="${OSXVNC_PORT:-5900}"

if [[ -z "${VNC_PASSWORD:-}" ]]; then
  echo "VNC_PASSWORD is required (set it in .env)."
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

DMG_NAME="VineServer-${OSXVNC_VERSION}.dmg"
DMG_URL="https://github.com/stweil/OSXvnc/releases/download/V${OSXVNC_VERSION}/${DMG_NAME}"
DMG_PATH="/tmp/${DMG_NAME}"
MOUNT_POINT=""

echo "Downloading OSXvnc (stweil) DMG: $DMG_NAME"
curl -fL --retry 3 --retry-delay 2 -o "$DMG_PATH" "$DMG_URL"

echo "Mounting DMG..."
MOUNT_POINT="$(hdiutil attach "$DMG_PATH" -nobrowse -noverify | awk 'END{print $3}')"
if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
  echo "Failed to mount DMG."
  exit 1
fi
echo "Mounted at: $MOUNT_POINT"

# Find the app inside the DMG (usually "Vine Server.app")
APP_PATH="$(find "$MOUNT_POINT" -maxdepth 2 -type d -name "*.app" | head -n 1 || true)"
if [[ -z "$APP_PATH" ]]; then
  echo "No .app found in DMG."
  hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  exit 1
fi

DEST_APP="/Applications/$(basename "$APP_PATH")"

echo "Installing app to: $DEST_APP"
rm -rf "$DEST_APP"
cp -R "$APP_PATH" /Applications/

echo "Unmounting DMG..."
hdiutil detach "$MOUNT_POINT" >/dev/null
rm -f "$DMG_PATH" || true

echo "Locating OSXvnc-server and storepasswd..."
SERVER_BIN="$(find "$DEST_APP" -type f -name "OSXvnc-server" -perm -111 | head -n 1 || true)"
STOREPASS_BIN="$(find "$DEST_APP" -type f -name "storepasswd" -perm -111 | head -n 1 || true)"

if [[ -z "$SERVER_BIN" ]]; then
  echo "Could not find OSXvnc-server inside $DEST_APP"
  exit 1
fi
if [[ -z "$STOREPASS_BIN" ]]; then
  echo "Could not find storepasswd inside $DEST_APP"
  exit 1
fi

echo "Server: $SERVER_BIN"
echo "storepasswd: $STOREPASS_BIN"

PASSDIR="/Library/Application Support/osxvnc"
PASSFILE="$PASSDIR/passwd"
mkdir -p "$PASSDIR"
chmod 755 "$PASSDIR"

echo "Creating VNC password file..."
set +e
# Style A: storepasswd reads password from stdin:  printf pw | storepasswd file
printf '%s\n' "$VNC_PASSWORD" | "$STOREPASS_BIN" "$PASSFILE" >/dev/null 2>&1
RC1=$?

# Style B: storepasswd expects args: storepasswd <password> <file>
if [[ $RC1 -ne 0 ]]; then
  "$STOREPASS_BIN" "$VNC_PASSWORD" "$PASSFILE" >/dev/null 2>&1
  RC2=$?
else
  RC2=0
fi
set -e

if [[ $RC1 -ne 0 && $RC2 -ne 0 ]]; then
  echo "storepasswd failed in both stdin and argv modes."
  echo "Try manually:"
  echo "  sudo \"$STOREPASS_BIN\" \"<password>\" \"$PASSFILE\""
  exit 1
fi


if [[ ! -s "$PASSFILE" ]]; then
  echo "Password file not created at $PASSFILE"
  exit 1
fi
chmod 600 "$PASSFILE"

echo "Restricting VNC to Tailscale only using pf (allow 100.64.0.0/10, block others)"
ANCHOR_FILE="/etc/pf.anchors/com.yourorg.vnc"
PF_CONF="/etc/pf.conf"

cat > "$ANCHOR_FILE" <<EOF
# Allow VNC only from Tailscale CGNAT range
table <tailscale> persist { 100.64.0.0/10 }
pass in proto tcp from <tailscale> to any port $OSXVNC_PORT
block in proto tcp to any port $OSXVNC_PORT
EOF
chmod 600 "$ANCHOR_FILE"

if ! grep -q 'com.yourorg.vnc' "$PF_CONF"; then
  {
    echo ""
    echo "# VNC restricted to Tailscale"
    echo "anchor \"com.yourorg.vnc\""
    echo "load anchor \"com.yourorg.vnc\" from \"/etc/pf.anchors/com.yourorg.vnc\""
  } >> "$PF_CONF"
fi

pfctl -f "$PF_CONF" >/dev/null
pfctl -E >/dev/null 2>&1 || true

echo "Installing LaunchDaemon for OSXvnc (starts at boot)..."
PLIST="/Library/LaunchDaemons/com.yourorg.osxvnc.plist"
OUT_LOG="/var/log/osxvnc.stdout.log"
ERR_LOG="/var/log/osxvnc.stderr.log"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>com.yourorg.osxvnc</string>

    <key>ProgramArguments</key>
    <array>
      <string>$SERVER_BIN</string>
      <string>-rfbauth</string>
      <string>$PASSFILE</string>
      <string>-rfbport</string>
      <string>$OSXVNC_PORT</string>
    </array>

    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>

    <key>StandardOutPath</key><string>$OUT_LOG</string>
    <key>StandardErrorPath</key><string>$ERR_LOG</string>
  </dict>
</plist>
EOF

chmod 644 "$PLIST"
chown root:wheel "$PLIST"

launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap system "$PLIST"
launchctl enable system/com.yourorg.osxvnc >/dev/null 2>&1 || true
launchctl kickstart -k system/com.yourorg.osxvnc >/dev/null 2>&1 || true

echo
echo "OSXvnc is running."
echo "Tailscale IP: $TS_IP"
echo "Connect with any VNC client to: ${TS_IP}:${OSXVNC_PORT}"
echo "Firewall: blocked for non-Tailscale source IPs."
