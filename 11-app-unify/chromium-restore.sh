#!/usr/bin/env bash
# Revert Layer 11 Chromium family — restore each profile's Preferences from the
# snapshot taken at apply time (keys we added are removed; keys we changed are
# put back to their prior value). Browser must be closed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

PY=$(command -v python3 || command -v python) || { warn "python not found — skipped"; exit 0; }
TOOL="$HERE/bin/jsontool.py"
STATE="$HOME/.local/state/nimbus/appunify"

# Same SingletonLock running-check as chromium-apply.sh (pgrep -f matches our own
# script path, so we read the browser's own lock instead).
is_running(){
  local lock="$1/SingletonLock" tgt pid
  [ -L "$lock" ] || return 1
  tgt=$(readlink "$lock") || return 1
  pid=${tgt##*-}; case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

REGISTRY='
chromium|chromium
google-chrome|google-chrome
brave|BraveSoftware/Brave-Browser
vivaldi|vivaldi
microsoft-edge|microsoft-edge
'

printf '%s\n' "$REGISTRY" | while IFS='|' read -r name dir; do
  [ -n "$name" ] || continue
  base="$HOME/.config/$dir"
  for prof in "$base/Default" "$base"/Profile\ *; do
    [ -d "$prof" ] || continue
    safe="${name}__$(basename "$prof" | tr ' ' '_')"
    snap="$STATE/$safe.json"
    [ -f "$snap" ] || continue
    if is_running "$base"; then
      warn "$name is running — close it and re-run revert (left as-is)"
      continue
    fi
    "$PY" "$TOOL" restore "$prof/Preferences" "$snap" \
      && ok "$name [$(basename "$prof")] restored"
  done
done
