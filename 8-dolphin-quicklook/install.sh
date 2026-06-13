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
#
# Why a login service and not just a one-time edit: dolphinui.rc is a file
# *Dolphin* owns — it rewrites it on exit and on any shortcut/toolbar change, and
# KDE can regenerate it on a Dolphin update — so the binding silently drifts away
# between restarts. So we install nimbus-quicklook-ensure (idempotent; owns the
# rc migrate/insert logic) + a systemd-user oneshot that re-asserts all three
# legs of the binding at every login. A pre-existing rc is backed up to .orig.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user, not root."; exit 1; }

case "${1:-}" in -h|--help) echo "Usage: bash install.sh [-y]"; exit 0 ;; esac

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
msg(){  printf '\n\033[1m:: %s\033[0m\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

SVC_DIR="$HOME/.local/share/kio/servicemenus"
SVC="$SVC_DIR/nimbus-quicklook.desktop"
OLD_SVC="$SVC_DIR/whitesur-quicklook.desktop"    # pre-rebrand name (v0.1.x) — migrate away
RC_DIR="$HOME/.local/share/kxmlgui5/dolphin"     # KF6 keeps the kxmlgui5 dir name
RC="$RC_DIR/dolphinui.rc"
SEED="$HOME/.local/share/nimbus-quicklook/dolphinui.rc"  # canonical full rc the helper reseeds from
BIN="$HOME/.local/bin/nimbus-quicklook-ensure"
UNIT="nimbus-quicklook-ensure.service"
NAME='servicemenu_nimbus-quicklook.desktop::quickLook'   # ServiceMenuShortcutManager naming

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
# Drop the pre-rebrand whitesur-quicklook.desktop so it can't double the menu
# entry or leave the rc pointing at a now-absent action.
[ -e "$OLD_SVC" ] && { rm -f "$OLD_SVC"; ok "removed pre-rebrand whitesur-quicklook.desktop"; }
# Must be executable: KIO refuses to run a user service menu carrying Exec=
# unless the file is marked executable ("not authorized" otherwise).
install -Dm755 "$HERE/nimbus-quicklook.desktop" "$SVC"
kbuildsycoca6 >/dev/null 2>&1 || true
ok "Quick Look entry added to Dolphin's right-click menu"

# --- 3. bind Space, and keep it bound across every restart -------------------
# The binding lives in dolphinui.rc, a file Dolphin OWNS and rewrites on exit /
# on any shortcut change, and that KDE can regenerate on a Dolphin update — so a
# one-shot edit here does not survive. Instead we install a self-contained helper
# + a systemd-user oneshot that re-asserts the binding at every login, and run it
# once now. The helper owns the rc migrate/insert logic (one source of truth).
msg "Binding Space → Quick Look and arming login persistence…"
# Seed: the canonical full rc the helper reseeds from if dolphinui.rc goes missing.
install -Dm644 "$HERE/dolphinui.rc" "$SEED"
# Back up the user's pre-existing rc once, so revert can restore it verbatim.
[ -f "$RC" ] && [ ! -f "$RC.orig" ] && cp "$RC" "$RC.orig"
# The helper (re-assert all three legs) + the login unit that runs it.
install -Dm755 "$HERE/bin/nimbus-quicklook-ensure" "$BIN"
install -Dm644 "$HERE/systemd/$UNIT" "$HOME/.config/systemd/user/$UNIT"
if systemctl --user daemon-reload 2>/dev/null; then
  # enable → runs at every future login;  --now → runs it once right here, which
  # is what actually writes the Space binding into the rc.
  systemctl --user enable --now "$UNIT" 2>/dev/null \
    && ok "Space bound + login-persistence service armed ($UNIT)" \
    || { "$BIN" || true; ok "Space bound (service enable deferred — no user bus?)"; }
else
  # No user systemd bus (e.g. over plain ssh): bind now, persistence on next login.
  "$BIN" || true
  warn "systemd --user unavailable now; binding applied, persistence arms at next login"
fi

# --- 4. window polish: make the kiview popup borderless (KWin rule) ----------
# A transient preview reads better without a titlebar. Matched on kiview's
# Wayland app-id; written to kwinrulesrc. (Close it with Space/Esc/Q.)
msg "Making the preview popup borderless (KWin rule)…"
KR="$HOME/.config/kwinrulesrc"
RULE_ID="nimbus-quicklook-kiview"
[ -f "$KR" ] && [ ! -f "$KR.orig" ] && cp "$KR" "$KR.orig"
kwriteconfig6 --file kwinrulesrc --group "$RULE_ID" --key Description "Nimbus — Quick Look (kiview) borderless"
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

       The binding is re-asserted at every login by
       nimbus-quicklook-ensure.service, so it survives Dolphin
       and KDE updates. To re-apply by hand any time:
         nimbus-quicklook-ensure   (then restart Dolphin)

       Revert:  ./revert.sh   (--purge also removes kiview-git)
   ────────────────────────────────────────────────────────────
DONE
