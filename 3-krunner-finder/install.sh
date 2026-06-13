#!/usr/bin/env bash
# Agent B — KRunner finder bundle: (1) bold two-line result rows + animations
# [needs sudo: patches milou's QML + installs a pacman re-apply hook], and
# (2) the "Ask Claude" / "Ask Hermes" / web-search D-Bus runner [user-level, no sudo].
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "── KRunner row styling + animations (needs sudo: system QML patch) ──"
if sudo -v 2>/dev/null; then
  sudo bash "$HERE/row-tweak/install.sh" || echo "   (row-tweak install reported an issue — see above)"
else
  echo "   Skipped row styling (no sudo). Run later:  sudo bash $HERE/row-tweak/install.sh"
fi

echo "── KRunner Ask-Claude / Ask-Hermes / web-search runner (user-level) ──"
bash "$HERE/claude-runner/install.sh"
