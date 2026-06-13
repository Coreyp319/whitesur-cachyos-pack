#!/usr/bin/env bash
# Revert Layer 8 — remove the Quick Look service menu, the login-persistence
# service, and the Space binding. Surgical + idempotent. --purge also uninstalls
# the kiview package.
set -uo pipefail
PURGE="${1:-}"

SVC_DIR="$HOME/.local/share/kio/servicemenus"
SVC="$SVC_DIR/nimbus-quicklook.desktop"
OLD_SVC="$SVC_DIR/whitesur-quicklook.desktop"     # pre-rebrand name (v0.1.x)
RC_DIR="$HOME/.local/share/kxmlgui5/dolphin"
RC="$RC_DIR/dolphinui.rc"
SEED="$HOME/.local/share/nimbus-quicklook/dolphinui.rc"
BIN="$HOME/.local/bin/nimbus-quicklook-ensure"
UNIT="nimbus-quicklook-ensure.service"
KR="$HOME/.config/kwinrulesrc"
RULE_ID="nimbus-quicklook-kiview"

echo "1/5 Disarming the login-persistence service…"
systemctl --user disable --now "$UNIT" 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/$UNIT"
systemctl --user daemon-reload 2>/dev/null || true
rm -f "$BIN" "$SEED"
rmdir --ignore-fail-on-non-empty "$(dirname "$SEED")" 2>/dev/null || true

echo "2/5 Removing the Quick Look service menu…"
rm -f "$SVC" "$OLD_SVC"
kbuildsycoca6 >/dev/null 2>&1 || true

echo "3/5 Removing the borderless KWin rule…"
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

echo "4/5 Removing the Space binding…"
if [ -f "$RC.orig" ]; then
  # We backed up a pre-existing rc — restore the user's original verbatim.
  mv -f "$RC.orig" "$RC"
  echo "    restored your pre-existing dolphinui.rc."
elif [ -f "$RC" ]; then
  # No .orig: we seeded the rc. Surgically strip just our ActionProperties lines
  # (the quickLook binding + the Selection-Mode Space override) so Dolphin's own
  # menu/toolbar structure and any later user tweaks survive; Space then reverts
  # to its default (Selection Mode). Scoped to the AP block so the menu-structure
  # toggle_selection_mode entry is left untouched.
  awk '
    /<ActionProperties/ { in_ap=1 }
    /<\/ActionProperties>/ { in_ap=0 }
    in_ap && index($0, "::quickLook")                            { next }
    in_ap && index($0, "name=\"toggle_selection_mode\" shortcut") { next }
    { print }
  ' "$RC" > "$RC.tmp" && mv "$RC.tmp" "$RC"
  echo "    stripped our binding from dolphinui.rc (Space reverts to Selection Mode)."
fi

echo "5/5 Restarting Dolphin if running…"
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
