#!/usr/bin/env bash
# Run a UI-audit helper NETWORK-ISOLATED, kernel-enforced. Prefers a private
# network namespace; if a --user unit can't create one on this box, falls back to
# blocking IP socket families (AF_INET/AF_INET6), which a user unit can always
# enforce. Either way the helper cannot reach the network. Records the mode used.
#
# Usage: run-sandboxed.sh <script.py> [args...]
set -uo pipefail
HHOME="${HERMES_HOME:-$HOME/.hermes}"
RW="$HHOME/ui-audit"
MODEFILE="$RW/usage/.sandbox-mode"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$#" -ge 1 ] || { echo "usage: run-sandboxed.sh <script.py> [args...]" >&2; exit 2; }
command -v systemd-run >/dev/null 2>&1 || { echo "systemd-run not available" >&2; exit 3; }

TARGET="$1"; shift
case "$TARGET" in */*) ;; *) TARGET="$HERE/$TARGET" ;; esac

COMMON=( --user --pipe --wait --quiet --collect
  -p NoNewPrivileges=yes
  -p PrivateTmp=yes
  -p ProtectSystem=strict
  -p ProtectHome=read-only
  -p ReadWritePaths="$RW"
  -p RestrictAddressFamilies="~AF_INET AF_INET6"
  -p SystemCallFilter="@system-service"
  -p LockPersonality=yes )

# Probe: can a --user transient unit get its own network namespace here?
mode="restrict-af"
if systemd-run --user --quiet --pipe --wait --collect -p PrivateNetwork=yes true 2>/dev/null; then
  mode="private-netns"
fi
mkdir -p "$(dirname "$MODEFILE")" 2>/dev/null && printf '%s\n' "$mode" > "$MODEFILE" 2>/dev/null || true

if [ "$mode" = "private-netns" ]; then
  exec systemd-run "${COMMON[@]}" -p PrivateNetwork=yes python3 "$TARGET" "$@"
else
  exec systemd-run "${COMMON[@]}" python3 "$TARGET" "$@"
fi
