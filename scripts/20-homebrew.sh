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
