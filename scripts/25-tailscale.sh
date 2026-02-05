#!/usr/bin/env bash
set -euo pipefail

BREW="/usr/local/bin/brew"
if [[ ! -x "$BREW" ]]; then
  echo "Homebrew not found; run brew step first."
  exit 1
fi

echo "Installing Tailscale..."
"$BREW" list --cask tailscale >/dev/null 2>&1 || "$BREW" install --cask tailscale

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale CLI not found in PATH. You may need to open the Tailscale app once."
  echo "Continuing; x11vnc step will fail until Tailscale is running."
  exit 0
fi

# Attempt to bring up Tailscale if auth key is provided
if [[ -n "${TS_AUTHKEY:-}" ]]; then
  TS_HOSTNAME="${TS_HOSTNAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"
  TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"

  echo "Bringing Tailscale up using TS_AUTHKEY (hostname: $TS_HOSTNAME)..."
  # Avoid failing the whole bootstrap if already up
  tailscale up --authkey "$TS_AUTHKEY" --hostname "$TS_HOSTNAME" --accept-dns=false $TS_EXTRA_ARGS || true
else
  echo "TS_AUTHKEY not set. If this node is not logged in yet, log in once via the Tailscale app."
fi

TSIP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [[ -n "$TSIP" ]]; then
  echo "Tailscale IPv4: $TSIP"
else
  echo "No Tailscale IPv4 detected yet."
fi
