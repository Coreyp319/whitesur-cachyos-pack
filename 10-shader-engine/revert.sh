#!/usr/bin/env bash
# Revert Layer 10 — stop the live wallpaper, remove its login autostart, and remove
# the Nimbus Flux app launcher. With --purge it also removes the build artifacts
# (cargo clean). The Rust toolchain itself is left alone (uninstall with
# `rustup self uninstall` if you want it gone).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DESKTOP="$HOME/.local/share/applications/nimbus-flux.desktop"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/nimbus-hexen-wallpaper.desktop"

ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }

# stop a running live wallpaper (-x by name; -f would match this script)
if pkill -x nimbus-flux 2>/dev/null; then ok "stopped live wallpaper"; else ok "no wallpaper running"; fi

# remove the login autostart so the wallpaper doesn't return next login
if [ -f "$AUTOSTART" ]; then rm -f "$AUTOSTART"; ok "login autostart removed"; else ok "no autostart to remove"; fi

if [ -f "$DESKTOP" ]; then rm -f "$DESKTOP"; ok "launcher removed"; else ok "no launcher to remove"; fi

if [ "${1:-}" = "--purge" ]; then
  command -v cargo >/dev/null 2>&1 || { [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"; }
  if command -v cargo >/dev/null 2>&1; then
    ( cd "$HERE/nimbus-flux" && cargo clean ) 2>/dev/null && ok "build artifacts cleaned (cargo clean)"
  fi
fi
