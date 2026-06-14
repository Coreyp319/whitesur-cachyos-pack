#!/usr/bin/env bash
# Layer 11 — Firefox: share the WhiteSur window frame.
#
# Durable, no userChrome. Two prefs in the profile's user.js, inside a marked
# block so revert strips exactly our lines and nothing else:
#   browser.tabs.inTitlebar = 0   -> Firefox stops drawing its own CSD titlebar,
#                                    so KWin draws the WhiteSur Aurorae frame
#                                    (the same traffic-lights as every other app).
#   layout.css...content-override = 2 -> web content follows the system light/dark
#                                    (Layer 1 base already sets this; harmless dup,
#                                    last-wins, kept here so this layer is whole).
# Firefox's own chrome already follows the GTK (WhiteSur) theme. MOZ_ENABLE_WAYLAND
# is set by Layer 1.  Re-runnable.
set -uo pipefail
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

START="// >>> nimbus-app-unify"
END="// <<< nimbus-app-unify"

# Resolve the default profile the same way Layer 1 step 13 does.
FF_INI=""
for c in "$HOME/.mozilla/firefox/profiles.ini" "$HOME/.config/mozilla/firefox/profiles.ini"; do
  [ -f "$c" ] && FF_INI="$c" && break
done
[ -n "$FF_INI" ] || { warn "no Firefox profile found — launch Firefox once, then re-run (skipped)"; exit 0; }

FF_DIR=$(dirname "$FF_INI")
PROF=$(awk -F= '/^\[Install/{i=1} i&&/^Default=/{print $2; exit}' "$FF_INI")
[ -z "$PROF" ] && PROF=$(awk -F= '/^Default=.*\.default/{print $2; exit}' "$FF_INI")
[ -n "$PROF" ] && [ -d "$FF_DIR/$PROF" ] || { warn "couldn't resolve Firefox default profile (skipped)"; exit 0; }

USERJS="$FF_DIR/$PROF/user.js"
touch "$USERJS"
# Strip any prior block of ours, then append a fresh one (idempotent).
if grep -qF "$START" "$USERJS"; then
  awk -v s="$START" -v e="$END" '
    $0==s{skip=1} skip&&$0==e{skip=0; next} skip{next} {print}
  ' "$USERJS" > "$USERJS.tmp" && mv "$USERJS.tmp" "$USERJS"
fi
{
  printf '%s\n' "$START"
  printf 'user_pref("browser.tabs.inTitlebar", 0);                         // system titlebar -> WhiteSur frame\n'
  printf 'user_pref("layout.css.prefers-color-scheme.content-override", 2); // follow system light/dark\n'
  printf '%s\n' "$END"
} >> "$USERJS"
ok "Firefox profile $PROF -> system titlebar (relaunch Firefox to see the WhiteSur frame)"
