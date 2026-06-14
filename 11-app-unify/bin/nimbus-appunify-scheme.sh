#!/usr/bin/env bash
# Flip the Flatpak GTK_THEME override to match the active KDE colour scheme, so
# GTK3 flatpak apps follow light<->dark. Run once at install and on every
# kdeglobals change by nimbus-appunify-scheme.path (the Layer 2/7 watcher
# pattern), which also fires at login — so the override re-asserts itself.
#
# Mirrors the dark-detection in nimbus-theme-toggle-button.sh: CoreyLavender is a
# dark scheme whose name lacks "Dark". Env vars are read at process start, so
# already-running flatpak apps only pick up the new theme on their next launch.
set -eu
command -v flatpak >/dev/null 2>&1 || exit 0

scheme=$(kreadconfig6 --file kdeglobals --group General --key ColorScheme 2>/dev/null || echo "")
case "$scheme" in
  *Dark*|CoreyLavender) theme="WhiteSur-Dark" ;;
  *)                    theme="WhiteSur-Light" ;;
esac
flatpak override --user --env=GTK_THEME="$theme" >/dev/null 2>&1 || true
