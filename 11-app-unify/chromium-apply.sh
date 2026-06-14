#!/usr/bin/env bash
# Layer 11 — Chromium family (Chromium / Chrome / Brave / Vivaldi / Edge):
# share the WhiteSur frame + pick up the GTK colours. Durable, no .crx theme.
#
# Two keys merged into each profile's `Preferences` JSON (everything else left
# untouched), with the prior value snapshotted so revert is exact:
#   browser.custom_chrome_frame   = false  -> use the system titlebar (KWin draws
#                                             the WhiteSur Aurorae frame; Plasma 6
#                                             advertises zxdg_decoration_manager_v1)
#   extensions.theme.system_theme = 1      -> GTK theme mode (enum 0=default,1=gtk,
#                                             2=qt). KDE often auto-picks 2=qt,
#                                             which is exactly why these browsers
#                                             DON'T match WhiteSur until we set 1.
# Web-content light/dark follows xdg-desktop-portal-kde automatically (no flag).
#
# The browser MUST be closed: it holds Preferences in memory and rewrites it on
# exit, so edits made while it runs are lost. We skip (with a warning) any browser
# that's running.  Re-runnable.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

PY=$(command -v python3 || command -v python) || { warn "python not found — skipped"; exit 0; }
TOOL="$HERE/bin/jsontool.py"
STATE="$HOME/.local/state/nimbus/appunify"
CHANGES='{"browser.custom_chrome_frame": false, "extensions.theme.system_theme": 1}'

# Is a Chromium browser using this user-data-dir? Read its SingletonLock symlink
# (target is "<hostname>-<pid>"), present only while running, and check the pid is
# alive. Far more reliable than `pgrep -f <name>`, which also matches our own
# script's path (…/chromium-apply.sh) and a crash leaves no stale false-positive.
is_running(){
  local lock="$1/SingletonLock" tgt pid
  [ -L "$lock" ] || return 1
  tgt=$(readlink "$lock") || return 1
  pid=${tgt##*-}; case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# name | config dir (under ~/.config)
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
  [ -d "$base" ] || continue
  if is_running "$base"; then
    warn "$name is running — close it and re-run (skipped)"
    continue
  fi
  # Default + every "Profile N"
  for prof in "$base/Default" "$base"/Profile\ *; do
    pref="$prof/Preferences"
    [ -f "$pref" ] || continue
    safe="${name}__$(basename "$prof" | tr ' ' '_')"
    snap="$STATE/$safe.json"
    if "$PY" "$TOOL" apply "$pref" "$snap" "$CHANGES"; then
      ok "$name [$(basename "$prof")] -> system frame + GTK theme"
    else
      warn "$name [$(basename "$prof")] — couldn't parse Preferences (skipped)"
    fi
  done
done
