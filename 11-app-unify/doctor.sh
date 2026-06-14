#!/usr/bin/env bash
# Layer 11 drift check — cross-app uniformity (browsers · Electron · Flatpak).
# Verifies only the app families that were actually chosen at install (recorded
# in the gate marker). See nimbus doctor.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"; . "$SELF/../lib/doctor-lib.sh"

STATE="$HOME/.local/state/nimbus/appunify"
MARKER="$STATE/.installed"
PY=$(command -v python3 || command -v python || echo python3)
chosen(){ grep -qx "$1" "$MARKER" 2>/dev/null; }

gate "marker absent" test -f "$MARKER"

# --- Firefox ---------------------------------------------------------------
if chosen firefox; then
  FF_INI=""
  for c in "$HOME/.mozilla/firefox/profiles.ini" "$HOME/.config/mozilla/firefox/profiles.ini"; do
    [ -f "$c" ] && FF_INI="$c" && break
  done
  if [ -n "$FF_INI" ]; then
    FF_DIR=$(dirname "$FF_INI")
    PROF=$(awk -F= '/^\[Install/{i=1} i&&/^Default=/{print $2; exit}' "$FF_INI")
    [ -z "$PROF" ] && PROF=$(awk -F= '/^Default=.*\.default/{print $2; exit}' "$FF_INI")
    check "Firefox system-titlebar pref present" grep -qF 'browser.tabs.inTitlebar' "$FF_DIR/${PROF:-_}/user.js"
  else
    note "Firefox: no profile present (skipped)"
  fi
fi

# --- Chromium family -------------------------------------------------------
if chosen chromium; then
  found=0
  for entry in "chromium:chromium" "google-chrome:chrome" "BraveSoftware/Brave-Browser:brave" "vivaldi:vivaldi" "microsoft-edge:edge"; do
    dir="${entry%%:*}"; label="${entry##*:}"
    pref="$HOME/.config/$dir/Default/Preferences"
    [ -f "$pref" ] || continue
    found=1
    check "$label: system frame + GTK theme" "$PY" -c '
import json,sys
d=json.load(open(sys.argv[1]))
st=d.get("extensions",{}).get("theme",{}).get("system_theme")
cf=d.get("browser",{}).get("custom_chrome_frame")
sys.exit(0 if (st==1 and cf is False) else 1)
' "$pref"
  done
  [ "$found" = 1 ] || note "Chromium family: no installed browser found (skipped)"
fi

# --- Electron (VS Code) ----------------------------------------------------
if chosen electron; then
  found=0
  for app in "Code" "Code - OSS" "VSCodium"; do
    s="$HOME/.config/$app/User/settings.json"
    [ -f "$s" ] || continue
    found=1
    check "$app: native title bar" "$PY" -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get("window.titleBarStyle")=="native" else 1)
' "$s"
  done
  [ "$found" = 1 ] || note "Electron: no VS Code variant found (skipped)"
fi

# --- Flatpak ---------------------------------------------------------------
if chosen flatpak; then
  if command -v flatpak >/dev/null 2>&1; then
    check "Flatpak GTK_THEME override set" bash -c 'flatpak override --user --show 2>/dev/null | grep -q GTK_THEME'
    check "light/dark watcher enabled"     [ "$(systemctl --user is-enabled nimbus-appunify-scheme.path 2>/dev/null)" = enabled ]
  else
    note "flatpak not installed (skipped)"
  fi
fi

doctor_done
