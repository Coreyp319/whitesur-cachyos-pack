#!/usr/bin/env bash
# Nimbus Flux wallpaper launcher — start/stop the Layer-10 bevy engine as a
# wlr-layer-shell desktop wallpaper. Driven by the com.nimbus.flux wallpaper plugin
# (contents/ui/main.qml), but also runnable by hand.
#
#   nimbus-flux-wallpaper [cyberpunk|hexen|fluid]   # start (default: cyberpunk)
#   nimbus-flux-wallpaper --stop                    # stop engine + watchdog
#
# Seamless switching: a background watchdog polls the desktop's wallpaperplugin in
# plasma's appletsrc and stops the engine the instant you pick another wallpaper —
# a belt-and-suspenders for the plugin's Component.onDestruction.
set -u

PLUGIN_ID="com.nimbus.flux"
DIR="$HOME/whitesur-cachyos-pack/10-shader-engine/nimbus-flux"
# Pick whichever build is NEWER — a stale release binary must never shadow a fresh
# debug build (that bug cost real debugging time twice).
REL="$DIR/target/release/nimbus-flux"; DBG="$DIR/target/debug/nimbus-flux"
if [ -x "$REL" ] && [ -x "$DBG" ]; then
    [ "$REL" -nt "$DBG" ] && BIN="$REL" || BIN="$DBG"
elif [ -x "$REL" ]; then BIN="$REL"
else BIN="$DBG"; fi
WPID="/tmp/nimbus-flux-watchdog.pid"
APPLETSRC="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"

stop() {
    [ -f "$WPID" ] && kill "$(cat "$WPID" 2>/dev/null)" 2>/dev/null
    rm -f "$WPID"
    pkill -x nimbus-flux 2>/dev/null   # -x = exact name; never -f (would self-match)
}

if [ "${1:-}" = "--stop" ]; then stop; exit 0; fi

scene="${1:-cyberpunk}"
[ -x "$BIN" ] || { echo "nimbus-flux binary not built ($DIR/target/{release,debug})" >&2; exit 1; }

stop

export BEVY_ASSET_ROOT="$DIR" NIMBUS_FLUX_WALLPAPER=1
# Always set the scene explicitly: in wallpaper mode the engine DEFAULTS to hexen when
# NIMBUS_FLUX_SCENE is unset, so leaving it unset would silently run hexen for "fluid".
# main.rs routes "fluid" (and any unknown) to the fluid sim.
export NIMBUS_FLUX_SCENE="$scene"
# Hexen refinement tuning: if a tuning has been promoted to "live" (via
# `hexen-tune.py go-live`), point the scene at it so accepted knobs apply on the live
# wallpaper. The renderer clamps every field and falls back to its hardcoded defaults if
# the file is missing/invalid, so this is safe to leave wired. Promotion is explicit
# (live.json, NOT the loop's in-progress tuning.json) so an in-flight tune never surprises
# the desktop. NOTE: the wallpaper runs RT, so only path-shared knobs (materials, parallax,
# fog) carry over; raster-only lighting knobs (moonlight, ambient) don't affect the RT path.
HEXEN_LIVE_TUNING="$HOME/.nimbus/hexen-tune/live.json"
if [ "$scene" = "hexen" ] && [ -f "$HEXEN_LIVE_TUNING" ]; then
    export NIMBUS_FLUX_HEXEN_TUNING="$HEXEN_LIVE_TUNING"
fi
setsid -f "$BIN" >/tmp/nimbus-flux-wallpaper.log 2>&1 </dev/null

# Watchdog: once Nimbus Flux is confirmed the active wallpaper, stop the engine as
# soon as it is no longer selected. `seen` guards the startup race where plasmashell
# has not yet persisted wallpaperplugin= to appletsrc.
(
    seen=0
    while sleep 1; do
        pgrep -x nimbus-flux >/dev/null || exit 0
        if grep -q "^wallpaperplugin=$PLUGIN_ID\$" "$APPLETSRC" 2>/dev/null; then
            seen=1
        elif [ "$seen" = 1 ]; then
            pkill -x nimbus-flux 2>/dev/null
            exit 0
        fi
    done
) >/dev/null 2>&1 &
echo $! > "$WPID"
disown 2>/dev/null || true
