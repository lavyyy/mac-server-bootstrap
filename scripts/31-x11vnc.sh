#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" ]]; then
  echo "Run via sudo from a real user: sudo $0"
  exit 1
fi

BREW="/usr/local/bin/brew"
BIN="/usr/local/bin/x11vnc"
SRC_DIR="/usr/local/src"
REPO_DIR="${SRC_DIR}/x11vnc-macosx"

PASSDIR="/Library/Application Support/x11vnc"
PASSFILE="${PASSDIR}/passwd"

WRAPPER_DIR="/usr/local/libexec"
WRAPPER="${WRAPPER_DIR}/x11vnc-tailscale-wrapper.sh"

AGENTS_DIR="/Library/LaunchAgents"
PLIST="${AGENTS_DIR}/dev.barking.x11vnc.plist"

LOGFILE="/var/log/x11vnc.log"
OUT_LOG="/var/log/x11vnc.stdout.log"
ERR_LOG="/var/log/x11vnc.stderr.log"

if [[ ! -x "$BREW" ]]; then
  echo "Homebrew not found at $BREW. Run brew step first."
  exit 1
fi

if [[ -z "${X11VNC_PASSWORD:-}" ]]; then
  echo "X11VNC_PASSWORD is required."
  echo "Set it in .env or inline, e.g.:"
  echo "  sudo X11VNC_PASSWORD='strong-password' ./bootstrap.sh"
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale CLI not found. Run the tailscale step and ensure Tailscale is installed."
  exit 1
fi

echo "Checking Tailscale IP..."
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [[ -z "$TS_IP" ]]; then
  echo "No Tailscale IPv4 detected. Ensure Tailscale is running/logged in, then rerun bootstrap."
  exit 1
fi
echo "Tailscale IPv4 detected: $TS_IP"

echo "Installing build dependencies for x11vnc..."
"$BREW" update
"$BREW" install git autoconf automake libtool pkg-config

# Best effort
"$BREW" install --cask xquartz >/dev/null 2>&1 || true

echo "Preparing source dir: $SRC_DIR"
mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

if [[ ! -d "$REPO_DIR" ]]; then
  echo "Cloning x11vnc macOS fork..."
  git clone https://github.com/Apreta/x11vnc-macosx.git
else
  echo "Updating x11vnc macOS fork..."
  cd "$REPO_DIR"
  git pull
fi

echo "Building x11vnc..."
cd "$REPO_DIR"
./autogen.sh
./configure
make -j"$(sysctl -n hw.ncpu)"
make install

if [[ ! -x "$BIN" ]]; then
  echo "x11vnc binary not found at $BIN after install."
  exit 1
fi

echo "Creating password file..."
mkdir -p "$PASSDIR"
chmod 755 "$PASSDIR"
"$BIN" -storepasswd "${X11VNC_PASSWORD}" "$PASSFILE"
chmod 600 "$PASSFILE"

echo "Creating wrapper to bind VNC only to Tailscale IP..."
mkdir -p "$WRAPPER_DIR"
chmod 755 "$WRAPPER_DIR"

cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

X11VNC="/usr/local/bin/x11vnc"
PASSFILE="/Library/Application Support/x11vnc/passwd"
LOGFILE="/var/log/x11vnc.log"

TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [[ -z "$TS_IP" ]]; then
  echo "No Tailscale IPv4 detected. Is Tailscale running/logged in?" >> "$LOGFILE"
  exit 1
fi

exec "$X11VNC" \
  -forever -shared \
  -listen "$TS_IP" \
  -rfbport 5900 \
  -rfbauth "$PASSFILE" \
  -o "$LOGFILE"
EOF

chmod 755 "$WRAPPER"

echo "Writing LaunchAgent plist: $PLIST"
mkdir -p "$AGENTS_DIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>dev.barking.x11vnc</string>

    <key>ProgramArguments</key>
    <array>
      <string>$WRAPPER</string>
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

# Load into GUI session of TARGET_USER
UID="$(id -u "$TARGET_USER")"

echo "Loading LaunchAgent into GUI session for user: $TARGET_USER (uid $UID)"
launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/dev.barking.x11vnc" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$UID/dev.barking.x11vnc" >/dev/null 2>&1 || true

echo "Validating listener..."
sleep 1
lsof -nP -iTCP:5900 -sTCP:LISTEN || true

echo
echo "x11vnc is configured to listen ONLY on the Tailscale IP (port 5900)."
echo "Connect from another Tailscale device to: ${TS_IP}:5900"
