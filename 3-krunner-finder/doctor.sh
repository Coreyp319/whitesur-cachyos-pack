#!/usr/bin/env bash
# Layer 3 drift check — KRunner finder + Ask-Claude/Hermes D-Bus runner.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"; . "$SELF/../lib/doctor-lib.sh"

SVC="$HOME/.local/share/dbus-1/services/dev.corey.krunner.claude.service"
PLUGIN="$HOME/.local/share/krunner/dbusplugins/dev.corey.krunner.claude.desktop"
gate "Ask-Claude runner not installed" test -e "$SVC"

en=$(kreadconfig6 --file krunnerrc --group Plugins --key claudesearchEnabled 2>/dev/null || true)
check "runner D-Bus service present"  [ -f "$SVC" ]
check "runner plugin registered"      [ -f "$PLUGIN" ]
check "runner enabled in krunnerrc"   [ "$en" = true ]

doctor_done
