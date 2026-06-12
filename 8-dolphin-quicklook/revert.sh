#!/usr/bin/env bash
# Revert Layer 8 — remove the Quick Look service menu + Space binding.
# Surgical + idempotent. --purge also uninstalls the kiview package.
set -uo pipefail
PURGE="${1:-}"

SVC="$HOME/.local/share/kio/servicemenus/whitesur-quicklook.desktop"
RC_DIR="$HOME/.local/share/kxmlgui5/dolphin"
RC="$RC_DIR/dolphinui.rc"
NAME='servicemenu_whitesur-quicklook.desktop::quickLook'
KR="$HOME/.config/kwinrulesrc"
RULE_ID="whitesur-quicklook-kiview"

echo "1/4 Removing the Quick Look service menu…"
rm -f "$SVC"
kbuildsycoca6 >/dev/null 2>&1 || true

echo "2/4 Removing the borderless KWin rule…"
if [ -f "$KR.orig" ]; then
  mv -f "$KR.orig" "$KR"
  echo "    restored your pre-existing kwinrulesrc."
elif [ -f "$KR" ]; then
  rules=$(kreadconfig6 --file kwinrulesrc --group General --key rules 2>/dev/null || true)
  if [ "$rules" = "$RULE_ID" ]; then
    rm -f "$KR"   # we created it solely for this rule
    echo "    removed our generated kwinrulesrc."
  else
    new=$(printf '%s' "$rules" | tr ',' '\n' | grep -vx "$RULE_ID" | paste -sd ',' -)
    kwriteconfig6 --file kwinrulesrc --group General --key rules "$new"
    kwriteconfig6 --file kwinrulesrc --group General --key count "$(printf '%s' "$new" | tr ',' '\n' | grep -c .)"
    awk -v g="[$RULE_ID]" 'BEGIN{skip=0} /^\[/{skip=($0==g)} skip{next} {print}' "$KR" > "$KR.tmp" && mv "$KR.tmp" "$KR"
    echo "    removed our rule from kwinrulesrc."
  fi
fi
qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true

echo "3/4 Removing the Space binding…"
if [ -f "$RC.orig" ]; then
  # We merged into a pre-existing rc — restore the user's original.
  mv -f "$RC.orig" "$RC"
  echo "    restored your pre-existing dolphinui.rc."
elif [ -f "$RC" ] && grep -q "$NAME" "$RC"; then
  # No .orig means we created the rc — remove it entirely (Space → default).
  rm -f "$RC"
  echo "    removed our generated dolphinui.rc (Space reverts to Selection Mode)."
fi

echo "4/4 Restarting Dolphin if running…"
if pgrep -x dolphin >/dev/null 2>&1; then
  kquitapp6 dolphin >/dev/null 2>&1 || true
  sleep 1
  (setsid dolphin >/dev/null 2>&1 &) 2>/dev/null || true
fi

if [ "$PURGE" = "--purge" ]; then
  pkg=$(pacman -Qq kiview-git kiview 2>/dev/null | head -1)
  if [ -n "$pkg" ]; then
    sudo pacman -Rns --noconfirm "$pkg" 2>/dev/null && echo "    Uninstalled $pkg." \
      || echo "    ($pkg not removed — remove manually if desired.)"
  fi
fi
echo "Done. Space reverts to Dolphin's default once Dolphin restarts."
