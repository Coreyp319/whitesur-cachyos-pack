#!/usr/bin/env bash
# =============================================================================
#  WhiteSur CachyOS Pack — master installer
#  Five independent layers, each opt-in:
#    1) Base mac desktop   — WhiteSur theme, dock, fonts, blur, animations,
#                            Spotlight, light/dark toggle, Firefox-follows-system
#    2) Settings refine    — theme-aware monochrome System Settings section icons
#    3) KRunner finder     — bold two-line result rows + animations, and an
#                            "Ask Claude"/"Ask Hermes"/web-search runner
#    4) Login + lock       — Big Sur continuity on the SDDM login + lock screens
#    5) System QoL         — paccache, Flatpak+Flathub, fish tooling, Timeshift
#    6) Local AI           — ollama-cuda + Hermes 4 14B / 4.3 36B on the GPU
#    7) Notifications      — Apple-style swaync toasts + notification center
#    8) Dolphin Quick Look — Space previews the selected file in kiview
#    9) GPU UI effects     — Glass blur (force-blur + rounded corners) and
#                            ReShade-style desktop GLSL shaders (CAS sharpening)
#
#  Run as your normal user (NOT root). Uses sudo only where noted (packages,
#  and Layer 3's milou QML patch). Pass -y to accept all layers non-interactively.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user, not root."; exit 1; }

ALL=0; case "${1:-}" in -y|--yes) ALL=1 ;; -h|--help)
  echo "Usage: bash install.sh [-y]   (-y installs all layers without asking)"; exit 0 ;;
esac

cat <<'NOTICE'

  ┌──────────────────────────────────────────────────────────────────────┐
  │   WhiteSur macOS-style desktop pack — CachyOS / KDE Plasma 6 (Wayland) │
  └──────────────────────────────────────────────────────────────────────┘

  NINE LAYERS (pick any):
    1) Base mac desktop  — the full WhiteSur transformation. REPLACES your
       panel/dock, restarts plasmashell, sets Firefox to follow system theme.
    2) Settings refine   — uniform monochrome icons for System Settings
       sidebar sections; a tiny systemd watcher re-tints them on light↔dark.
    3) KRunner finder    — bigger two-line search rows + animations (needs
       sudo: patches milou's QML, adds a pacman re-apply hook), plus a
       web-search / Ask-Claude / Ask-Hermes runner (Claude needs the `claude`
       CLI; Hermes needs Layer 6's Ollama + a hermes model).
    4) Login + lock      — Big Sur wallpaper on the lock screen (user-level)
       and the SDDM login screen (needs sudo), for login→lock→desktop unity.
    5) System QoL        — general OS ergonomics (NOT desktop look): weekly
       pacman-cache prune, Flatpak+Flathub, fish shell tooling (zoxide/starship/
       fzf), and Timeshift restore points. Uses sudo for package installs.
    6) Local AI          — local LLM stack on the NVIDIA GPU: ollama-cuda runner
       + an OpenAI-compatible API on :11434, and the Hermes 4 14B (fast) /
       4.3 36B (smarter) models. No sandbox yet. Uses sudo for the package.
    7) Notifications     — Apple-style notifications via swaync: frosted top-
       right toast cards, styled action buttons + inline reply, and a
       notification center with Do-Not-Disturb (Meta+N). Replaces Plasma's
       native notifications. Uses sudo for the package.
    8) Dolphin Quick Look — macOS-style preview: select a file in Dolphin and
       press Space to pop up a kiview preview (Space/Esc to dismiss; arrows flip
       through the folder). Adds a "Quick Look" service menu + binds Space to it
       inside Dolphin only. Builds kiview from git master. Fully reversible.
    9) GPU UI effects     — GLSL shaders inside KWin's GPU compositing pipeline:
       Glass blur (force-blur ANY window + rounded corners + dock/menu blur;
       REPLACES Layer 1's stock blur — from the AUR) and kwin-effect-shaders
       (ReShade-style desktop post-process: CAS sharpening, deband, tonemap —
       built from source). The shader pass stays OFF until you bind a toggle key.
       Fully reversible.

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
if ask "LAYER 5 — system QoL (sudo for package installs)"; then
  bash "$HERE/5-system-qol/install.sh" $([ "$ALL" = 1 ] && echo -y) || echo "  (layer 5 reported issues — see above)"
fi
if ask "LAYER 6 — local AI: Ollama + Hermes (sudo for the package)"; then
  bash "$HERE/6-local-ai/install.sh" $([ "$ALL" = 1 ] && echo -y) || echo "  (layer 6 reported issues — see above)"
fi
if ask "LAYER 7 — Apple-style notifications (swaync)"; then
  bash "$HERE/7-notifications/install.sh" $([ "$ALL" = 1 ] && echo -y) || echo "  (layer 7 reported issues — see above)"
fi
if ask "LAYER 8 — Dolphin Quick Look (Space → preview)"; then
  bash "$HERE/8-dolphin-quicklook/install.sh" $([ "$ALL" = 1 ] && echo -y) || echo "  (layer 8 reported issues — see above)"
fi
if ask "LAYER 9 — GPU UI effects (Glass blur + desktop shaders)"; then
  bash "$HERE/9-gpu-effects/install.sh" $([ "$ALL" = 1 ] && echo -y) || echo "  (layer 9 reported issues — see above)"
fi

echo; echo ":: Settling Plasma…"
qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
kquitapp6 plasmashell >/dev/null 2>&1 || true
(kstart plasmashell >/dev/null 2>&1 &) 2>/dev/null || (setsid plasmashell >/dev/null 2>&1 &)

cat <<'DONE'

   ────────────────────────────────────────────────────────────
   ✅  Done. LOG OUT and back in to finish (Meta+Space, Meta+Ctrl+T).
       Dock auto-hides — push your mouse to the bottom edge.
       Toggle light/dark: dock icon (☼/☾, relabels itself) · search "Switch"
       in Spotlight · Meta+Ctrl+T.
       Revert anytime:  ./revert.sh   (add --purge to delete installed files)
   ────────────────────────────────────────────────────────────
DONE
