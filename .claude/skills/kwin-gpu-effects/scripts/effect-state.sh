#!/usr/bin/env bash
# Inspect the live state of KWin GPU blur/shader effects. Read-only.
# Used by the kwin-gpu-effects skill as its "check first" step.
set -uo pipefail

bold(){ printf '\033[1m%s\033[0m\n' "$1"; }
g(){ printf '\033[32m%s\033[0m' "$1"; }   # green
r(){ printf '\033[31m%s\033[0m' "$1"; }   # red
y(){ printf '\033[33m%s\033[0m' "$1"; }   # yellow

rd(){ kreadconfig6 --file kwinrc --group "$1" --key "$2" 2>/dev/null; }
on(){ [ "$1" = "true" ] && g "on " || { [ -z "$1" ] && y "unset" || r "off "; }; }

# Ground truth: what the running compositor ACTUALLY has loaded. For third-party
# forks (forceblur/glass/shaders) this DIVERGES from the *Enabled config keys —
# they ignore `/KWin reconfigure`, so config can say on while nothing is rendering.
LOADED="$(qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadedEffects 2>/dev/null | tr ',' '\n')"
isloaded(){ printf '%s\n' "$LOADED" | grep -qx "$1"; }
rt(){ isloaded "$1" && g "LOADED    " || r "not loaded"; }

bold ":: Session"
printf '  XDG_SESSION_TYPE = %s' "${XDG_SESSION_TYPE:-?}"
[ "${XDG_SESSION_TYPE:-}" = "wayland" ] && printf '  %s\n' "$(g '✓ Wayland')" \
  || printf '  %s\n' "$(r '✗ not Wayland — effects will not work properly')"

BLUR=$(rd Plugins blurEnabled)
FORCE=$(rd Plugins forceblurEnabled)
GLASS=$(rd Plugins glassEnabled)
SHAD=$(rd Plugins kwin_effect_shadersEnabled)

bold ":: Blur effects   (only ONE fork may run: blur | forceblur | glass)"
echo  "                              cfg   runtime       settings"
printf '  stock blur  (blur)        : %s  %s   BlurStrength=%s\n' "$(on "$BLUR")"  "$(rt blur)"      "$(rd Effect-blur BlurStrength)"
printf '  Better Blur (forceblur)   : %s  %s   BlurStrength=%s\n' "$(on "$FORCE")" "$(rt forceblur)" "$(rd Effect-forceblur BlurStrength)"
printf '  Glass       (glass)       : %s  %s   BlurStrength=%s BlurDocks=%s BlurMenus=%s\n' \
  "$(on "$GLASS")" "$(rt glass)" "$(rd Effect-glass BlurStrength)" "$(rd Effect-glass BlurDocks)" "$(rd Effect-glass BlurMenus)"

en=0; for v in "$BLUR" "$FORCE" "$GLASS"; do [ "$v" = "true" ] && en=$((en+1)); done
[ "$en" -gt 1 ] && printf '  %s %d blur forks enabled — they CONFLICT; leave exactly one on.\n' "$(r '✗')" "$en"
[ "$en" -eq 0 ] && printf '  %s no blur fork enabled in config.\n' "$(y '!')"
# config vs runtime mismatch — the classic "my change did nothing"
for pair in "blur:$BLUR" "forceblur:$FORCE" "glass:$GLASS"; do
  id="${pair%%:*}"; cfg="${pair#*:}"
  if [ "$cfg" = "true" ] && ! isloaded "$id"; then
    printf '  %s %-9s: config ON but NOT loaded → apply with  Effects.loadEffect %s\n' "$(y '!')" "$id" "$id"
  elif [ "$cfg" != "true" ] && isloaded "$id"; then
    printf '  %s %-9s: loaded but config OFF (fork ignored /KWin reconfigure) → Effects.unloadEffect %s\n' "$(y '!')" "$id" "$id"
  fi
done

bold ":: Desktop shaders"
printf '  kwin-effect-shaders       : %s  %s  (visible pass needs a toggle shortcut)\n' "$(on "$SHAD")" "$(rt kwin_effect_shaders)"
SDIR="$HOME/.local/share/kwin-effect-shaders_shaders"
if [ -d "$SDIR" ]; then
  printf '  shaders dir : %s\n' "$(g "$SDIR")"
  [ -f "$SDIR/1_settings.glsl" ] && printf '  settings    : %s/1_settings.glsl\n' "$SDIR"
else
  printf '  shaders dir : %s (effect not built/installed)\n' "$(y 'missing')"
fi

bold ":: Installed effect packages"
command -v pacman >/dev/null && {
  pacman -Qq kwin-effects-forceblur kwin-effects-glass kwin-effects-glass-git 2>/dev/null | sort -u | sed 's/^/  pkg: /' || true
}
command -v kwin_x11 >/dev/null 2>&1 || command -v kwin_wayland >/dev/null 2>&1 && \
  printf '  kwin       : %s\n' "$(kwin_wayland --version 2>/dev/null | head -1 || echo '?')"

bold ":: GPU env (Wayland; set in ~/.config/environment.d/, needs relogin)"
for v in KWIN_DRM_NO_AMS KWIN_FORCE_SW_CURSOR MESA_VK_DEVICE_SELECT DRI_PRIME; do
  printf '  %-22s = %s\n' "$v" "${!v:-<unset>}"
done

echo
echo "Apply changes — pick by effect type:"
echo "  stock 'blur'        : qdbus6 org.kde.KWin /KWin reconfigure"
echo "  forks (forceblur/glass/kwin_effect_shaders):"
echo "    qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.reconfigureEffect <id>   # re-read settings"
echo "    qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.{load,unload,toggle}Effect <id>"
