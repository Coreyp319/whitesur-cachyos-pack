#!/usr/bin/env bash
# Layer 9 drift check — glass blur fork + aurora wallpaper (+ optional reactivity).
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"; . "$SELF/../lib/doctor-lib.sh"

AURORA="$HOME/.local/share/plasma/wallpapers/com.nimbus.aurora"
l9_present(){ [ -d "$AURORA" ] || has_pkg kwin-effects-glass-git kwin-effects-forceblur; }
gate "neither aurora wallpaper nor a blur fork present" l9_present

glass=$(kreadconfig6 --file kwinrc --group Plugins --key glassEnabled 2>/dev/null || true)
shaders=$(kreadconfig6 --file kwinrc --group Plugins --key kwin_effect_shadersEnabled 2>/dev/null || true)

check "glass blur fork installed"              has_pkg kwin-effects-glass-git kwin-effects-forceblur
check "glass blur active in kwinrc (glassEnabled=true, got: ${glass:-unset})" [ "$glass" = true ]
check "aurora wallpaper plugin installed"      [ -d "$AURORA" ]

# Optional / user-toggleable — informational, never counted as drift.
note "aurora window bridge:  $(systemctl --user is-enabled nimbus-aurora-bridge.service 2>/dev/null || echo n/a)"
note "aurora music bridge:   $(systemctl --user is-enabled nimbus-aurora-audio.service  2>/dev/null || echo n/a)"
note "desktop shaders effect: ${shaders:-default-enabled}"

doctor_done
