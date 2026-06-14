#!/usr/bin/env bash
# Install the Nimbus Flux wallpaper plugin + its launcher so the Layer-10 bevy engine
# is selectable from System Settings → Wallpaper. Idempotent; run as your normal user.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ID="com.nimbus.flux"
DEST="$HOME/.local/share/plasma/wallpapers/$PLUGIN_ID"
BINDIR="$HOME/.local/bin"

ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
note(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

# 1. launcher onto PATH
mkdir -p "$BINDIR"
install -m755 "$HERE/nimbus-flux-wallpaper.sh" "$BINDIR/nimbus-flux-wallpaper"
ok "launcher → $BINDIR/nimbus-flux-wallpaper"

# 2. plugin package (clean deploy so removed files don't linger)
rm -rf "$DEST"; mkdir -p "$DEST"
cp -r "$HERE/$PLUGIN_ID/metadata.json" "$HERE/$PLUGIN_ID/contents" "$DEST/"
ok "plugin → $DEST"

# 3. refresh KService cache so the new wallpaper type is discoverable
kbuildsycoca6 >/dev/null 2>&1 || true
ok "kbuildsycoca6 refreshed"

note "Restart plasmashell so it appears in Settings → Wallpaper:"
note "    kquitapp6 plasmashell; kstart plasmashell"
note "Then: right-click desktop → Configure Desktop and Wallpaper →"
note "    Wallpaper type → 'Nimbus Flux (3D Engine)' → pick a Scene → Apply."
