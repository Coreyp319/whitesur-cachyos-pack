#!/usr/bin/env bash
# Revert layer 9 — GPU UI effects. Restores Layer 1's stock blur and turns off
# the shader pass. Config is reverted by default; --purge also removes the
# installed/built packages (kept by default in case you re-enable later).
set -uo pipefail
PURGE="${1:-}"
BUILD="$HOME/.cache/whitesur-gpu-effects"
reconf(){ qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true; }

echo "1/3 Better Blur → stock blur…"
# Only restore stock blur if Better Blur was actually the active one.
if [ "$(kreadconfig6 --file kwinrc --group Plugins --key forceblurEnabled 2>/dev/null)" = "true" ]; then
  kwriteconfig6 --file kwinrc --group Plugins --key forceblurEnabled false
  kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled      true   # back to Layer 1's blur
  echo "    Restored stock KWin blur (Layer 1 default)."
else
  echo "    Better Blur wasn't active — leaving blur settings as-is."
fi

echo "2/3 Desktop shaders pass off…"
kwriteconfig6 --file kwinrc --group Plugins --key kwin_effect_shadersEnabled false
reconf

echo "3/3 Packages / build…"
if [ "$PURGE" = "--purge" ]; then
  for h in paru yay; do command -v "$h" >/dev/null 2>&1 && { "$h" -Rns --noconfirm kwin-effects-forceblur 2>/dev/null; break; }; done
  # kwin-effect-shaders installs via 'sudo make install' — uninstall via its build tree.
  SRC="$BUILD/kwin-effect-shaders"
  [ -f "$SRC/install.sh" ] && ( cd "$SRC" && bash install.sh UNINSTALL >/dev/null 2>&1 ) || true
  rm -rf "$BUILD" "$HOME/.local/share/kwin-effect-shaders_shaders"
  echo "    Purged Better Blur + kwin-effect-shaders (build tree, shaders, package)."
else
  echo "    Left packages/build in place (run with --purge to remove)."
fi

reconf
echo "Done. Both effects are disabled; stock blur is back."
