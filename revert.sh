#!/usr/bin/env bash
# Master revert — undoes all four layers. Pass --purge to also delete installed files.
#   Layer 1 (base): there is no scripted revert; use System Settings → Global Theme →
#   Breeze, then remove the dock panel. The other two layers revert cleanly below.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PURGE="${1:-}"

echo "── Layer 4: login + lock screen ──"
bash "$HERE/4-login-lock/revert.sh" || true

echo "── Layer 3: KRunner finder ──"
bash "$HERE/3-krunner-finder/revert.sh" || true

echo "── Layer 2: Settings refine ──"
bash "$HERE/2-settings-refine/revert.sh" "$PURGE" || true

echo "── Layer 1: base mac desktop ──"
echo "   No scripted revert. To undo: System Settings → Global Theme → Breeze (light/dark),"
echo "   then remove the dock panel (right-click → Enter Edit Mode → Remove Panel)."
echo "   Restore the original dock gap from the panel-background .bak if present."

echo; echo "Revert complete for layers 2, 3 & 4. Restart Qt apps to see changes."
