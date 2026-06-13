#!/usr/bin/env bash
# Revert the lock screen to whatever wallpaper it used before lockscreen-apply.sh
# (saved state), or org.kde.image as a fallback. Run as your normal user.
set -uo pipefail
PLUGIN_ID="com.whitesur.aurora"
LOCKSTATE="$HOME/.cache/whitesur-gpu-effects/aurora-prev-lockscreen"
RC="kscreenlockerrc"

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

command -v kwriteconfig6 >/dev/null 2>&1 || { warn "kwriteconfig6 not found — nothing to do."; exit 0; }

CUR=$(kreadconfig6 --file "$RC" --group Greeter --key WallpaperPlugin --default "org.kde.image")
if [ "$CUR" != "$PLUGIN_ID" ]; then
  ok "lock screen wasn't using aurora — left it as-is"
  exit 0
fi

PREV="org.kde.image"; IMG=""
if [ -f "$LOCKSTATE" ]; then
  PREV="$(sed -n 1p "$LOCKSTATE")"; IMG="$(sed -n 2p "$LOCKSTATE")"
fi
[ -n "$PREV" ] || PREV="org.kde.image"

kwriteconfig6 --file "$RC" --group Greeter --key WallpaperPlugin "$PREV"
if [ "$PREV" = "org.kde.image" ] && [ -n "$IMG" ]; then
  kwriteconfig6 --file "$RC" --group Greeter --group Wallpaper --group org.kde.image --group General --key Image "$IMG"
fi
ok "lock screen restored → $PREV"
rm -f "$LOCKSTATE"
