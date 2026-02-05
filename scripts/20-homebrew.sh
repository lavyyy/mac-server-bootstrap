#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" ]]; then
  echo "SUDO_USER is empty; run bootstrap via sudo from a real user."
  exit 1
fi

USER_HOME="$(dscl . -read /Users/"$TARGET_USER" NFSHomeDirectory | awk '{print $2}')"
BREW="/usr/local/bin/brew"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_FILE="$REPO_DIR/config/brew-packages.txt"

run_as_user() {
  # Run a command as the target user with their HOME set correctly
  sudo -u "$TARGET_USER" env -i \
    HOME="$USER_HOME" \
    USER="$TARGET_USER" \
    LOGNAME="$TARGET_USER" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash -lc "$*"
}

echo "Homebrew step: installing/configuring as user: $TARGET_USER"
echo "User home: $USER_HOME"

# Install Homebrew as the non-root user (installer refuses root)
if [[ ! -x "$BREW" ]]; then
  echo "Installing Homebrew (Intel /usr/local)..."
  run_as_user 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
else
  echo "Homebrew already installed at: $BREW"
fi

echo "Ensuring /usr/local permissions are compatible with Homebrew..."

# These are common directories Homebrew needs to write to on Intel macOS.
# We only adjust ownership if the directory exists and is not writable by TARGET_USER.
fix_dir() {
  local d="$1"
  if [[ -d "$d" ]]; then
    if ! sudo -u "$TARGET_USER" test -w "$d" 2>/dev/null; then
      echo "Fixing ownership/permissions: $d"
      chown -R "$TARGET_USER":admin "$d" || chown -R "$TARGET_USER":staff "$d" || true
      chmod -R u+rwX "$d" || true
    fi
  fi
}

fix_dir /usr/local/share/man
fix_dir /usr/local/share/man/man8
fix_dir /usr/local/share/man/man1
fix_dir /usr/local/share/man/man3
fix_dir /usr/local/share/man/man5
fix_dir /usr/local/share/man/man7

# Also commonly needed for installs/links
fix_dir /usr/local/bin
fix_dir /usr/local/sbin
fix_dir /usr/local/lib
fix_dir /usr/local/include
fix_dir /usr/local/share
fix_dir /usr/local/var
fix_dir /usr/local/etc

echo "Updating brew..."
run_as_user "$BREW update"

if [[ -f "$PKG_FILE" ]]; then
  echo "Installing brew packages from $PKG_FILE"
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    [[ "$pkg" =~ ^# ]] && continue
    run_as_user "$BREW list \"$pkg\" >/dev/null 2>&1 || $BREW install \"$pkg\""
  done < "$PKG_FILE"
else
  echo "No config/brew-packages.txt found; skipping package install."
fi

echo "Homebrew setup complete."
