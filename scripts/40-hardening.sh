#!/usr/bin/env bash
set -euo pipefail

echo "Applying basic hardening..."

# Enable macOS application firewall
/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on >/dev/null || true

# Disable Guest account (best effort)
defaults write /Library/Preferences/com.apple.loginwindow GuestEnabled -bool false || true

# Require password immediately after sleep/screensaver (best effort)
defaults write com.apple.screensaver askForPassword -int 1 || true
defaults write com.apple.screensaver askForPasswordDelay -int 0 || true

echo "Hardening complete."
