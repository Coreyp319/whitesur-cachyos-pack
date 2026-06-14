#!/usr/bin/env bash
# Revert Layer 11 — put every app family back, disarm the light/dark watcher.
# --purge also does a full `flatpak override --user --reset` (pristine global
# override file) instead of the surgical key removal.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PURGE="${1:-}"
ok(){  printf '  \033[32m✓\033[0m %s\n' "$1"; }
msg(){ printf '\n\033[1m:: %s\033[0m\n' "$1"; }

STATE="$HOME/.local/state/nimbus/appunify"

msg "Firefox…";        bash "$HERE/firefox-restore.sh"
msg "Chromium family…"; bash "$HERE/chromium-restore.sh"
msg "Electron…";       bash "$HERE/electron-restore.sh"

msg "Flatpak…"
# Disarm the watcher first.
systemctl --user disable --now nimbus-appunify-scheme.path 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/nimbus-appunify-scheme.path" \
      "$HOME/.config/systemd/user/nimbus-appunify-scheme.service" \
      "$HOME/.local/bin/nimbus-appunify-scheme.sh"
systemctl --user daemon-reload 2>/dev/null || true
# flatpak-theme-restore.sh already resets the pack-owned global override cleanly,
# so --purge needs nothing extra here (kept for a consistent layer interface).
bash "$HERE/flatpak-theme-restore.sh"
: "${PURGE:=}"

# Drop the gate marker + state dir if empty.
rm -f "$STATE/.installed"
rmdir "$STATE" 2>/dev/null || true

echo
echo "Done. Relaunch browsers / VS Code to drop back to their own titlebars."
