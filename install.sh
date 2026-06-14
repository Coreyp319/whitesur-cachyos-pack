#!/usr/bin/env bash
# =============================================================================
#  Nimbus CachyOS Pack — master installer
#
#  A thin front-end over the `nimbus` CLI: it prints the overview below, then
#  hands layer selection + install to `nimbus install`, so there is ONE source
#  of truth (nimbus.layers) instead of a hardcoded ladder that drifts from it.
#  Afterwards it settles Plasma. For status/repair use the CLI directly:
#    ./nimbus status        health per layer
#    ./nimbus doctor [id]   detailed drift checks
#    ./nimbus update        re-assert installed layers after a system update
#
#  Run as your normal user (NOT root). Uses sudo only where noted (packages,
#  and Layer 3's milou QML patch). Pass -y to accept all layers non-interactively.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user, not root."; exit 1; }

case "${1:-}" in -h|--help)
  echo "Usage: bash install.sh [-y] [id…]   (front-end for ./nimbus install)"
  echo "  -y  install all layers non-interactively   ·   id…  install specific layers"
  echo "  -n/--dry-run  show what would run, change nothing   ·   see also: ./nimbus help"
  exit 0 ;;
esac

cat <<'NOTICE'

  ┌──────────────────────────────────────────────────────────────────────┐
  │   Nimbus macOS-style desktop pack — CachyOS / KDE Plasma 6 (Wayland) │
  └──────────────────────────────────────────────────────────────────────┘

  TEN LAYERS (pick any):
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
   10) Nimbus Flux        — standalone GPU compute-shader fluid engine (Rust /
       bevy / wgpu): a real Eulerian fluid (ink / mercury / water) you launch as
       an app, drag to push, react to with 1/2/3 + D. Needs the Rust toolchain;
       builds a release binary + adds an app-menu launcher. Separate from the
       desktop — the wallpaper's own "Liquid" style is the integrated version.

  REQUIREMENTS:  Arch/CachyOS · KDE Plasma 6 · Wayland · run as normal user.
  REVERSIBLE:    ./revert.sh  (undoes every layer; --purge also deletes files).
  AFTER:         log out / back in to activate Meta+Space + Meta+Ctrl+T.
  Community themes (vinceliuice/WhiteSur) + local custom files. AS-IS, no warranty.

NOTICE

# Gate on the environment before touching anything (blocks on hard failures like
# root / non-Arch; warnings just print and proceed).
if ! "$HERE/nimbus" preflight; then
  echo; echo "Aborting — resolve the blocker(s) above, then re-run."; exit 1
fi
echo

# Layer selection + install is driven by nimbus.layers (no duplicate ladder).
# Bare `install.sh` -> per-layer [Y/n] prompts; `-y` -> all; `id…` -> those.
"$HERE/nimbus" install "$@"

# Settle Plasma so the new look lands now — but not on a dry run.
case " $* " in
  *" -n "*|*" --dry-run "*) ;;
  *)
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
       Check health:    ./nimbus status   ·   repair:  ./nimbus update
   ────────────────────────────────────────────────────────────
DONE
    ;;
esac
