#!/usr/bin/env bash
# Agent A — System Settings refinement: theme-aware monochrome section icons
# (+ optional Kvantum whitespace fork). User-level, no sudo. Reversible via revert.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="whitesur-refine-icons"   # neutralized from the original cocovox-* naming

echo ":: Installing refined System Settings icon theme…"
mkdir -p "$HOME/.local/share/icons"
rm -rf "$HOME/.local/share/icons/WhiteSur-dark-refined"
cp -r "$HERE/icons/WhiteSur-dark-refined" "$HOME/.local/share/icons/"
gtk-update-icon-cache -q -f "$HOME/.local/share/icons/WhiteSur-dark-refined" 2>/dev/null || true

echo ":: Installing theme-aware re-bake script + color-scheme watcher…"
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
install -m755 "$HERE/bin/refine-icons" "$HOME/.local/bin/$NAME"
# Deploy systemd units, renaming references to the neutral name + pointing at the script.
sed "s|cocovox-refine-icons|$NAME|g" "$HERE/systemd/refine-icons.service" > "$HOME/.config/systemd/user/$NAME.service"
sed "s|cocovox-refine-icons|$NAME|g" "$HERE/systemd/refine-icons.path"    > "$HOME/.config/systemd/user/$NAME.path"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable --now "$NAME.path" 2>/dev/null || true

echo ":: Selecting refined icons + initial tone bake…"
kwriteconfig6 --file kdeglobals --group Icons --key Theme WhiteSur-dark-refined
"$HOME/.local/bin/$NAME" 2>/dev/null || true
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

# Optional: the Kvantum whitespace fork — light + dark variants installed but
# NOT auto-selected. The icon watcher above will ride them on light↔dark if you
# opt in by selecting WhiteSurRefined; it then auto-swaps to WhiteSurRefinedDark
# in dark mode (and back), so both must be present.
if [ -d "$HERE/kvantum/WhiteSurRefined" ]; then
  mkdir -p "$HOME/.config/Kvantum"
  for kv in "$HERE"/kvantum/WhiteSurRefined*; do
    [ -d "$kv" ] && cp -r "$kv" "$HOME/.config/Kvantum/"
  done
  echo ":: Kvantum whitespace fork installed (light + dark, NOT selected)."
  echo "   To enable it:  kwriteconfig6 --file ~/.config/Kvantum/kvantum.kvconfig --group General --key theme WhiteSurRefined"
  echo "   (the icon watcher then swaps to WhiteSurRefinedDark automatically in dark mode)"
fi

echo ":: Done — refined System Settings icons are live and theme-aware (re-bake on light↔dark)."
