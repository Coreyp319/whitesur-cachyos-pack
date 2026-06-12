#!/usr/bin/env bash
# =============================================================================
#  WhiteSur macOS-style desktop for CachyOS / KDE Plasma 6 (Wayland)
# =============================================================================
#  Turns a stock CachyOS KDE install into the macOS-style setup:
#    • WhiteSur global theme (Plasma + Qt/Kvantum + GTK light & dark) + icons
#    • Mac cursors, Inter (SF-like) font, Big Sur wallpaper
#    • Floating auto-hiding dock with Launchpad, frosted/blurred, pinned apps
#    • Spotlight (KRunner centered, Meta+Space) + file search
#    • Mac-style window animations, Mission Control hot corner, edge tiling
#    • Heavy blur on translucent surfaces, frosted Konsole
#    • One-click light<->dark toggle (Plasma + Qt + GTK + Firefox follow)
#    • Firefox set to follow the system light/dark theme
#
#  USAGE:   bash whitesur-cachyos-macos.sh
#  Run as your normal user (NOT root). It will call sudo only for packages.
#  Safe to re-run (idempotent-ish). Log out/in afterward for Meta+Space etc.
#
#  Tested target: CachyOS, KDE Plasma 6.6+, Wayland, X86_64.
# =============================================================================
set -uo pipefail

msg(){ printf '\n\033[1;36m::\033[0m \033[1m%s\033[0m\n' "$*"; }
ok(){  printf '   \033[1;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '   \033[1;33m!\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] && { echo "Do NOT run as root. Run as your normal user."; exit 1; }
command -v pacman >/dev/null || { echo "This script targets Arch/CachyOS (pacman not found)."; exit 1; }
[ "${XDG_CURRENT_DESKTOP:-}" = "KDE" ] || warn "XDG_CURRENT_DESKTOP is not KDE — proceeding anyway."
BUILD="$HOME/.cache/whitesur-setup"; mkdir -p "$BUILD/bin"
GH="https://github.com/vinceliuice"

# ---------------------------------------------------------------------------
# 0b. Notice + consent — surfaced so the runner can decide before anything runs
# ---------------------------------------------------------------------------
ASSUME_YES=0
for a in "$@"; do case "$a" in -y|--yes) ASSUME_YES=1 ;; -h|--help)
  echo "Usage: bash $(basename "$0") [-y|--yes]   (-y skips the confirmation prompt)"; exit 0 ;;
esac; done

cat <<'NOTICE'

  ┌────────────────────────────────────────────────────────────────────┐
  │   WhiteSur macOS-style setup — CachyOS / KDE Plasma 6 (Wayland)      │
  └────────────────────────────────────────────────────────────────────┘

  WHAT IT INSTALLS
    WhiteSur theme suite (Plasma, Qt/Kvantum, GTK light+dark, icons,
    cursors, Big Sur wallpaper) • Inter font • floating auto-hide dock
    with Launchpad • Spotlight (Meta+Space) • mac-style window animations
    • heavy blur • frosted Konsole • one-click light/dark toggle.

  REQUIREMENTS
    • Arch / CachyOS (pacman)              • KDE Plasma 6 on Wayland
    • Run as your normal user — NOT root. Uses sudo only to install three
      packages: kvantum, sassc, optipng.

  ⚠  READ FIRST — THIS WILL CHANGE YOUR DESKTOP
    • REPLACES YOUR PANEL / DOCK. Any panel containing a task manager is
      removed and rebuilt as the mac dock — a custom panel layout is lost
      (rebuildable by hand). Everything else is additive/reversible.
    • Restarts plasmashell + reconfigures KWin (brief screen flicker).
    • Edits the WhiteSur panel-background SVG for the dock margin
      (a .bak copy is saved next to it).
    • Points Firefox at "follow system light/dark" (safe — no userChrome).
    • Wallpaper install is BEST-EFFORT; if it misses, set one by hand.
    • LOG OUT / IN afterward to activate Meta+Space and Meta+Ctrl+T
      (Wayland binds global shortcuts at login).
    • Re-runnable, but it rebuilds the dock on every run.
    • Community themes (vinceliuice/WhiteSur), installed to your home dir.
      Provided AS-IS, no warranty — skim the script before trusting it.

  TO REVERT LATER
    System Settings → Global Theme → Breeze (light/dark), then remove the
    dock panel and add a default one. The panel-background .bak restores
    the original dock gap.

NOTICE

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '  Proceed and apply all of the above now? [y/N] '
  read -r REPLY </dev/tty 2>/dev/null || REPLY=""
  case "$REPLY" in
    [yY]|[yY][eE][sS]) echo ;;
    *) echo "  Aborted — nothing was changed."; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------------------
# 1. Packages (the only sudo step)
# ---------------------------------------------------------------------------
msg "Installing packages (sudo)…"
sudo pacman -S --needed --noconfirm kvantum sassc optipng git curl unzip || warn "package install had issues"

# ---------------------------------------------------------------------------
# 2. Download + install the WhiteSur theme suite (all user-level, no sudo)
# ---------------------------------------------------------------------------
clone(){ rm -rf "$BUILD/$1"; git clone --depth=1 "$GH/$1.git" "$BUILD/$1" >/dev/null 2>&1 && ok "cloned $1" || warn "clone $1 failed"; }

msg "Cloning theme repos…"
clone WhiteSur-kde
clone WhiteSur-icon-theme
clone WhiteSur-cursors
clone WhiteSur-gtk-theme
clone WhiteSur-wallpapers

msg "Installing Plasma theme, icons, cursors…"
( cd "$BUILD/WhiteSur-kde"        && ./install.sh >/dev/null 2>&1 ) && ok "WhiteSur Plasma/Kvantum/Aurorae"
( cd "$BUILD/WhiteSur-icon-theme" && ./install.sh >/dev/null 2>&1 ) && ok "WhiteSur icons"
( cd "$BUILD/WhiteSur-cursors"    && ./install.sh >/dev/null 2>&1 ) && ok "WhiteSur cursors"

# The GTK installer insists on detecting GNOME Shell; shim it on KDE.
msg "Installing WhiteSur GTK theme (light + dark, libadwaita)…"
printf '#!/bin/sh\necho "GNOME Shell 46.0"\n' > "$BUILD/bin/gnome-shell"; chmod +x "$BUILD/bin/gnome-shell"
( cd "$BUILD/WhiteSur-gtk-theme" && PATH="$BUILD/bin:$PATH" ./install.sh -c Light -l >/dev/null 2>&1 ) && ok "GTK light"
( cd "$BUILD/WhiteSur-gtk-theme" && PATH="$BUILD/bin:$PATH" ./install.sh -c Dark  -l >/dev/null 2>&1 ) && ok "GTK dark"

msg "Installing Big Sur wallpapers (best-effort)…"
if [ -d "$BUILD/WhiteSur-wallpapers" ]; then
  ( cd "$BUILD/WhiteSur-wallpapers" && { ./install-wallpapers.sh >/dev/null 2>&1 || ./install-gnome-backgrounds.sh >/dev/null 2>&1 || true; } )
  WP=$(ls "$HOME/.local/share/wallpapers/WhiteSur"*/contents/images/*.jpg 2>/dev/null | head -1)
  [ -n "${WP:-}" ] && plasma-apply-wallpaperimage "$WP" >/dev/null 2>&1 && ok "Big Sur wallpaper applied" || ok "wallpapers installed (set manually if needed)"
fi

# ---------------------------------------------------------------------------
# 3. Inter font (SF-like UI font)
# ---------------------------------------------------------------------------
msg "Installing Inter font…"
if ! fc-list | grep -qi "Inter:"; then
  IURL=$(curl -fsSL https://api.github.com/repos/rsms/inter/releases/latest \
         | grep -oE '"browser_download_url": *"[^"]+\.zip"' | grep -oE 'https[^"]+' | head -1)
  [ -z "$IURL" ] && IURL="https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip"
  curl -fsSL -o "$BUILD/inter.zip" "$IURL" && unzip -q -o "$BUILD/inter.zip" -d "$BUILD/inter"
  mkdir -p "$HOME/.local/share/fonts/Inter"
  cp "$BUILD"/inter/extras/ttf/*.ttf "$HOME/.local/share/fonts/Inter/" 2>/dev/null
  fc-cache -f "$HOME/.local/share/fonts/Inter" >/dev/null 2>&1
  ok "Inter installed"
else ok "Inter already present"; fi

# ---------------------------------------------------------------------------
# 4. Patch Kvantum themes: opaque windows + opaque Dolphin view (clean look)
# ---------------------------------------------------------------------------
msg "Patching Kvantum themes (opaque windows, frosted menus only)…"
for KV in "$HOME/.config/Kvantum/WhiteSur/WhiteSur.kvconfig" "$HOME/.config/Kvantum/WhiteSur/WhiteSurDark.kvconfig"; do
  [ -f "$KV" ] || continue
  perl -0777 -pi -e 's/translucent_windows=true/translucent_windows=false/' "$KV"
  perl -0777 -pi -e 's/transparent_dolphin_view=true/transparent_dolphin_view=false/' "$KV"
  perl -0777 -pi -e 's/(reduce_menu_opacity=25\s*\n\s*reduce_window_opacity=)25/${1}0/' "$KV"
done
ok "Kvantum patched"

# ---------------------------------------------------------------------------
# 5. Apply the look (LIGHT by default; toggle to dark later)
# ---------------------------------------------------------------------------
msg "Applying WhiteSur look…"
plasma-apply-colorscheme  WhiteSur            >/dev/null 2>&1
plasma-apply-desktoptheme WhiteSur            >/dev/null 2>&1
plasma-apply-cursortheme  WhiteSur-cursors    >/dev/null 2>&1
kwriteconfig6 --file kdeglobals --group Icons --key Theme WhiteSur
/usr/lib/plasma-changeicons WhiteSur          >/dev/null 2>&1
kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle kvantum
kwriteconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage com.github.vinceliuice.WhiteSur
kwriteconfig6 --file "$HOME/.config/Kvantum/kvantum.kvconfig" --group General --key theme WhiteSur
kwriteconfig6 --file kcminputrc --group Mouse --key cursorTheme WhiteSur-cursors
# Window decoration: WhiteSur Aurorae (mac traffic-light buttons) if installed,
# else leave the stock decoration. Login splash -> WhiteSur.
if [ -d "$HOME/.local/share/aurorae/themes/WhiteSur" ]; then
  kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key library org.kde.kwin.aurorae
  kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key theme __aurorae__svg__WhiteSur
fi
kwriteconfig6 --file ksplashrc --group KSplash --key Engine KSplashQML
kwriteconfig6 --file ksplashrc --group KSplash --key Theme  com.github.vinceliuice.WhiteSur
# GTK light
for v in gtk-3.0 gtk-4.0; do
  kwriteconfig6 --file $v/settings.ini --group Settings --key gtk-theme-name WhiteSur-Light
  kwriteconfig6 --file $v/settings.ini --group Settings --key gtk-icon-theme-name WhiteSur
  kwriteconfig6 --file $v/settings.ini --group Settings --key gtk-cursor-theme-name WhiteSur-cursors
  kwriteconfig6 --file $v/settings.ini --group Settings --key gtk-application-prefer-dark-theme false
done
ok "look applied"

# ---------------------------------------------------------------------------
# 6. Fonts: Inter for UI, Inter Display for titles
# ---------------------------------------------------------------------------
msg "Setting Inter as the UI font…"
F11="Inter,11,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
kwriteconfig6 --file kdeglobals --group General --key font "$F11"
kwriteconfig6 --file kdeglobals --group General --key menuFont "$F11"
kwriteconfig6 --file kdeglobals --group General --key toolBarFont "Inter,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
kwriteconfig6 --file kdeglobals --group General --key smallestReadableFont "Inter,9,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
kwriteconfig6 --file kdeglobals --group WM      --key activeFont "Inter Display,11,-1,5,500,0,0,0,0,0,0,0,0,0,0,1"
# Mono/fixed font: Meslo is a derivative of Apple's Menlo (the macOS terminal
# face), so it pairs with Inter the way SF Mono pairs with SF on macOS. Ships
# with the CachyOS Nerd-Font set; falls back to the system mono if absent.
if fc-list | grep -qi "MesloLGS Nerd Font"; then
  kwriteconfig6 --file kdeglobals --group General --key fixed "MesloLGS Nerd Font Mono,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
fi
# Mac-like font smoothing: no hinting + RGB subpixel = the soft macOS rendering
# (vs the crisper, more-hinted Linux default).
kwriteconfig6 --file kdeglobals --group General --key XftAntialias true
kwriteconfig6 --file kdeglobals --group General --key XftHintStyle hintnone
kwriteconfig6 --file kdeglobals --group General --key XftSubPixel  rgb
ok "fonts set"

# ---------------------------------------------------------------------------
# 7. KWin: blur, hot corner, tiling, mac-style animations
# ---------------------------------------------------------------------------
msg "Configuring KWin (blur, animations, hot corner, tiling)…"
kwriteconfig6 --file kwinrc --group Plugins      --key blurEnabled true
kwriteconfig6 --file kwinrc --group Effect-blur  --key BlurStrength 15
kwriteconfig6 --file kwinrc --group Effect-overview --key BorderActivate 7      # top-left = Overview
kwriteconfig6 --file kwinrc --group Plugins      --key overviewEnabled true
kwriteconfig6 --file kwinrc --group Windows      --key ElectricBorderTiling true
kwriteconfig6 --file kwinrc --group Windows      --key ElectricBorderMaximize true
# animation set: open/close = scale+fade(0.90), minimize = squash, maximize morph
kwriteconfig6 --file kwinrc --group Plugins --key scaleEnabled true
kwriteconfig6 --file kwinrc --group Plugins --key squashEnabled true
kwriteconfig6 --file kwinrc --group Plugins --key maximizeEnabled true
kwriteconfig6 --file kwinrc --group Plugins --key magiclampEnabled false
kwriteconfig6 --file kwinrc --group Plugins --key glideEnabled false
kwriteconfig6 --file kwinrc --group Plugins --key fallapartEnabled false
kwriteconfig6 --file kwinrc --group Effect-scale --key InScale 0.90
kwriteconfig6 --file kwinrc --group Effect-scale --key OutScale 0.90
# Motion language: ~0.9 duration factor gives smooth, deliberate window
# scale/fade (~225ms) that matches the Spotlight/KRunner 220ms OutCubic feel,
# rather than the near-instant 0.25 some CachyOS profiles ship.
kwriteconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor 0.9
ok "KWin configured"

# ---------------------------------------------------------------------------
# 8. Menus translucent, KRunner Spotlight, Baloo, QoL
# ---------------------------------------------------------------------------
msg "Menus, Spotlight, file search, QoL…"
kwriteconfig6 --file breezerc  --group Style   --key MenuOpacity 80
kwriteconfig6 --file krunnerrc  --group General --key FreeFloating true
TAB=$(printf '\t')
kwriteconfig6 --file kglobalshortcutsrc --group "org.kde.krunner.desktop" --key "_launch" \
  "Alt+Space${TAB}Alt+F2${TAB}Meta+Space,Alt+Space${TAB}Alt+F2,KRunner"
kwriteconfig6 --file kcminputrc --group Keyboard --key NumLock 0          # numlock on at login
kwriteconfig6 --file kwinrc     --group NightColor --key Active true      # warm evenings
kwriteconfig6 --file plasmanotifyrc --group Notifications --key PopupPosition TopRight  # mac-style
command -v balooctl6 >/dev/null && balooctl6 enable >/dev/null 2>&1 && ok "file search enabled"
ok "menus/spotlight/QoL done"

# ---------------------------------------------------------------------------
# 9. Frosted Konsole profile
# ---------------------------------------------------------------------------
msg "Creating frosted Konsole profile…"
mkdir -p "$HOME/.local/share/konsole"
cat > "$HOME/.local/share/konsole/Frosted.colorscheme" <<'EOF'
[Background]
Color=28,30,38
[BackgroundIntense]
Color=28,30,38
[Color0]
Color=42,46,56
[Color0Intense]
Color=90,96,110
[Color1]
Color=237,84,84
[Color1Intense]
Color=255,120,120
[Color2]
Color=88,200,120
[Color2Intense]
Color=130,225,160
[Color3]
Color=240,180,80
[Color3Intense]
Color=255,210,120
[Color4]
Color=92,160,245
[Color4Intense]
Color=140,190,255
[Color5]
Color=186,134,232
[Color5Intense]
Color=210,170,250
[Color6]
Color=80,200,205
[Color6Intense]
Color=130,225,230
[Color7]
Color=232,234,240
[Color7Intense]
Color=255,255,255
[Foreground]
Color=224,226,233
[ForegroundIntense]
Color=255,255,255
[General]
Blur=true
Description=Frosted
Opacity=0.8
EOF
cat > "$HOME/.local/share/konsole/Frosted.profile" <<'EOF'
[Appearance]
ColorScheme=Frosted
Font=MesloLGS Nerd Font Mono,11,-1,5,400,0,0,0,0,0,0,0,0,0,0,1
[General]
Name=Frosted
Parent=FALLBACK/
EOF
kwriteconfig6 --file konsolerc --group "Desktop Entry" --key DefaultProfile "Frosted.profile"
ok "Konsole frosted"

# ---------------------------------------------------------------------------
# 10. Light/dark toggle script + launcher
# ---------------------------------------------------------------------------
msg "Installing light/dark toggle…"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
cat > "$HOME/.local/bin/whitesur-theme-toggle.sh" <<'EOF'
#!/bin/bash
# WhiteSur whole-desktop light<->dark toggle. Firefox follows via the portal.
cur=$(kreadconfig6 --file kdeglobals --group General --key ColorScheme)
if [[ "$cur" == *Dark* ]]; then
  COLORS=WhiteSur; PTHEME=WhiteSur; ICONS=WhiteSur; KV=WhiteSur
  GTK=WhiteSur-Light; PREFERDARK=false; LNF=com.github.vinceliuice.WhiteSur; MODE=light
  DECO=__aurorae__svg__WhiteSur;      SPLASH=com.github.vinceliuice.WhiteSur
else
  COLORS=WhiteSurDark; PTHEME=WhiteSur-dark; ICONS=WhiteSur-dark; KV=WhiteSurDark
  GTK=WhiteSur-Dark; PREFERDARK=true; LNF=com.github.vinceliuice.WhiteSur-dark; MODE=dark
  DECO=__aurorae__svg__WhiteSur-dark; SPLASH=com.github.vinceliuice.WhiteSur-dark
fi
plasma-apply-colorscheme  "$COLORS" >/dev/null 2>&1
plasma-apply-desktoptheme "$PTHEME" >/dev/null 2>&1
# If the Settings-refine layer is installed, it owns the icon theme (a systemd
# watcher re-tints the refined icons on color-scheme change) — don't fight it.
if [ -d "$HOME/.local/share/icons/WhiteSur-dark-refined" ] && \
   systemctl --user is-enabled whitesur-refine-icons.path >/dev/null 2>&1; then
  :
else
  kwriteconfig6 --file kdeglobals --group Icons --key Theme "$ICONS"
  /usr/lib/plasma-changeicons "$ICONS" >/dev/null 2>&1
fi
kwriteconfig6 --file "$HOME/.config/Kvantum/kvantum.kvconfig" --group General --key theme "$KV"
kwriteconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage "$LNF"
# Window decoration (WhiteSur Aurorae) + login splash follow the mode.
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key library "org.kde.kwin.aurorae"
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key theme "$DECO"
kwriteconfig6 --file ksplashrc --group KSplash --key Theme "$SPLASH"
qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1
# Wallpaper: light vs dark Big Sur (best-effort — only if the image exists).
if [ "$MODE" = dark ]; then WALLDIR=WhiteSur-dark; else WALLDIR=WhiteSur-light; fi
WALL=$(ls "$HOME/.local/share/wallpapers/$WALLDIR"/contents/images/*.jpg 2>/dev/null | head -1)
[ -n "${WALL:-}" ] && plasma-apply-wallpaperimage "$WALL" >/dev/null 2>&1
for v in gtk-3.0 gtk-4.0; do
  kwriteconfig6 --file "$v/settings.ini" --group Settings --key gtk-theme-name "$GTK"
  kwriteconfig6 --file "$v/settings.ini" --group Settings --key gtk-application-prefer-dark-theme "$PREFERDARK"
  kwriteconfig6 --file "$v/settings.ini" --group Settings --key gtk-icon-theme-name "$ICONS"
done
notify-send -a Theme "Switched to $MODE mode" "Firefox + Qt live; GTK on next launch." 2>/dev/null
EOF
chmod +x "$HOME/.local/bin/whitesur-theme-toggle.sh"
cat > "$HOME/.local/share/applications/whitesur-theme-toggle.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Toggle Light / Dark Theme
Comment=Switch the whole desktop between WhiteSur light and dark
Exec=$HOME/.local/bin/whitesur-theme-toggle.sh
Icon=preferences-desktop-theme-global
Terminal=false
Categories=Utility;Settings;
EOF
kwriteconfig6 --file kglobalshortcutsrc --group "whitesur-theme-toggle.desktop" --key "_launch" \
  "Meta+Ctrl+T,none,Toggle Light / Dark Theme"
kbuildsycoca6 >/dev/null 2>&1
ok "toggle installed (Meta+Ctrl+T after next login)"

# ---------------------------------------------------------------------------
# 11. Build the dock (portable: via Plasma scripting, no hardcoded IDs)
# ---------------------------------------------------------------------------
msg "Building the floating dock…"
# pinned apps: only the ones actually installed
declare -a PINS
for d in org.kde.dolphin firefox brave-browser code org.kde.konsole systemsettings; do
  for base in /usr/share/applications "$HOME/.local/share/applications"; do
    [ -f "$base/$d.desktop" ] && { PINS+=("applications:$d.desktop"); break; }
  done
done
PINS+=("applications:whitesur-theme-toggle.desktop")
LAUNCHERS=$(IFS=,; echo "${PINS[*]}")

PANEL_ID=$(qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '
var ps = panels();
for (var i=0;i<ps.length;i++){
  var w=ps[i].widgets(); var has=false;
  for (var j=0;j<w.length;j++) if (w[j].type=="org.kde.plasma.icontasks") has=true;
  if (has) ps[i].remove();
}
var dock = new Panel;
dock.location="bottom"; dock.height=56;
try{dock.floating=true;}catch(e){} try{dock.alignment="center";}catch(e){} try{dock.lengthMode="fit";}catch(e){}
try{dock.hiding="autohide";}catch(e){}
var launcher = dock.addWidget("org.kde.plasma.kickerdash");
launcher.currentConfigGroup=["General"];
launcher.writeConfig("icon","view-app-grid");
launcher.writeConfig("appNameFormat",0);
launcher.writeConfig("showRecentApps",false);
launcher.writeConfig("showRecentDocs",false);
launcher.writeConfig("alphaSort",true);
var tasks = dock.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup=["General"];
tasks.writeConfig("launchers","'"$LAUNCHERS"'");
dock.addWidget("org.kde.plasma.marginsseparator");
dock.addWidget("org.kde.plasma.systemtray");
dock.addWidget("org.kde.plasma.digitalclock");
print(dock.id);
' 2>/dev/null | tr -dc '0-9')
# translucent panel (not exposed in scripting API → set on the captured containment)
if [ -n "$PANEL_ID" ]; then
  kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
    --group Containments --group "$PANEL_ID" --group General --key panelOpacity 2
  ok "dock built (containment $PANEL_ID), translucent + autohide"
else warn "dock build returned no id — check Plasma scripting"; fi

# ---------------------------------------------------------------------------
# 12. Dock bottom margin (raise the floating gap 8 -> 14 in the theme)
# ---------------------------------------------------------------------------
msg "Adding dock bottom margin…"
PBG="$HOME/.local/share/plasma/desktoptheme/WhiteSur/widgets/panel-background.svgz"
if [ -f "$PBG" ]; then
  cp "$PBG" "$PBG.bak"
  zcat "$PBG" > "$BUILD/pbg.svg"
  perl -0777 -pi -e 's/(id="hint-bottom-inset"\s+width="4"\s+height=")8(")/${1}10${2}/' "$BUILD/pbg.svg"
  perl -0777 -pi -e 's/(height=")11\.999977("\s+width="3\.9999998"\s+id="shadow-hint-bottom-inset")/${1}18${2}/' "$BUILD/pbg.svg"
  gzip -c "$BUILD/pbg.svg" > "$PBG"
  rm -f "$HOME/.cache/plasma-svgelements-"* "$HOME/.cache/plasma_theme_"*.kcache 2>/dev/null
  ok "bottom margin added (backup at $PBG.bak)"
fi

# ---------------------------------------------------------------------------
# 13. Firefox: follow the system light/dark theme (no fragile userChrome)
# ---------------------------------------------------------------------------
msg "Wiring Firefox to follow the system theme…"
mkdir -p "$HOME/.config/environment.d"
echo "MOZ_ENABLE_WAYLAND=1" > "$HOME/.config/environment.d/firefox-wayland.conf"
FF_INI=""
for c in "$HOME/.mozilla/firefox/profiles.ini" "$HOME/.config/mozilla/firefox/profiles.ini"; do
  [ -f "$c" ] && FF_INI="$c" && break
done
if [ -n "$FF_INI" ]; then
  FF_DIR=$(dirname "$FF_INI")
  PROF=$(awk -F= '/^\[Install/{i=1} i&&/^Default=/{print $2; exit}' "$FF_INI")
  [ -z "$PROF" ] && PROF=$(awk -F= '/^Default=.*\.default/{print $2; exit}' "$FF_INI")
  if [ -n "$PROF" ] && [ -d "$FF_DIR/$PROF" ]; then
    cat > "$FF_DIR/$PROF/user.js" <<'EOF'
// Follow the system (KDE) light/dark preference for UI and web content.
user_pref("layout.css.prefers-color-scheme.content-override", 2);
EOF
    ok "Firefox profile $PROF set to follow system"
  else warn "couldn't resolve Firefox default profile — skipped"; fi
else warn "no Firefox profile found — skipped (launch Firefox once, then re-run)"; fi

# ---------------------------------------------------------------------------
# 14. Apply everything live
# ---------------------------------------------------------------------------
msg "Applying (restarting Plasma shell + KWin)…"
qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1
if command -v kquitapp6 >/dev/null; then kquitapp6 plasmashell >/dev/null 2>&1; fi
(kstart plasmashell >/dev/null 2>&1 &) 2>/dev/null || (setsid plasmashell >/dev/null 2>&1 &)

cat <<'DONE'

   ────────────────────────────────────────────────────────────
   ✅  WhiteSur macOS setup complete.

   • Dock auto-hides — push your mouse to the bottom edge.
   • Toggle light/dark: click the theme icon on the dock,
     run "Toggle Light" in Spotlight, or Meta+Ctrl+T (after relogin).
   • LOG OUT AND BACK IN to activate Meta+Space (Spotlight) and
     the toggle shortcut (Wayland binds global keys at login).
   • If GTK apps look unthemed, relaunch them.
   ────────────────────────────────────────────────────────────
DONE
