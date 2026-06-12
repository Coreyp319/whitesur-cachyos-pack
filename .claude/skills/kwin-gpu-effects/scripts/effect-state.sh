#!/usr/bin/env bash
# Inspect the live state of KWin GPU blur/shader effects. Read-only.
# Used by the kwin-gpu-effects skill as its "check first" step.
set -uo pipefail

bold(){ printf '\033[1m%s\033[0m\n' "$1"; }
g(){ printf '\033[32m%s\033[0m' "$1"; }   # green
r(){ printf '\033[31m%s\033[0m' "$1"; }   # red
y(){ printf '\033[33m%s\033[0m' "$1"; }   # yellow

rd(){ kreadconfig6 --file kwinrc --group "$1" --key "$2" 2>/dev/null; }
on(){ [ "$1" = "true" ] && g "on" || { [ -z "$1" ] && y "unset(default)" || r "off"; }; }

bold ":: Session"
printf '  XDG_SESSION_TYPE = %s' "${XDG_SESSION_TYPE:-?}"
[ "${XDG_SESSION_TYPE:-}" = "wayland" ] && printf '  %s\n' "$(g '✓ Wayland')" \
  || printf '  %s\n' "$(r '✗ not Wayland — effects will not work properly')"

BLUR=$(rd Plugins blurEnabled)
FORCE=$(rd Plugins forceblurEnabled)
SHAD=$(rd Plugins kwin_effect_shadersEnabled)

bold ":: Blur effects   (only ONE of stock/Better may run)"
printf '  stock blur   (id blur)         : %s   BlurStrength=%s\n' "$(on "$BLUR")"  "$(rd Effect-blur BlurStrength)"
printf '  Better Blur  (id forceblur)    : %s   BlurStrength=%s\n' "$(on "$FORCE")" "$(rd Effect-forceblur BlurStrength)"
if [ "$BLUR" = "true" ] && [ "$FORCE" = "true" ]; then
  printf '  %s both blur effects enabled — they CONFLICT; disable one.\n' "$(r '✗')"
elif [ "$BLUR" != "true" ] && [ "$FORCE" != "true" ]; then
  printf '  %s no blur effect active.\n' "$(y '!')"
fi

bold ":: Desktop shaders"
printf '  kwin-effect-shaders            : %s  (visible pass needs a toggle shortcut)\n' "$(on "$SHAD")"
SDIR="$HOME/.local/share/kwin-effect-shaders_shaders"
if [ -d "$SDIR" ]; then
  printf '  shaders dir : %s\n' "$(g "$SDIR")"
  [ -f "$SDIR/1_settings.glsl" ] && printf '  settings    : %s/1_settings.glsl\n' "$SDIR"
else
  printf '  shaders dir : %s (effect not built/installed)\n' "$(y 'missing')"
fi

bold ":: Installed effect packages"
command -v pacman >/dev/null && {
  pacman -Qq kwin-effects-forceblur kwin-effects-glass 2>/dev/null | sed 's/^/  pkg: /' || true
}
command -v kwin_x11 >/dev/null 2>&1 || command -v kwin_wayland >/dev/null 2>&1 && \
  printf '  kwin       : %s\n' "$(kwin_wayland --version 2>/dev/null | head -1 || echo '?')"

bold ":: GPU env (Wayland; set in ~/.config/environment.d/, needs relogin)"
for v in KWIN_DRM_NO_AMS KWIN_FORCE_SW_CURSOR MESA_VK_DEVICE_SELECT DRI_PRIME; do
  printf '  %-22s = %s\n' "$v" "${!v:-<unset>}"
done

echo
echo "Apply config changes with:  qdbus6 org.kde.KWin /KWin reconfigure"
