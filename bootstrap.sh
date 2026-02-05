#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/mac-server-bootstrap"
LOG_FILE="${LOG_DIR}/bootstrap-$(date +%Y%m%d-%H%M%S).log"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo:"
  echo "  sudo $0"
  exit 1
fi

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "== Starting Mac Server Bootstrap =="
echo "Log: $LOG_FILE"
echo "Host: $(scutil --get ComputerName 2>/dev/null || hostname)"
echo "User invoking sudo: ${SUDO_USER:-unknown}"
echo "macOS: $(sw_vers -productVersion)  build: $(sw_vers -buildVersion)"

# ----------------------------
# Safe .env loader (allowlist)
# ----------------------------
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

ALLOW_KEYS=(
  X11VNC_PASSWORD
  TS_AUTHKEY
  TS_HOSTNAME
  TS_EXTRA_ARGS
  RUN_TAILSCALE
  RUN_X11VNC
  RUN_HARDENING
)

is_allowed_key() {
  local k="$1"
  for a in "${ALLOW_KEYS[@]}"; do
    [[ "$k" == "$a" ]] && return 0
  done
  return 1
}

load_env_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  echo "Loading env from: $f"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue

    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      echo "Skipping invalid .env line: $line"
      continue
    fi

    key="${line%%=*}"
    val="${line#*=}"

    if ! is_allowed_key "$key"; then
      echo "Skipping non-allowed key in .env: $key"
      continue
    fi

    if [[ "$val" =~ ^\".*\"$ ]]; then
      val="${val:1:${#val}-2}"
    elif [[ "$val" =~ ^\'.*\'$ ]]; then
      val="${val:1:${#val}-2}"
    fi

    export "$key=$val"
  done < "$f"
}

load_env_file "$ENV_FILE"

# Defaults for toggles
: "${RUN_TAILSCALE:=1}"
: "${RUN_X11VNC:=1}"
: "${RUN_HARDENING:=1}"

run_script() {
  local s="$1"
  echo
  echo "== Running: $s =="
  /bin/bash "$REPO_DIR/scripts/$s"
}

run_script "00-preflight.sh"
run_script "10-ssh.sh"
run_script "20-homebrew.sh"

if [[ "$RUN_TAILSCALE" == "1" ]]; then
  run_script "25-tailscale.sh"
else
  echo "Skipping Tailscale step (RUN_TAILSCALE=$RUN_TAILSCALE)"
fi

if [[ "$RUN_X11VNC" == "1" ]]; then
  run_script "31-x11vnc.sh"
else
  echo "Skipping x11vnc step (RUN_X11VNC=$RUN_X11VNC)"
fi

if [[ "$RUN_HARDENING" == "1" ]]; then
  run_script "40-hardening.sh"
else
  echo "Skipping hardening step (RUN_HARDENING=$RUN_HARDENING)"
fi

echo
echo "== Done =="
echo "Check VNC bind: lsof -nP -iTCP:5900 -sTCP:LISTEN"
