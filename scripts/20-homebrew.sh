#!/usr/bin/env bash
set -euo pipefail

BREW="/usr/local/bin/brew"

if [[ ! -x "$BREW" ]]; then
  echo "Installing Homebrew (Intel /usr/local)..."
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  echo "Homebrew already installed at: $BREW"
fi

echo "Updating brew..."
"$BREW" update

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_FILE="$REPO_DIR/config/brew-packages.txt"

if [[ -f "$PKG_FILE" ]]; then
  echo "Installing brew packages from $PKG_FILE"
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    [[ "$pkg" =~ ^# ]] && continue
    "$BREW" list "$pkg" >/dev/null 2>&1 || "$BREW" install "$pkg"
  done < "$PKG_FILE"
else
  echo "No config/brew-packages.txt found; skipping package install."
fi
