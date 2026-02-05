#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" ]]; then
  echo "SUDO_USER is empty; run bootstrap via sudo from a real user."
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

if [[ ! -x "$BREW" ]]; then
  echo "Homebrew not found at $BREW. Run brew step first."
  exit 1
fi

echo "Installing Tailscale (via brew cask) as user: $TARGET_USER"
run_as_user "$BREW list --cask tailscale >/dev/null 2>&1 || $BREW install --cask tailscale"

# Tailscale CLI location varies; try a few common ones
find_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
    return 0
  fi
  if [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
    echo "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    return 0
  fi
  if [[ -x /usr/local/bin/tailscale ]]; then
    echo "/usr/local/bin/tailscale"
    return 0
  fi
  return 1
}

TAILSCALE_BIN="$(find_tailscale || true)"

if [[ -z "${TAILSCALE_BIN}" ]]; then
  echo "tailscale CLI not found yet. You may need to open Tailscale.app once to finish setup."
  echo "Skipping tailscale up for now."
  exit 0
fi

echo "Using tailscale CLI at: $TAILSCALE_BIN"

# If TS_AUTHKEY is provided, bring up tailscale non-interactively
if [[ -n "${TS_AUTHKEY:-}" ]]; then
  TS_HOSTNAME="${TS_HOSTNAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"
  TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"

  echo "Bringing Tailscale up (hostname: $TS_HOSTNAME)..."
  # Running tailscale up usually requires elevated privileges for network config
  sudo "$TAILSCALE_BIN" up --authkey "$TS_AUTHKEY" --hostname "$TS_HOSTNAME" --accept-dns=false $TS_EXTRA_ARGS || true
else
  echo "TS_AUTHKEY not set. If this node is not logged in yet, log in once via the Tailscale app."
fi

TSIP="$(sudo "$TAILSCALE_BIN" ip -4 2>/dev/null | head -n1 || true)"
if [[ -n "$TSIP" ]]; then
  echo "Tailscale IPv4: $TSIP"
else
  echo "No Tailscale IPv4 detected yet."
fi
