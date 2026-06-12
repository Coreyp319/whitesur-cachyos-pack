#!/usr/bin/env bash
# Revert Agent A's System Settings refinement. Surgical — only undoes what it added.
# Does NOT touch your light/dark choice, color scheme, or main Kvantum selection.
#   --purge  also deletes the installed theme files from disk.
set -eu
NAME="whitesur-refine-icons"

echo "1/4 Stopping + removing the theme-aware icon watcher…"
systemctl --user disable --now "$NAME.path" 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/$NAME.path" \
      "$HOME/.config/systemd/user/$NAME.service" \
      "$HOME/.config/systemd/user/default.target.wants/$NAME.path"
systemctl --user daemon-reload 2>/dev/null || true

echo "2/4 Resetting icon theme to stock WhiteSur (matching current light/dark)…"
fg=$(kreadconfig6 --file kdeglobals --group "Colors:Window" --key ForegroundNormal 2>/dev/null || echo "36,36,36")
sum=$(( ${fg%%,*} + ${fg##*,} ))
if [ "$sum" -lt 320 ]; then stock="WhiteSur"; else stock="WhiteSur-dark"; fi
[ -d "$HOME/.local/share/icons/$stock" ] || stock="WhiteSur-dark"
kwriteconfig6 --file kdeglobals --group Icons --key Theme "$stock"

echo "3/4 Un-selecting the Kvantum whitespace fork if active…"
cur=$(kreadconfig6 --file "$HOME/.config/Kvantum/kvantum.kvconfig" --group General --key theme 2>/dev/null || echo "")
case "$cur" in
  WhiteSurRefinedDark) kwriteconfig6 --file "$HOME/.config/Kvantum/kvantum.kvconfig" --group General --key theme WhiteSurDark ;;
  WhiteSurRefined)     kwriteconfig6 --file "$HOME/.config/Kvantum/kvantum.kvconfig" --group General --key theme WhiteSur ;;
esac

if [ "${1:-}" = "--purge" ]; then
  echo "4/4 Purging installed refine files…"
  rm -rf "$HOME/.config/Kvantum/WhiteSurRefined" \
         "$HOME/.config/Kvantum/WhiteSurRefinedDark" \
         "$HOME/.local/share/icons/WhiteSur-dark-refined" \
         "$HOME/.local/bin/$NAME"
else
  echo "4/4 Leaving files on disk (run with --purge to delete). Unselected = harmless."
fi
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
echo "Reverted to stock $stock icons. Restart open Qt apps to see the change."
