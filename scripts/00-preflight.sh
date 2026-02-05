#!/usr/bin/env bash
set -euo pipefail

echo "Preflight checks..."
echo "macOS version: $(sw_vers -productVersion) (build $(sw_vers -buildVersion))"
echo "CPU: $(sysctl -n machdep.cpu.brand_string)"

if [[ -z "${SUDO_USER:-}" ]]; then
  echo "SUDO_USER is empty. Run via sudo from a real account."
  exit 1
fi

# Command Line Tools (may prompt via GUI)
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools not found."
  echo "Attempting to trigger install: xcode-select --install"
  xcode-select --install || true
  echo "If a GUI prompt appeared, complete it, then rerun bootstrap."
fi
