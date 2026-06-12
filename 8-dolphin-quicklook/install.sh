#!/usr/bin/env bash
# Layer 8 — Dolphin Quick Look (Space → preview).
#
# macOS-style "Quick Look": select a file in Dolphin, press Space, a preview
# pops up; press Space (or Esc/Q) to dismiss it; A / D step through the folder
# while it stays open. Dolphin 26.04 / Plasma 6 ship no native spacebar
# preview (Space toggles Selection Mode), so we add a Dolphin *service menu*
# that opens the selection in kiview (a Qt/KDE quick-preview popup that handles
# images, video, audio, PDF and text) and bind Space to that action *inside
# Dolphin*, via Dolphin's own ServiceMenuShortcutManager. The binding lives in
# Dolphin's KXmlGui rc, so Space stays scoped to the file manager (untouched in
# every other app).
#
# Note: kiview previews the file you launched it on and lets you navigate that
# file's folder; it does NOT live-follow Dolphin's selection (no KDE tool does).
#
# Why a full dolphinui.rc and not a one-line edit: KXmlGui only honours a local
# rc that carries the complete menu/toolbar structure at the right gui version;
# a bare ActionProperties stub is silently discarded. We ship Dolphin 26.04's
# rc (gui version 48) with two <Action> lines added — verified on this system.
# If you've already customised Dolphin shortcuts (a local rc exists), we instead
# merge those two lines into your file and back the original up to .orig.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user, not root."; exit 1; }

case "${1:-}" in -h|--help) echo "Usage: bash install.sh [-y]"; exit 0 ;; esac

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
msg(){  printf '\n\033[1m:: %s\033[0m\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

SVC="$HOME/.local/share/kio/servicemenus/whitesur-quicklook.desktop"
RC_DIR="$HOME/.local/share/kxmlgui5/dolphin"     # KF6 keeps the kxmlgui5 dir name
RC="$RC_DIR/dolphinui.rc"
NAME='servicemenu_whitesur-quicklook.desktop::quickLook'   # ServiceMenuShortcutManager naming

# --- 1. previewer: kiview from git master (built via the bundled PKGBUILD) ----
# The AUR `kiview` (v1.1) only has the D-Bus "grab the active Dolphin selection"
# mode, which toggles your selection and errors out from a service menu. master
# adds `kiview -s <file>` (direct path preview) — what we invoke below.
msg "Building kiview from git master (bundled PKGBUILD)…"
if pacman -Qq kiview-git >/dev/null 2>&1; then
  ok "kiview-git already installed"
else
  command -v makepkg >/dev/null 2>&1 || { warn "base-devel/makepkg missing — install it first"; exit 1; }
  # Drop the stock AUR kiview (v1.1) first; it lacks the direct-preview mode.
  pacman -Qq kiview >/dev/null 2>&1 && sudo pacman -R --noconfirm kiview 2>/dev/null || true
  BUILD="$(mktemp -d)"; cp "$HERE/PKGBUILD" "$BUILD/"
  ( cd "$BUILD" && makepkg -si --noconfirm ) || { warn "kiview build failed — aborting"; rm -rf "$BUILD"; exit 1; }
  rm -rf "$BUILD"
  ok "kiview-git built + installed"
fi

# --- 2. the Dolphin service menu (the action Space will trigger) -------------
msg "Installing the Quick Look service menu…"
# Must be executable: KIO refuses to run a user service menu carrying Exec=
# unless the file is marked executable ("not authorized" otherwise).
install -Dm755 "$HERE/whitesur-quicklook.desktop" "$SVC"
kbuildsycoca6 >/dev/null 2>&1 || true
ok "Quick Look entry added to Dolphin's right-click menu"

# --- 3. bind Space to it, scoped to Dolphin ---------------------------------
msg "Binding Space → Quick Look (inside Dolphin only)…"
mkdir -p "$RC_DIR"
if [ ! -f "$RC" ]; then
  install -m644 "$HERE/dolphinui.rc" "$RC"
  ok "installed Dolphin UI rc with Space → Quick Look"
else
  [ -f "$RC.orig" ] || cp "$RC" "$RC.orig"
  if grep -q "$NAME" "$RC"; then
    ok "Quick Look binding already present"
  elif grep -q '</ActionProperties>' "$RC"; then
    # insert our two lines just before the first </ActionProperties>
    awk -v ins="        <Action name=\"$NAME\" shortcut=\"Space\"/>\n        <Action name=\"toggle_selection_mode\" shortcut=\"none\"/>" '
      !done && /<\/ActionProperties>/ { print ins; done=1 }
      { print }' "$RC" > "$RC.tmp" && mv "$RC.tmp" "$RC"
    ok "merged binding into your existing dolphinui.rc (backup: dolphinui.rc.orig)"
  else
    warn "no <ActionProperties> block in your dolphinui.rc — assign Space by hand (see below)"
  fi
fi

# --- 4. window polish: make the kiview popup borderless (KWin rule) ----------
# A transient preview reads better without a titlebar. Matched on kiview's
# Wayland app-id; written to kwinrulesrc. (Close it with Space/Esc/Q.)
msg "Making the preview popup borderless (KWin rule)…"
KR="$HOME/.config/kwinrulesrc"
RULE_ID="whitesur-quicklook-kiview"
[ -f "$KR" ] && [ ! -f "$KR.orig" ] && cp "$KR" "$KR.orig"
kwriteconfig6 --file kwinrulesrc --group "$RULE_ID" --key Description "WhiteSur — Quick Look (kiview) borderless"
kwriteconfig6 --file kwinrulesrc --group "$RULE_ID" --key wmclass "io.github.nyre221.kiview"
kwriteconfig6 --file kwinrulesrc --group "$RULE_ID" --key wmclassmatch 1
kwriteconfig6 --file kwinrulesrc --group "$RULE_ID" --key noborder true
kwriteconfig6 --file kwinrulesrc --group "$RULE_ID" --key noborderrule 2
rules=$(kreadconfig6 --file kwinrulesrc --group General --key rules 2>/dev/null || true)
case ",$rules," in
  *",$RULE_ID,"*) : ;;
  *) rules="${rules:+$rules,}$RULE_ID"
     kwriteconfig6 --file kwinrulesrc --group General --key rules "$rules"
     kwriteconfig6 --file kwinrulesrc --group General --key count "$(printf '%s' "$rules" | tr ',' '\n' | grep -c .)" ;;
esac
qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
ok "kiview popup is borderless"

# --- 5. restart Dolphin if running so it picks up both changes ---------------
if pgrep -x dolphin >/dev/null 2>&1; then
  msg "Restarting Dolphin…"
  kquitapp6 dolphin >/dev/null 2>&1 || true
  sleep 1
  (setsid dolphin >/dev/null 2>&1 &) 2>/dev/null || true
  ok "Dolphin restarted"
fi

cat <<'DONE'

   ────────────────────────────────────────────────────────────
   ✅  Layer 8 done — Quick Look on Space (kiview).
       Select a file in Dolphin and press SPACE to preview;
       SPACE / Esc / Q dismiss it; A / D step prev/next file in
       the folder; Return opens it. (Selection Mode loses its
       Space shortcut — it's still on the toolbar button.)

       If Space doesn't preview (e.g. a different Dolphin
       version), assign it once by hand — it sticks after that:
         Dolphin → Settings → Configure Keyboard Shortcuts
           → "Context Menu Actions" → "Quick Look" → set Space.

       Revert:  ./revert.sh   (--purge also removes kiview-git)
   ────────────────────────────────────────────────────────────
DONE
