#!/usr/bin/env bash
# Layer 9 — GPU UI effects (KWin GLSL shaders on the composited desktop).
#
# Plasma 6 already renders the whole UI on the GPU (KWin composites through
# OpenGL/EGL; Plasma's shell draws via the QtQuick scene graph). This layer
# swaps in / adds GLSL shader effects that run inside that pipeline. Two items,
# each opt-in (answer per prompt); pass -y to accept both. Uses sudo for builds.
#
#   • Better Blur  — fork of KWin's blur (id "forceblur"): force-blur ANY window,
#                    rounded corners w/ anti-aliasing, adjustable brightness/
#                    saturation, optional static-blur (low GPU). REPLACES the
#                    stock blur from Layer 1 (they conflict — only one can run).
#                    Installed from the AUR.
#   • Desktop shaders — kwin-effect-shaders (id "kwin_effect_shaders"): a single-
#                    pass GLSL post-process over the final composited image
#                    (ReShade/vkBasalt-style). Ships CAS sharpening, FakeHDR,
#                    deband, tonemap, levels. Built from source. Shader PASS is
#                    OFF until you bind a toggle shortcut — safe to leave enabled.
#
# Wayland only in practice (X11 drops compositing for fullscreen apps).
# Run as your normal user: bash 9-gpu-effects/install.sh   (add -y for both)
# Reversible via revert.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HOME/.cache/whitesur-gpu-effects"
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user, not root."; exit 1; }
command -v pacman >/dev/null || { echo "This layer targets Arch/CachyOS (pacman not found)."; exit 1; }

ALL=0; case "${1:-}" in -y|--yes) ALL=1 ;; -h|--help)
  echo "Usage: bash install.sh [-y]   (-y sets up both GPU-effect items without asking)"; exit 0 ;;
esac

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
msg(){  printf '\n\033[1m:: %s\033[0m\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }
ask(){  [ "$ALL" = 1 ] && return 0; printf '  Set up %s? [Y/n] ' "$1"
        read -r r </dev/tty 2>/dev/null || r=n; case "$r" in [nN]*) return 1 ;; *) return 0 ;; esac; }
reconf(){ qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true; }

echo ":: Layer 9 — GPU UI effects. Pick what you want (Enter = yes)."
[ "${XDG_SESSION_TYPE:-}" = "wayland" ] || warn "Not a Wayland session — these effects need Wayland to work properly."

# ---------------------------------------------------------------------------
# 1. Better Blur (kwin-effects-forceblur) — replaces the stock blur from Layer 1
# ---------------------------------------------------------------------------
if ask "Better Blur (frosted glass: force-blur + rounded corners)"; then
  msg "Better Blur (kwin-effects-forceblur)…"
  AUR=""; for h in paru yay; do command -v "$h" >/dev/null 2>&1 && { AUR="$h"; break; }; done
  if [ -z "$AUR" ]; then
    warn "no AUR helper (paru/yay) found — install one, then: <helper> -S kwin-effects-forceblur"
  elif "$AUR" -S --needed --noconfirm kwin-effects-forceblur; then
    ok "kwin-effects-forceblur installed"
    # Swap stock blur -> forceblur. They CANNOT both run; flip atomically.
    kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled      false
    kwriteconfig6 --file kwinrc --group Plugins --key forceblurEnabled true
    # Match Layer 1's blur strength so the frosted look is continuous.
    kwriteconfig6 --file kwinrc --group Effect-forceblur --key BlurStrength 15
    reconf
    ok "stock blur → Better Blur (BlurStrength 15; tune the rest in its settings dialog)"
    echo "    System Settings → Desktop Effects → Better Blur (gear icon) for"
    echo "    rounded corners, brightness/saturation, static-blur, per-window force-blur."
  else
    warn "Better Blur build failed — stock blur left untouched. Try 'kwin-effects-glass' (the maintained fork)."
  fi
fi

# ---------------------------------------------------------------------------
# 2. Desktop shaders (kwin-effect-shaders) — ReShade-style GLSL post-process
# ---------------------------------------------------------------------------
if ask "Desktop shaders (CAS sharpening / color grading over the whole screen)"; then
  msg "Desktop shaders (kwin-effect-shaders)…"
  sudo pacman -S --needed --noconfirm git cmake extra-cmake-modules kwin || \
    warn "could not install build deps — the build may fail"
  mkdir -p "$BUILD"
  SRC="$BUILD/kwin-effect-shaders"
  if [ -d "$SRC/.git" ]; then git -C "$SRC" pull --ff-only >/dev/null 2>&1 || true
  else git clone --depth 1 https://github.com/kevinlekiller/kwin-effect-shaders "$SRC" || warn "clone failed"; fi
  if [ -f "$SRC/install.sh" ] && ( cd "$SRC" && bash install.sh ); then
    # Effect ships EnabledByDefault, but the visible shader PASS stays off until
    # you bind its toggle shortcut — so enabling the plugin is safe/no-op visually.
    kwriteconfig6 --file kwinrc --group Plugins --key kwin_effect_shadersEnabled true
    reconf
    ok "kwin-effect-shaders built + enabled (shaders in ~/.local/share/kwin-effect-shaders_shaders)"
    echo "    Turn shaders ON:  System Settings → Shortcuts → KWin → 'Toggle Shaders'"
    echo "    (bind a key), then press it. Pick/tune shaders by editing:"
    echo "      ~/.local/share/kwin-effect-shaders_shaders/1_settings.glsl"
    echo "    Good defaults: CAS (sharpening) + deband. Heavy ones (FakeHDR) cost GPU."
  else
    warn "kwin-effect-shaders build failed (it compiles against KWin's private headers —"
    warn "fragile across KWin point releases). Stock desktop is unaffected."
  fi
fi

msg "Layer 9 done. Log out/in if effects don't take immediately."
