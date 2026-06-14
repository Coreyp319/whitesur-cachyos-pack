#!/usr/bin/env bash
# Login launcher for the ray-traced "hexen" wallpaper, invoked by the XDG autostart
# entry (~/.config/autostart/nimbus-hexen-wallpaper.desktop). A short delay lets
# plasmashell/KWin settle before bevy_live_wallpaper grabs the layer-shell surface.
# Kept as a separate script so the .desktop Exec= stays free of reserved characters
# (`;`, quotes) that desktop-file-validate rejects.
sleep 4
LAYER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec env NIMBUS_FLUX_WALLPAPER=1 bash "$LAYER/run.sh"
