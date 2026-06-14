#!/usr/bin/env bash
# Revert Layer 11 Electron — restore VS Code settings.json from snapshot and
# remove the Electron Wayland env hint.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

PY=$(command -v python3 || command -v python) || { warn "python not found — skipped"; exit 0; }
TOOL="$HERE/bin/jsontool.py"
STATE="$HOME/.local/state/nimbus/appunify"

for app in "Code" "Code - OSS" "VSCodium"; do
  settings="$HOME/.config/$app/User/settings.json"
  safe="vscode__$(printf '%s' "$app" | tr ' ' '_')"
  snap="$STATE/$safe.json"
  [ -f "$snap" ] || continue
  "$PY" "$TOOL" restore --flat "$settings" "$snap" \
    && ok "$app settings restored"
done

rm -f "$HOME/.config/environment.d/nimbus-electron-wayland.conf"
ok "Electron Wayland env hint removed"
