#!/usr/bin/env bash
# Nimbus Hexen — apply the gothic theme that matches the Layer-10 "hexen" bevy
# wallpaper: install + activate the Nimbus-Hexen colour scheme (dark by default,
# --light for the parchment variant) and sync the gothic torch-amber palette into
# the Layer-9 aurora wallpaper so the desktop background matches when the aurora is
# in use. With --start it also fetches assets, builds, and launches the live
# bevy wallpaper (NIMBUS_FLUX_WALLPAPER=1).
#
# Reversible: prior colour scheme + aurora palette are backed up to the state dir
# and restored by restore.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYER="$(cd "$HERE/.." && pwd)"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/nimbus/hexen"
SCHEMES_DIR="$HOME/.local/share/color-schemes"

VARIANT="dark"           # dark|light
START_WP=0               # --start launches the live wallpaper
ACTIVATE=1               # --no-activate installs without switching the active scheme
AUTOSTART=0              # --autostart installs a login autostart entry (persists across reboot)
for arg in "$@"; do
    case "$arg" in
        --light) VARIANT="light" ;;
        --dark)  VARIANT="dark" ;;
        --start) START_WP=1 ;;
        --autostart) AUTOSTART=1 ;;
        --no-activate) ACTIVATE=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

AUTOSTART_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/nimbus-hexen-wallpaper.desktop"

mkdir -p "$STATE" "$SCHEMES_DIR"

# Gothic aurora ramp (c0 deep-stone → c4 candle-gold), mirrors the dungeon's
# torch-lit warm palette. Used for the Layer-9 tie-in.
AURORA_COLORS=(\#120d0a \#3a1d12 \#7a3b1e \#c8791f \#f2c879)

# ---- 1. install both colour scheme files ----------------------------------------
install -m644 "$HERE/Nimbus-Hexen.colors"       "$SCHEMES_DIR/Nimbus-Hexen.colors"
install -m644 "$HERE/Nimbus-Hexen-Light.colors" "$SCHEMES_DIR/Nimbus-Hexen-Light.colors"
echo "installed Nimbus-Hexen{,-Light}.colors -> $SCHEMES_DIR"

# ---- 2. back up + activate the colour scheme ------------------------------------
if [[ "$ACTIVATE" == 1 ]]; then
    if [[ ! -f "$STATE/prev-colorscheme" ]]; then
        kreadconfig6 --file kdeglobals --group General --key ColorScheme \
            > "$STATE/prev-colorscheme" 2>/dev/null || echo "" > "$STATE/prev-colorscheme"
    fi
    SCHEME_NAME="Nimbus-Hexen"; [[ "$VARIANT" == light ]] && SCHEME_NAME="Nimbus-Hexen-Light"
    if command -v plasma-apply-colorscheme >/dev/null 2>&1; then
        plasma-apply-colorscheme "$SCHEME_NAME" && echo "activated colour scheme: $SCHEME_NAME"
    else
        echo "plasma-apply-colorscheme not found — scheme installed but not activated" >&2
    fi
fi

# ---- 3. Layer-9 aurora palette tie-in -------------------------------------------
# Write the gothic ramp into the aurora wallpaper config; only bounce the plugin if
# the aurora is the *current* wallpaper (so we never hijack a different one).
if command -v qdbus6 >/dev/null 2>&1 && qdbus6 org.kde.plasmashell >/dev/null 2>&1; then
    # back up the live aurora colours once (falls back to main.xml defaults on read miss)
    if [[ ! -f "$STATE/prev-aurora-colors" ]]; then
        qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript '
            var d = desktops()[0];
            d.currentConfigGroup = ["Wallpaper", "com.nimbus.aurora", "General"];
            [d.readConfig("Color0"), d.readConfig("Color1"), d.readConfig("Color2"),
             d.readConfig("Color3"), d.readConfig("Color4")].join("\n");' \
            > "$STATE/prev-aurora-colors" 2>/dev/null || true
        # main.xml defaults if the read came back empty
        if [[ ! -s "$STATE/prev-aurora-colors" ]]; then
            printf '#0d0f29\n#1c2e73\n#4552b8\n#8f5cb8\n#fa8c73\n' > "$STATE/prev-aurora-colors"
        fi
    fi
    qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript "
        var d = desktops()[0];
        d.currentConfigGroup = ['Wallpaper', 'com.nimbus.aurora', 'General'];
        d.writeConfig('Color0', '${AURORA_COLORS[0]}');
        d.writeConfig('Color1', '${AURORA_COLORS[1]}');
        d.writeConfig('Color2', '${AURORA_COLORS[2]}');
        d.writeConfig('Color3', '${AURORA_COLORS[3]}');
        d.writeConfig('Color4', '${AURORA_COLORS[4]}');" >/dev/null 2>&1 || true
    # bounce only if aurora is the active wallpaper, so the change takes effect live
    CURPLUG="$(qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript \
        'desktops()[0].wallpaperPlugin' 2>/dev/null || true)"
    if [[ "$CURPLUG" == "com.nimbus.aurora" ]]; then
        qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript \
            'desktops()[0].wallpaperPlugin="org.kde.image"' >/dev/null 2>&1 || true
        qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript \
            'desktops()[0].wallpaperPlugin="com.nimbus.aurora"' >/dev/null 2>&1 || true
        echo "synced gothic palette into the live aurora wallpaper"
    else
        echo "gothic palette written to aurora config (applies when the aurora is used)"
    fi
else
    echo "plasmashell/qdbus6 unavailable — skipped aurora palette tie-in" >&2
fi

# ---- 4. optional login autostart (persists the wallpaper across reboots) --------
if [[ "$AUTOSTART" == 1 ]]; then
    mkdir -p "$(dirname "$AUTOSTART_FILE")"
    cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Nimbus Hexen Wallpaper (ray-traced)
Comment=Layer-10 ray-traced gothic dungeon live wallpaper (Nimbus pack)
Exec=$HERE/autostart-launch.sh
X-KDE-autostart-phase=2
OnlyShowIn=KDE;
Terminal=false
Hidden=false
EOF
    echo "installed login autostart -> $AUTOSTART_FILE"
fi

# ---- 5. optionally launch the live bevy wallpaper now ---------------------------
if [[ "$START_WP" == 1 ]]; then
    echo "fetching assets + building the dungeon wallpaper (first run takes a few min)…"
    bash "$LAYER/fetch-hexen-assets.sh"
    pkill -x nimbus-flux 2>/dev/null || true
    NIMBUS_FLUX_WALLPAPER=1 setsid -f bash "$LAYER/run.sh" >/dev/null 2>&1 || true
    echo "launched the live gothic wallpaper (stop it with: pkill -x nimbus-flux)"
else
    echo "to start the live wallpaper:  NIMBUS_FLUX_WALLPAPER=1 bash $LAYER/run.sh"
fi
echo "done. revert with: bash $HERE/restore.sh"
