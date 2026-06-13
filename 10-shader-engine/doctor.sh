#!/usr/bin/env bash
# Layer 10 drift check — standalone bevy/wgpu fluid engine (Nimbus Flux).
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"; . "$SELF/../lib/doctor-lib.sh"

BIN="$SELF/nimbus-flux/target/release/nimbus-flux"
DESKTOP="$HOME/.local/share/applications/nimbus-flux.desktop"
gate "engine not built" test -x "$BIN"

check "nimbus-flux binary built + executable" [ -x "$BIN" ]
check "launcher .desktop installed"           [ -f "$DESKTOP" ]

doctor_done
