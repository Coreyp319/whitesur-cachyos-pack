#!/usr/bin/env bash
# Master revert — undoes all five layers. Pass --purge to also delete installed files.
#   Layer 1 (base): there is no scripted revert; use System Settings → Global Theme →
#   Breeze, then remove the dock panel. The other two layers revert cleanly below.
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
echo "   No scripted revert. To undo: System Settings → Global Theme → Breeze (light/dark),"
echo "   then remove the dock panel (right-click → Enter Edit Mode → Remove Panel)."
echo "   Restore original dock margins: for each of WhiteSur / WhiteSur-dark, copy"
echo "   ~/.local/share/plasma/desktoptheme/<theme>/widgets/panel-background.svgz.bak back."
echo "   Remove the bundled separator widget: rm -rf ~/.local/share/plasma/plasmoids/org.whitesur.dockseparator"

echo; echo "Revert complete for layers 2–9. Restart Qt apps to see changes."
