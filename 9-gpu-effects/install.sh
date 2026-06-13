#!/usr/bin/env bash
# Layer 9 — GPU UI effects (KWin GLSL shaders on the composited desktop).
#
# Plasma 6 already renders the whole UI on the GPU (KWin composites through
# OpenGL/EGL; Plasma's shell draws via the QtQuick scene graph). This layer
# swaps in / adds GLSL shader effects that run inside that pipeline. Two items,
# each opt-in (answer per prompt); pass -y to accept both. Uses sudo for builds.
#
#   • Glass blur   — maintained fork of KWin's blur (id "glass", AUR
#                    kwin-effects-glass-git; falls back to the archived
#                    "forceblur"): force-blur ANY window, rounded corners,
#                    per-window/dock/menu blur, refraction. REPLACES the stock
#                    blur from Layer 1 (they conflict — only one fork can run).
#                    NB: forks IGNORE `/KWin reconfigure`; driven via /Effects.
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
# Stock effects honour /KWin reconfigure; third-party FORKS ignore it and must be
# driven through the /Effects interface (load/unload/reconfigure a named effect).
eff(){ qdbus6 org.kde.KWin /Effects "org.kde.kwin.Effects.$1" "$2" >/dev/null 2>&1 || true; }

echo ":: Layer 9 — GPU UI effects. Pick what you want (Enter = yes)."
[ "${XDG_SESSION_TYPE:-}" = "wayland" ] || warn "Not a Wayland session — these effects need Wayland to work properly."

# ---------------------------------------------------------------------------
# 1. Glass blur (kwin-effects-glass-git) — replaces the stock blur from Layer 1
# ---------------------------------------------------------------------------
if ask "Glass frosted blur (force-blur + rounded corners; replaces stock blur)"; then
  msg "Glass blur (kwin-effects-glass-git)…"
  AUR=""; for h in paru yay; do command -v "$h" >/dev/null 2>&1 && { AUR="$h"; break; }; done
  if [ -z "$AUR" ]; then
    warn "no AUR helper (paru/yay) found — install one, then: <helper> -S kwin-effects-glass-git"
  else
    # Glass is the maintained fork; forceblur is the archived original (fallback).
    FORK_ID=""
    if   "$AUR" -S --needed --noconfirm kwin-effects-glass-git; then FORK_ID=glass
    elif "$AUR" -S --needed --noconfirm kwin-effects-forceblur;  then FORK_ID=forceblur
    fi
    if [ -n "$FORK_ID" ]; then
      ok "installed $FORK_ID"
      # Swap stock blur -> the fork. Only ONE blur fork may run; flip atomically.
      kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled         false
      kwriteconfig6 --file kwinrc --group Plugins --key "${FORK_ID}Enabled" true
      # Match Layer 1's blur strength so the frosted look stays continuous.
      kwriteconfig6 --file kwinrc --group "Effect-${FORK_ID}" --key BlurStrength 15
      # Forks ignore /KWin reconfigure — swap them live via /Effects.
      eff unloadEffect blur
      eff loadEffect "$FORK_ID"
      ok "stock blur → $FORK_ID (loaded live; BlurStrength 15)"
      echo "    Tune in System Settings → Desktop Effects → $FORK_ID (gear): rounded"
      echo "    corners, brightness/saturation, dock/menu blur, per-window rules."
      echo "    After editing its config, re-apply with (NOT /KWin reconfigure):"
      echo "      qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.reconfigureEffect $FORK_ID"
    else
      warn "Glass/forceblur build failed — stock blur left untouched."
    fi
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
    eff loadEffect kwin_effect_shaders   # fork: load via /Effects, not /KWin reconfigure
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

# ---------------------------------------------------------------------------
# 3. Interactive aurora wallpaper (com.whitesur.aurora) — a cursor-reactive
#    Big Sur gradient rendered by a GLSL shader on the QtQuick scene graph.
#    Self-contained Plasma 6 wallpaper plugin under interactive-bg/.
# ---------------------------------------------------------------------------
if ask "Interactive aurora wallpaper (cursor-reactive animated background)"; then
  msg "Interactive aurora wallpaper (com.whitesur.aurora)…"
  if [ "${XDG_SESSION_TYPE:-}" != "wayland" ]; then
    warn "needs a Plasma 6 Wayland session — skipping."
  else
    # qsb (qt6-shadertools) lets us rebuild the shader; a prebuilt .qsb ships too.
    command -v qsb >/dev/null 2>&1 || [ -x /usr/lib/qt6/bin/qsb ] || \
      sudo pacman -S --needed --noconfirm qt6-shadertools >/dev/null 2>&1 || \
      warn "qt6-shadertools not installed — falling back to the prebuilt shader"
    bash "$HERE/interactive-bg/apply.sh"
    echo "    Tune it: System Settings → Wallpaper → Configure (theme, custom colours,"
    echo "    motion, cursor influence)."
    echo "    Revert just this:  bash 9-gpu-effects/interactive-bg/restore.sh --purge"

    # Window reactivity (v2): a KWin script + a tiny D-Bus bridge daemon feed live
    # window geometry to the shader so the aurora bends + glows around dragged
    # windows. Opt-in; needs python-dbus + python-gobject for the daemon.
    if ask "…and react to windows being dragged (KWin script + a user-service bridge)"; then
      sudo pacman -S --needed --noconfirm python-dbus python-gobject >/dev/null 2>&1 || \
        warn "could not install python-dbus/python-gobject — the bridge daemon needs them"
      bash "$HERE/interactive-bg/windows-apply.sh"
    fi

    # Music reactivity: a user-service taps the audio-output monitor (pw-cat) and
    # FFTs it (numpy) so the aurora pulses with whatever's playing. Opt-in.
    if ask "…and pulse to the music currently playing (audio monitor + FFT bridge)"; then
      sudo pacman -S --needed --noconfirm python-numpy >/dev/null 2>&1 || \
        warn "could not install python-numpy — the audio bridge needs it"
      bash "$HERE/interactive-bg/audio-apply.sh"
    fi

    # Lock screen: drive kscreenlocker's greeter with the same aurora, mirroring
    # the desktop settings (window/music reactivity forced off — the greeter is
    # sandboxed and shows no windows). Opt-in; reversible via lockscreen-restore.sh
    # (also torn down by restore.sh). No extra packages needed.
    if ask "…and use the aurora on the lock screen too"; then
      bash "$HERE/interactive-bg/lockscreen-apply.sh"
    fi
  fi
fi

msg "Layer 9 done. Log out/in if effects don't take immediately."
