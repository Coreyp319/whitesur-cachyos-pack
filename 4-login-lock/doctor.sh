#!/usr/bin/env bash
# Layer 4 drift check — Big Sur SDDM login + lock screen.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"; . "$SELF/../lib/doctor-lib.sh"

lock=$(kreadconfig6 --file kscreenlockerrc --group Greeter --key Theme 2>/dev/null || true)
gate "lock screen not themed (layer not installed)" test -n "$lock"

sddm_conf(){ ls /etc/sddm.conf.d/*.conf >/dev/null 2>&1; }
check "lock screen theme is WhiteSur (got: ${lock:-unset})" [ "$lock" = com.github.vinceliuice.WhiteSur ]
check "SDDM Big Sur background installed"   [ -f /usr/share/sddm/themes/breeze/bigsur.jpg ]
check "SDDM config drop-in present"         sddm_conf

doctor_done
