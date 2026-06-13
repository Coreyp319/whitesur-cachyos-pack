#!/usr/bin/env bash
# Layer 1 drift check — WhiteSur desktop base + light/dark toggle.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"; . "$SELF/../lib/doctor-lib.sh"

TOGGLE="$HOME/.local/bin/nimbus-theme-toggle.sh"
gate "theme-toggle helper absent" test -e "$TOGGLE"

laf=$(kreadconfig6 --file kdeglobals --group KDE   --key LookAndFeelPackage 2>/dev/null || true)
icon=$(kreadconfig6 --file kdeglobals --group Icons --key Theme 2>/dev/null || true)
style=$(kreadconfig6 --file kdeglobals --group KDE  --key widgetStyle 2>/dev/null || true)
kbd=$(kreadconfig6 --file kglobalshortcutsrc --group 'nimbus-theme-toggle.desktop' --key '_launch' 2>/dev/null || true)

# Only check what Layer 1 owns unambiguously. LookAndFeel + icon theme are
# legitimately overridden by Layer 2 (Nimbus-dark-refined icons) and the
# CoreyLavender dark theme, so they're reported, not failed.
check "widget style is kvantum (got: ${style:-unset})"  [ "$style" = kvantum ]
check "theme-toggle helper executable"                  [ -x "$TOGGLE" ]
note  "Look-and-Feel:  ${laf:-unset}"
note  "icon theme:     ${icon:-unset}"
note  "Meta+Ctrl+T:    ${kbd:-unset (log out to activate, or re-run layer 1)}"

doctor_done
