#!/usr/bin/env bash
# Revert Layer 11 Flatpak theming — remove the GLOBAL override the pack created.
#
# We reset the global override outright rather than surgically un-setting keys:
# `--unset-env=GTK_THEME` leaves an empty `GTK_THEME=` in [Environment], which is
# the exact value that breaks GTK4/libadwaita flatpaks — worse than not reverting.
# The pack owns the global override (the per-app override files are separate and
# untouched), so a clean reset is both correct and safe.
set -uo pipefail
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

command -v flatpak >/dev/null 2>&1 || { ok "flatpak not installed (nothing to restore)"; exit 0; }

if flatpak override --user --reset >/dev/null 2>&1; then
  ok "Flatpak global override removed (per-app overrides untouched)"
else
  warn "couldn't clear Flatpak global override"
fi
