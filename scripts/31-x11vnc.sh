#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" ]]; then
  echo "Run via sudo from a real user: sudo $0"
  exit 1
fi

USER_HOME="$(dscl . -read /Users/"$TARGET_USER" NFSHomeDirectory | awk '{print $2}')"
BREW="/usr/local/bin/brew"
X11VNC_BIN="/usr/local/bin/x11vnc"

SRC_BASE="/usr/local/src"
REPO_DIR="${SRC_BASE}/x11vnc-macosx"

PASSDIR="/Library/Application Support/x11vnc"
PASSFILE="${PASSDIR}/passwd"

WRAPPER_DIR="/usr/local/libexec"
WRAPPER="${WRAPPER_DIR}/x11vnc-tailscale-wrapper.sh"

AGENTS_DIR="/Library/LaunchAgents"
PLIST="${AGENTS_DIR}/com.yourorg.x11vnc.plist"

LOGFILE="/var/log/x11vnc.log"
OUT_LOG="/var/log/x11vnc.stdout.log"
ERR_LOG="/var/log/x11vnc.stderr.log"

run_as_user() {
  sudo -u "$TARGET_USER" env -i \
    HOME="$USER_HOME" \
    USER="$TARGET_USER" \
    LOGNAME="$TARGET_USER" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash -lc "$*"
}

if [[ -z "${X11VNC_PASSWORD:-}" ]]; then
  echo "X11VNC_PASSWORD is required (set in .env)."
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

echo "Checking Tailscale IP..."
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [[ -z "$TS_IP" ]]; then
  echo "No Tailscale IPv4 detected. Ensure Tailscale is running/logged in, then rerun."
  exit 1
fi
echo "Tailscale IPv4 detected: $TS_IP"

echo "Installing build dependencies for x11vnc (as user: $TARGET_USER)..."
run_as_user "$BREW update"
run_as_user "$BREW install git autoconf automake libtool pkg-config"
# Best effort, may fail if cask not supported in some environments
run_as_user "$BREW install --cask xquartz >/dev/null 2>&1 || true"

echo "Preparing source dir: $SRC_BASE"
# Create source base owned by user (avoid root-owned build tree)
mkdir -p "$SRC_BASE"
chown "$TARGET_USER":staff "$SRC_BASE" || chown "$TARGET_USER":admin "$SRC_BASE" || true

if [[ ! -d "$REPO_DIR" ]]; then
  echo "Cloning x11vnc macOS fork (as user)..."
  run_as_user "cd \"$SRC_BASE\" && git clone https://github.com/Apreta/x11vnc-macosx.git"
else
  echo "Updating x11vnc macOS fork (as user)..."
  run_as_user "cd \"$REPO_DIR\" && git pull"
fi

echo "Building x11vnc (as user)..."
run_as_user "
  set -euo pipefail
  cd \"$REPO_DIR\"

  # Some forks have autogen.sh, others require autoreconf, others ship configure already.
  if [[ -x ./autogen.sh ]]; then
    echo 'Using ./autogen.sh'
    ./autogen.sh
  elif command -v autoreconf >/dev/null 2>&1; then
    echo 'Using autoreconf -fi'
    autoreconf -fi
  else
    echo 'No autogen.sh and no autoreconf found'
    exit 1
  fi

  if [[ -x ./configure ]]; then
    ./configure
  else
    echo 'configure script not found after bootstrap step'
    ls -la
    exit 1
  fi

  make -j\"$(sysctl -n hw.ncpu)\"
"


echo "Installing x11vnc (requires sudo)..."
# make install writes into /usr/local/bin, needs privileges
cd "$REPO_DIR"
make install

if [[ ! -x "$X11VNC_BIN" ]]; then
  echo "x11vnc binary not found at $X11VNC_BIN after install."
  exit 1
fi

echo "Creating password file..."
mkdir -p "$PASSDIR"
chmod 755 "$PASSDIR"
"$X11VNC_BIN" -storepasswd "${X11VNC_PASSWORD}" "$PASSFILE"
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
    <key>Label</key><string>com.yourorg.x11vnc</string>

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
launchctl enable "gui/$UID/com.yourorg.x11vnc" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$UID/com.yourorg.x11vnc" >/dev/null 2>&1 || true

echo "Validating listener..."
sleep 1
lsof -nP -iTCP:5900 -sTCP:LISTEN || true

echo
echo "x11vnc is configured to listen ONLY on the Tailscale IP (port 5900)."
echo "Connect from another Tailscale device to: ${TS_IP}:5900"
