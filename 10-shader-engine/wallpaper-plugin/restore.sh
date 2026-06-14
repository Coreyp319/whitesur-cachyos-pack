#!/usr/bin/env bash
# Remove the Nimbus Flux wallpaper plugin + launcher and stop the engine.
set -uo pipefail
PLUGIN_ID="com.nimbus.flux"

ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
note(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

# stop the engine + its watchdog (launcher knows how; fall back to a direct kill)
if [ -x "$HOME/.local/bin/nimbus-flux-wallpaper" ]; then
    "$HOME/.local/bin/nimbus-flux-wallpaper" --stop 2>/dev/null || true
else
    pkill -x nimbus-flux 2>/dev/null || true
fi

rm -rf "$HOME/.local/share/plasma/wallpapers/$PLUGIN_ID"
rm -f "$HOME/.local/bin/nimbus-flux-wallpaper"
kbuildsycoca6 >/dev/null 2>&1 || true
ok "removed Nimbus Flux wallpaper plugin + launcher"
note "If it was your active wallpaper, pick another in Settings → Wallpaper."
