#!/usr/bin/env bash
# Revert the WhiteSur Aurora wallpaper: switch the desktop(s) back to whatever
# was active before apply.sh ran (saved state), or org.kde.image as a fallback.
# Pass --purge to also delete the installed plugin. Run as your normal user.
set -uo pipefail
PURGE="${1:-}"
PLUGIN_ID="com.whitesur.aurora"
DEST="$HOME/.local/share/plasma/wallpapers/$PLUGIN_ID"
STATE="$HOME/.cache/whitesur-gpu-effects/aurora-prev-wallpaper"

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

command -v qdbus6 >/dev/null 2>&1 || { warn "qdbus6 not found — nothing to do."; exit 0; }

# Tear down the window-reactivity bridge (KWin script + daemon) if it's installed.
_HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$_HERE/windows-restore.sh" ] && bash "$_HERE/windows-restore.sh" "$PURGE" || true
# Revert the lock screen too, if aurora was applied there.
[ -f "$_HERE/lockscreen-restore.sh" ] && bash "$_HERE/lockscreen-restore.sh" || true

# only act if the aurora is actually the active wallpaper
CUR="$(qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript 'print(desktops()[0].wallpaperPlugin)' 2>/dev/null)"
if [ "$CUR" = "$PLUGIN_ID" ]; then
  PREV="org.kde.image"; IMG=""
  if [ -f "$STATE" ]; then PREV="$(sed -n 1p "$STATE")"; IMG="$(sed -n 2p "$STATE")"; fi
  [ -n "$PREV" ] || PREV="org.kde.image"
  qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
    var ds = desktops();
    for (var i = 0; i < ds.length; i++) {
      ds[i].wallpaperPlugin = '$PREV';
      if ('$PREV' === 'org.kde.image' && '$IMG'.length > 0) {
        ds[i].currentConfigGroup = ['Wallpaper','org.kde.image','General'];
        ds[i].writeConfig('Image', '$IMG');
        ds[i].writeConfig('PreviewImage', '$IMG');
      }
    }" >/dev/null 2>&1 && ok "wallpaper restored → $PREV" || warn "could not switch wallpaper live"
else
  ok "aurora wasn't the active wallpaper — left wallpaper as-is"
fi

if [ "$PURGE" = "--purge" ]; then
  rm -rf "$DEST" "$STATE"
  ok "removed aurora plugin + saved state"
else
  echo "    Left the plugin installed (run with --purge to remove it)."
fi
