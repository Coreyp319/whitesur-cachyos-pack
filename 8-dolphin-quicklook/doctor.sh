#!/usr/bin/env bash
# Layer 8 drift check — Quick Look on Space (kiview). See nimbus doctor.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"; . "$SELF/../lib/doctor-lib.sh"

UNIT="$HOME/.config/systemd/user/nimbus-quicklook-ensure.service"
SVC="$HOME/.local/share/kio/servicemenus/nimbus-quicklook.desktop"
OLD_SVC="$HOME/.local/share/kio/servicemenus/whitesur-quicklook.desktop"
RC="$HOME/.local/share/kxmlgui5/dolphin/dolphinui.rc"

gate "login re-assert service absent" test -f "$UNIT"

nimbus_lines=$(grep -c 'servicemenu_nimbus-quicklook.desktop::quickLook' "$RC" 2>/dev/null || true)
stale_lines=$(grep -c 'servicemenu_whitesur-quicklook.desktop::quickLook' "$RC" 2>/dev/null || true)

check "login re-assert service enabled"        [ "$(systemctl --user is-enabled nimbus-quicklook-ensure.service 2>/dev/null)" = enabled ]
check "service menu present + executable"      [ -x "$SVC" ]
check "no stale whitesur service menu"         [ ! -e "$OLD_SVC" ]
check "exactly one Space binding in rc"        [ "$nimbus_lines" = 1 ]
check "no stale whitesur binding in rc"        [ "$stale_lines" = 0 ]
check "kiview previewer installed"             has_pkg kiview-git kiview

doctor_done
