#!/usr/bin/env bash
# =============================================================================
#  WhiteSur CachyOS Pack — master installer
#  Four independent layers, each opt-in:
#    1) Base mac desktop   — WhiteSur theme, dock, fonts, blur, animations,
#                            Spotlight, light/dark toggle, Firefox-follows-system
#    2) Settings refine    — theme-aware monochrome System Settings section icons
#    3) KRunner finder     — bold two-line result rows + animations, and an
#                            "Ask Claude"/web-search runner
#    4) Login + lock       — Big Sur continuity on the SDDM login + lock screens
#
#  Run as your normal user (NOT root). Uses sudo only where noted (packages,
#  and Layer 3's milou QML patch). Pass -y to accept all layers non-interactively.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user, not root."; exit 1; }

ALL=0; case "${1:-}" in -y|--yes) ALL=1 ;; -h|--help)
  echo "Usage: bash install.sh [-y]   (-y installs all three layers without asking)"; exit 0 ;;
esac

cat <<'NOTICE'

  ┌──────────────────────────────────────────────────────────────────────┐
  │   WhiteSur macOS-style desktop pack — CachyOS / KDE Plasma 6 (Wayland) │
  └──────────────────────────────────────────────────────────────────────┘

  FOUR LAYERS (pick any):
    1) Base mac desktop  — the full WhiteSur transformation. REPLACES your
       panel/dock, restarts plasmashell, sets Firefox to follow system theme.
    2) Settings refine   — uniform monochrome icons for System Settings
       sidebar sections; a tiny systemd watcher re-tints them on light↔dark.
    3) KRunner finder    — bigger two-line search rows + animations (needs
       sudo: patches milou's QML, adds a pacman re-apply hook), plus a
       web-search / Ask-Claude runner (Claude part needs the `claude` CLI).
    4) Login + lock      — Big Sur wallpaper on the lock screen (user-level)
       and the SDDM login screen (needs sudo), for login→lock→desktop unity.

  REQUIREMENTS:  Arch/CachyOS · KDE Plasma 6 · Wayland · run as normal user.
  REVERSIBLE:    ./revert.sh  (undoes every layer; --purge also deletes files).
  AFTER:         log out / back in to activate Meta+Space + Meta+Ctrl+T.
  Community themes (vinceliuice/WhiteSur) + local custom files. AS-IS, no warranty.

NOTICE

ask(){ [ "$ALL" = 1 ] && return 0; printf '  Install %s? [Y/n] ' "$1"
       read -r r </dev/tty 2>/dev/null || r=n; case "$r" in [nN]*) return 1 ;; *) return 0 ;; esac; }

if ask "LAYER 1 — base mac desktop"; then
  bash "$HERE/1-base/whitesur-cachyos-macos.sh" -y || echo "  (layer 1 reported issues — see above)"
fi
if ask "LAYER 2 — System Settings refined icons"; then
  bash "$HERE/2-settings-refine/install.sh" || echo "  (layer 2 reported issues — see above)"
fi
if ask "LAYER 3 — KRunner finder (sudo for the row patch)"; then
  bash "$HERE/3-krunner-finder/install.sh" || echo "  (layer 3 reported issues — see above)"
fi
if ask "LAYER 4 — login + lock screen (sudo for SDDM)"; then
  bash "$HERE/4-login-lock/install.sh" || echo "  (layer 4 reported issues — see above)"
fi

echo; echo ":: Settling Plasma…"
qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
kquitapp6 plasmashell >/dev/null 2>&1 || true
(kstart plasmashell >/dev/null 2>&1 &) 2>/dev/null || (setsid plasmashell >/dev/null 2>&1 &)

cat <<'DONE'

   ────────────────────────────────────────────────────────────
   ✅  Done. LOG OUT and back in to finish (Meta+Space, Meta+Ctrl+T).
       Dock auto-hides — push your mouse to the bottom edge.
       Toggle light/dark: dock icon · "Toggle Light" in Spotlight · Meta+Ctrl+T.
       Revert anytime:  ./revert.sh   (add --purge to delete installed files)
   ────────────────────────────────────────────────────────────
DONE
