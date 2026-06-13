#!/usr/bin/env bash
# Use the WhiteSur Aurora wallpaper on the LOCK SCREEN (Plasma 6 kscreenlocker).
# Mirrors the current DESKTOP aurora settings into kscreenlockerrc's [Greeter],
# backing up whatever the lock screen used before so it's fully reversible.
#
# The greeter is sandboxed, so the wallpaper's executable-engine bridges (colour
# scheme / window / music) usually don't run there — and window/music reactivity
# is meaningless on a lock screen anyway. So for the greeter we force WindowReact=0
# and MusicReact=0 and write an EXPLICIT light/dark value (instead of "follow
# scheme", which depends on a probe that may be blocked), leaving a clean,
# cursor-reactive animated wallpaper. Re-run this after changing desktop settings
# to re-sync. Run as your normal user.
set -uo pipefail
PLUGIN_ID="com.whitesur.aurora"
DEST="$HOME/.local/share/plasma/wallpapers/$PLUGIN_ID"
STATE_DIR="$HOME/.cache/whitesur-gpu-effects"
LOCKSTATE="$STATE_DIR/aurora-prev-lockscreen"   # line1: plugin id  line2: image path
RC="kscreenlockerrc"

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

for c in kwriteconfig6 kreadconfig6 qdbus6; do
  command -v "$c" >/dev/null 2>&1 || { warn "$c not found — is this a Plasma 6 session?"; exit 1; }
done
[ -d "$DEST" ] || { warn "aurora plugin not installed — run ./apply.sh first"; exit 1; }

# read a desktop aurora config value (with a fallback) via plasmashell scripting,
# so we mirror whatever screen 0 currently shows regardless of containment number.
read_cfg(){
  qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
    var d = desktops()[0];
    d.currentConfigGroup = ['Wallpaper','$PLUGIN_ID','General'];
    print(d.readConfig('$1', '$2'));" 2>/dev/null
}

THEME=$(read_cfg Theme 0)
STYLE=$(read_cfg Style 0)
SPEED=$(read_cfg Speed 1.0)
INTENS=$(read_cfg Intensity 1.0)
INTER=$(read_cfg Interactivity 0.0)
C0=$(read_cfg Color0 "#0d0f29"); C1=$(read_cfg Color1 "#1c2e73"); C2=$(read_cfg Color2 "#4552b8")
C3=$(read_cfg Color3 "#8f5cb8"); C4=$(read_cfg Color4 "#fa8c73")

# explicit light/dark from the live colour scheme (greeter can't probe it reliably)
SCHEME=$(kreadconfig6 --file kdeglobals --group General --key ColorScheme 2>/dev/null)
case "$SCHEME" in *Dark*) APPEAR=2; MODE=dark;; *) APPEAR=1; MODE=light;; esac

# back up the current lock-screen wallpaper — but only if it isn't already aurora,
# so re-running never clobbers the real backup.
CUR=$(kreadconfig6 --file "$RC" --group Greeter --key WallpaperPlugin --default "org.kde.image")
if [ "$CUR" != "$PLUGIN_ID" ]; then
  IMG=$(kreadconfig6 --file "$RC" --group Greeter --group Wallpaper --group "$CUR" --group General --key Image)
  mkdir -p "$STATE_DIR"
  printf '%s\n%s\n' "$CUR" "$IMG" > "$LOCKSTATE"
  ok "saved current lock-screen wallpaper ($CUR) for revert"
fi

W(){ kwriteconfig6 --file "$RC" --group Greeter --group Wallpaper --group "$PLUGIN_ID" --group General --key "$1" "$2"; }
W Theme "$THEME"; W Style "$STYLE"; W Speed "$SPEED"; W Intensity "$INTENS"; W Interactivity "$INTER"
W Color0 "$C0"; W Color1 "$C1"; W Color2 "$C2"; W Color3 "$C3"; W Color4 "$C4"
W Appearance "$APPEAR"          # explicit light/dark, not "follow scheme"
W WindowReact 0                 # no user windows on the lock screen
W MusicReact 0                  # audio bridge isn't reachable from the greeter
kwriteconfig6 --file "$RC" --group Greeter --key WallpaperPlugin "$PLUGIN_ID"
ok "lock screen set to aurora (Style=$STYLE, Theme=$THEME, $MODE mode)"

echo
echo "    Test it now:  loginctl lock-session    (or press Meta+L)"
echo "    Revert:       ./lockscreen-restore.sh"
echo "    If the greeter is blank, just type your password to unlock, then revert."
