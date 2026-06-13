#!/usr/bin/env bash
# Revert Agent B's KRunner bundle.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SVC="dev.corey.krunner.claude"

echo "── Reverting row styling (needs sudo: restores milou QML, removes hook) ──"
sudo bash "$HERE/row-tweak/revert.sh" 2>/dev/null || echo "   (row-tweak revert skipped/failed — run: sudo bash $HERE/row-tweak/revert.sh)"

echo "── Removing the Ask-Claude / Ask-Hermes / web-search runner ──"
kwriteconfig6 --file krunnerrc --group Plugins --key claudesearchEnabled false
rm -f "$HOME/.local/share/dbus-1/services/$SVC.service" \
      "$HOME/.local/share/krunner/dbusplugins/$SVC.desktop"
rm -rf "$HOME/.local/share/krunner-claude-runner"
# Stop the live D-Bus-activated runner too (kquitapp6 only quits krunner itself).
pkill -f 'python3.*claude_runner.py' 2>/dev/null || true
kquitapp6 krunner 2>/dev/null || true
echo "Done. KRunner is back to stock."
