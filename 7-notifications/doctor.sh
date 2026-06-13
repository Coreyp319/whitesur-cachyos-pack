#!/usr/bin/env bash
# Layer 7 drift check — swaync owns notifications, ordered before plasmashell.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"; . "$SELF/../lib/doctor-lib.sh"

OVR="$HOME/.config/systemd/user/swaync.service"
SHADOW="$HOME/.local/share/dbus-1/services/org.freedesktop.Notifications.service"

gate "swaync.service override absent" test -f "$OVR"

owner=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
  org.freedesktop.DBus GetConnectionUnixProcessID s org.freedesktop.Notifications 2>/dev/null | awk '{print $2}')
ocomm=$(ps -o comm= -p "${owner:-0}" 2>/dev/null || true)

no_cycle(){ ! systemd-analyze --user verify plasma-workspace-wayland.target 2>&1 | grep -qi 'ordering cycle'; }

check "swaync override is the active unit"     [ "$(systemctl --user show swaync.service -p FragmentPath --value 2>/dev/null)" = "$OVR" ]
check "swaync enabled"                         [ "$(systemctl --user is-enabled swaync.service 2>/dev/null)" = enabled ]
check "D-Bus shadow service present"           [ -f "$SHADOW" ]
check "swaync owns the notification bus"       [ "$ocomm" = swaync ]
# The ordering-cycle verify is the slow check (~200ms); skip it for `status`.
[ "$NIMBUS_QUIET" = 1 ] || check "no boot ordering cycle (swaync before plasmashell)" no_cycle

doctor_done
