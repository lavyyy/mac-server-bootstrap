#!/usr/bin/env bash
set -euo pipefail

echo "Enabling SSH (Remote Login)..."
systemsetup -setremotelogin on >/dev/null

# Optional authorized_keys install
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_FILE="$REPO_DIR/config/admin_authorized_keys"

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" ]]; then
  echo "Cannot determine target user; skipping authorized_keys."
  exit 0
fi

if [[ -f "$KEY_FILE" ]]; then
  echo "Installing authorized_keys for user: $TARGET_USER"
  USER_HOME="$(dscl . -read /Users/"$TARGET_USER" NFSHomeDirectory | awk '{print $2}')"
  SSH_DIR="$USER_HOME/.ssh"
  AUTH_KEYS="$SSH_DIR/authorized_keys"

  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  touch "$AUTH_KEYS"
  chmod 600 "$AUTH_KEYS"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    grep -qxF "$line" "$AUTH_KEYS" || echo "$line" >> "$AUTH_KEYS"
  done < "$KEY_FILE"

  chown -R "$TARGET_USER":staff "$SSH_DIR"
  echo "authorized_keys updated."
else
  echo "No config/admin_authorized_keys found; skipping key install."
fi
