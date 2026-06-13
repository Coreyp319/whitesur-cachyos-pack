#!/usr/bin/env bash
# Install + activate the Nimbus Aurora interactive wallpaper (Plasma 6).
# Idempotent: compiles the shader (if qsb is available, else uses the prebuilt
# .qsb shipped in the repo), copies the plugin into the user's wallpaper dir,
# saves the CURRENT wallpaper for revert, and switches the desktop(s) over.
# Run as your normal user.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ID="com.nimbus.aurora"
DEST="$HOME/.local/share/plasma/wallpapers/$PLUGIN_ID"
STATE_DIR="$HOME/.cache/nimbus-gpu-effects"
STATE="$STATE_DIR/aurora-prev-wallpaper"   # line1: plugin id  line2: image url

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

command -v qdbus6 >/dev/null 2>&1 || { warn "qdbus6 not found — is this a Plasma 6 session?"; exit 1; }

# 1. compile the fragment shader -> .qsb (fall back to the prebuilt one)
QSB=""
for c in qsb /usr/lib/qt6/bin/qsb; do command -v "$c" >/dev/null 2>&1 && { QSB="$c"; break; }; done
[ -x /usr/lib/qt6/bin/qsb ] && QSB="${QSB:-/usr/lib/qt6/bin/qsb}"
if [ -n "$QSB" ]; then
  # aurora + the Liquid-style fluid passes (velocity/pressure/dye/display)
  for f in "$HERE"/contents/shaders/*.frag; do
    "$QSB" --qt6 -o "$f.qsb" "$f" \
      && ok "shader compiled: $(basename "$f").qsb" || warn "qsb failed for $(basename "$f") — using prebuilt if present"
  done
else
  warn "qsb not found (install qt6-shadertools to rebuild) — using prebuilt .qsb files"
fi
[ -f "$HERE/contents/shaders/aurora.frag.qsb" ] || { warn "no compiled shader available — aborting"; exit 1; }

# 2. copy the plugin into place (clean deploy so removed files don't linger)
rm -rf "$DEST"; mkdir -p "$DEST"
cp -r "$HERE/metadata.json" "$HERE/contents" "$DEST/"
ok "plugin installed → $DEST"

# 3. save the current wallpaper (only if we're not already the active plugin)
CUR="$(qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript 'print(desktops()[0].wallpaperPlugin)' 2>/dev/null)"
if [ "$CUR" != "$PLUGIN_ID" ] && [ -n "$CUR" ]; then
  IMG="$(qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
    var d = desktops()[0]; d.currentConfigGroup = ['Wallpaper','$CUR','General']; print(d.readConfig('Image'));" 2>/dev/null)"
  mkdir -p "$STATE_DIR"
  printf '%s\n%s\n' "$CUR" "$IMG" > "$STATE"
  ok "saved current wallpaper ($CUR) for revert"
fi

# 4. switch every desktop to the aurora
qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
  var ds = desktops();
  for (var i = 0; i < ds.length; i++) { ds[i].wallpaperPlugin = '$PLUGIN_ID'; }" >/dev/null 2>&1 \
  && ok "aurora set as wallpaper" || warn "could not switch wallpaper live — set it in System Settings → Wallpaper"
