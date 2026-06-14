#!/usr/bin/env bash
# Layer 11 — Electron: share the WhiteSur frame where the app lets us.
#
# Honest scope: the only Electron app with a durable native-frame switch is
# VS Code (`window.titleBarStyle: native` -> KWin draws the WhiteSur frame). We
# set that for Code / Code-OSS / VSCodium, snapshotting the prior value. We also
# drop a global ELECTRON_OZONE_PLATFORM_HINT=auto so Electron apps run as native
# Wayland clients (lets KWin offer server-side decorations) — already the default
# on Electron 36+, set defensively for older bundles. Self-framing apps like
# Discord/Spotify draw their own titlebar and have NO durable switch — left alone.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

PY=$(command -v python3 || command -v python) || { warn "python not found — skipped"; exit 0; }
TOOL="$HERE/bin/jsontool.py"
STATE="$HOME/.local/state/nimbus/appunify"
CHANGES='{"window.titleBarStyle": "native"}'

for app in "Code" "Code - OSS" "VSCodium"; do
  udir="$HOME/.config/$app/User"
  [ -d "$udir" ] || continue
  settings="$udir/settings.json"
  [ -f "$settings" ] || printf '{}\n' > "$settings"
  safe="vscode__$(printf '%s' "$app" | tr ' ' '_')"
  snap="$STATE/$safe.json"
  if "$PY" "$TOOL" apply --flat "$settings" "$snap" "$CHANGES"; then
    ok "$app -> native title bar (relaunch to see the WhiteSur frame)"
  else
    warn "$app — settings.json isn't strict JSON (has comments?); add \"window.titleBarStyle\": \"native\" by hand"
  fi
done

# Best-effort: native Wayland hint for all Electron apps.
ENVD="$HOME/.config/environment.d"
mkdir -p "$ENVD"
printf 'ELECTRON_OZONE_PLATFORM_HINT=auto\n' > "$ENVD/nimbus-electron-wayland.conf"
ok "Electron Wayland hint set (relogin to take effect)"
