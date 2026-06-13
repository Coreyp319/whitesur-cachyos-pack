#!/usr/bin/env bash
# Master revert — undoes all nine layers. Pass --purge to also delete installed files.
#   Layers 2–9 revert cleanly below. Layer 1 (base) now scripts its self-contained
#   user-level bits (toggle, keybind, dock separator, dock-margin SVG); the Global-
#   Theme reset + panel removal remain manual (they depend on your replacement).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PURGE="${1:-}"

echo "── Layer 9: GPU UI effects ──"
bash "$HERE/9-gpu-effects/revert.sh" "$PURGE" || true

echo "── Layer 8: Dolphin Quick Look ──"
bash "$HERE/8-dolphin-quicklook/revert.sh" "$PURGE" || true

echo "── Layer 7: Apple-style notifications ──"
bash "$HERE/7-notifications/revert.sh" "$PURGE" || true

echo "── Layer 6: local AI (Ollama + Hermes) ──"
bash "$HERE/6-local-ai/revert.sh" "$PURGE" || true

echo "── Layer 5: system QoL ──"
bash "$HERE/5-system-qol/revert.sh" "$PURGE" || true

echo "── Layer 4: login + lock screen ──"
bash "$HERE/4-login-lock/revert.sh" || true

echo "── Layer 3: KRunner finder ──"
bash "$HERE/3-krunner-finder/revert.sh" || true

echo "── Layer 2: Settings refine ──"
bash "$HERE/2-settings-refine/revert.sh" "$PURGE" || true

echo "── Layer 1: base mac desktop ──"
# Scripted teardown of the self-contained user-level artifacts this layer adds
# (the light/dark toggle + its keybind, the custom dock separator, and the dock
# float-gap SVG edit). The Global-Theme reset and panel removal stay MANUAL —
# they depend on your chosen replacement and can't be scripted without guessing
# your layout.
rm -f "$HOME/.local/bin/whitesur-theme-toggle.sh" \
      "$HOME/.local/share/applications/whitesur-theme-toggle.desktop"
kwriteconfig6 --file kglobalshortcutsrc --group "whitesur-theme-toggle.desktop" \
  --key "_launch" "none,none,Toggle Light / Dark Theme" 2>/dev/null || true
rm -rf "$HOME/.local/share/plasma/plasmoids/org.whitesur.dockseparator"
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

echo; echo "Revert complete for layers 2–9 (+ Layer 1 user-level bits). Restart Qt apps to see changes."
