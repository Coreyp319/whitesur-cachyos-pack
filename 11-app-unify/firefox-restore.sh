#!/usr/bin/env bash
# Revert Layer 11 Firefox — strip our marked block from user.js, leaving any
# other prefs (incl. Layer 1's baseline content-override line) intact.
set -uo pipefail
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }

START="// >>> nimbus-app-unify"
END="// <<< nimbus-app-unify"

FF_INI=""
for c in "$HOME/.mozilla/firefox/profiles.ini" "$HOME/.config/mozilla/firefox/profiles.ini"; do
  [ -f "$c" ] && FF_INI="$c" && break
done
[ -n "$FF_INI" ] || { ok "no Firefox profile (nothing to restore)"; exit 0; }

FF_DIR=$(dirname "$FF_INI")
PROF=$(awk -F= '/^\[Install/{i=1} i&&/^Default=/{print $2; exit}' "$FF_INI")
[ -z "$PROF" ] && PROF=$(awk -F= '/^Default=.*\.default/{print $2; exit}' "$FF_INI")
USERJS="$FF_DIR/${PROF:-}/user.js"

if [ -n "$PROF" ] && [ -f "$USERJS" ] && grep -qF "$START" "$USERJS"; then
  awk -v s="$START" -v e="$END" '
    $0==s{skip=1} skip&&$0==e{skip=0; next} skip{next} {print}
  ' "$USERJS" > "$USERJS.tmp" && mv "$USERJS.tmp" "$USERJS"
  ok "Firefox: removed system-titlebar block (relaunch Firefox to revert the frame)"
else
  ok "Firefox: nothing to restore"
fi
