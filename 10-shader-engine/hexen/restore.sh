#!/usr/bin/env bash
# Nimbus Hexen — revert apply.sh: stop the live bevy wallpaper, restore the prior
# colour scheme and aurora palette. With --purge also remove the installed colour
# scheme files and the fetched Poly Haven assets.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYER="$(cd "$HERE/.." && pwd)"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/nimbus/hexen"
SCHEMES_DIR="$HOME/.local/share/color-schemes"

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

# ---- 1. stop the live wallpaper (note: -x by name; -f would match this script) ---
if pkill -x nimbus-flux 2>/dev/null; then
    echo "stopped the live bevy wallpaper"
fi

# remove the login autostart entry so it doesn't come back on next login
AUTOSTART_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/nimbus-hexen-wallpaper.desktop"
if [[ -f "$AUTOSTART_FILE" ]]; then
    rm -f "$AUTOSTART_FILE"
    echo "removed login autostart entry"
fi

# ---- 2. restore the colour scheme ----------------------------------------------
if command -v plasma-apply-colorscheme >/dev/null 2>&1; then
    PREV=""
    [[ -f "$STATE/prev-colorscheme" ]] && PREV="$(cat "$STATE/prev-colorscheme")"
    if [[ -n "$PREV" && "$PREV" != Nimbus-Hexen* ]]; then
        plasma-apply-colorscheme "$PREV" && echo "restored colour scheme: $PREV"
    else
        # nothing sensible saved — fall back to the pack default if present, else Breeze
        for fallback in CoreyLavender BreezeDark Breeze; do
            if plasma-apply-colorscheme "$fallback" >/dev/null 2>&1; then
                echo "restored colour scheme: $fallback (no prior saved)"; break
            fi
        done
    fi
fi

# ---- 3. restore the aurora palette ----------------------------------------------
if command -v qdbus6 >/dev/null 2>&1 && qdbus6 org.kde.plasmashell >/dev/null 2>&1; then
    if [[ -f "$STATE/prev-aurora-colors" ]]; then
        mapfile -t C < "$STATE/prev-aurora-colors"
    else
        C=(\#0d0f29 \#1c2e73 \#4552b8 \#8f5cb8 \#fa8c73)   # main.xml defaults
    fi
    if [[ ${#C[@]} -ge 5 ]]; then
        qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript "
            var d = desktops()[0];
            d.currentConfigGroup = ['Wallpaper', 'com.nimbus.aurora', 'General'];
            d.writeConfig('Color0', '${C[0]}');
            d.writeConfig('Color1', '${C[1]}');
            d.writeConfig('Color2', '${C[2]}');
            d.writeConfig('Color3', '${C[3]}');
            d.writeConfig('Color4', '${C[4]}');" >/dev/null 2>&1 || true
        CURPLUG="$(qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript \
            'desktops()[0].wallpaperPlugin' 2>/dev/null || true)"
        if [[ "$CURPLUG" == "com.nimbus.aurora" ]]; then
            qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript \
                'desktops()[0].wallpaperPlugin="org.kde.image"' >/dev/null 2>&1 || true
            qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript \
                'desktops()[0].wallpaperPlugin="com.nimbus.aurora"' >/dev/null 2>&1 || true
        fi
        echo "restored aurora palette"
    fi
fi

# ---- 4. optional purge ----------------------------------------------------------
if [[ "$PURGE" == 1 ]]; then
    rm -f "$SCHEMES_DIR/Nimbus-Hexen.colors" "$SCHEMES_DIR/Nimbus-Hexen-Light.colors"
    rm -rf "$LAYER/nimbus-flux/assets/hexen"
    rm -rf "$STATE"
    echo "purged: colour scheme files, fetched assets, saved state"
fi
echo "done."
