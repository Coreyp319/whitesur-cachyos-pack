#!/usr/bin/env bash
# Master revert — a thin front-end over `nimbus revert`, plus the special one-way
# Layer 1 teardown the manifest can't express. Pass --purge to also delete files/
# packages; -n/--dry-run to preview without changing anything.
#   Layers 2–10 revert via nimbus.layers (single source of truth, reverse order).
#   Layer 1 (base) scripts its self-contained user-level bits (toggle, keybind,
#   dock separator, dock-margin SVG) below; the Global-Theme reset + panel removal
#   stay MANUAL — they depend on your chosen replacement.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

PURGE=""; DRY=0
for a in "$@"; do case "$a" in
  --purge)       PURGE=--purge ;;
  -n|--dry-run)  DRY=1 ;;
  -h|--help)     echo "Usage: bash revert.sh [--purge] [-n|--dry-run]"; exit 0 ;;
esac; done

# Layers 10→2 in reverse install order, driven by the manifest (no duplicate
# ladder). --purge (when given) is forwarded; layers with no purge mode ignore it.
nargs=(all); [ -n "$PURGE" ] && nargs+=("$PURGE"); [ "$DRY" = 1 ] && nargs+=(-n)
"$HERE/nimbus" revert "${nargs[@]}"

if [ "$DRY" = 1 ]; then
  echo; echo "── Layer 1 — would run its scripted user-level teardown (toggle/keybind/separator/dock-margins) ──"
  echo "(dry run — nothing changed)"
  exit 0
fi

echo "── Layer 1: base mac desktop ──"
# Scripted teardown of the self-contained user-level artifacts this layer adds
# (the light/dark toggle + its keybind, the custom dock separator, and the dock
# float-gap SVG edit). The Global-Theme reset and panel removal stay MANUAL —
# they depend on your chosen replacement and can't be scripted without guessing
# your layout.
systemctl --user disable --now nimbus-theme-toggle-button.path 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/nimbus-theme-toggle-button.path" \
      "$HOME/.config/systemd/user/nimbus-theme-toggle-button.service"
systemctl --user daemon-reload 2>/dev/null || true
rm -f "$HOME/.local/bin/nimbus-theme-toggle.sh" \
      "$HOME/.local/bin/nimbus-theme-toggle-button.sh" \
      "$HOME/.local/share/applications/nimbus-theme-toggle.desktop"
kwriteconfig6 --file kglobalshortcutsrc --group "nimbus-theme-toggle.desktop" \
  --key "_launch" "none,none,Toggle Light / Dark Theme" 2>/dev/null || true
rm -rf "$HOME/.local/share/plasma/plasmoids/org.nimbus.dockseparator"
# Restore the original dock float-gap for whichever theme backups exist.
for THEME in WhiteSur WhiteSur-dark; do
  PBG="$HOME/.local/share/plasma/desktoptheme/$THEME/widgets/panel-background.svgz"
  [ -f "$PBG.bak" ] && cp -f "$PBG.bak" "$PBG" && echo "   restored $THEME dock margins"
done
rm -f "$HOME/.cache/ksvg-elements" "$HOME/.cache/plasma_theme_"*.kcache 2>/dev/null || true
kbuildsycoca6 >/dev/null 2>&1 || true
echo "   Removed toggle + keybind + dock separator; restored dock margins."
echo "   STILL MANUAL: System Settings → Global Theme → Breeze (light/dark), then"
echo "   remove the dock panel (right-click → Enter Edit Mode → Remove Panel)."

echo; echo "Revert complete for layers 2–10 (+ Layer 1 user-level bits). Restart Qt apps to see changes."
