#!/usr/bin/env bash
# Layer 11 — Cross-app uniformity (browsers · Electron · Flatpak).
#
# The toolkit-native apps (Qt/Kvantum, GTK3/GTK4) already wear WhiteSur. This
# layer pulls in the hold-outs that draw their own UI: Firefox, the Chromium
# family, Electron, and sandboxed Flatpak apps. Durable mechanisms only — NO
# userChrome.css, NO .crx themes (both break on browser updates). The big lever
# is the WINDOW FRAME: every browser/Electron window is pushed onto the system
# titlebar so they share KWin's WhiteSur Aurorae traffic-lights.
#
# Each item is offered separately (Enter = yes); pass -y to take them all. No
# sudo. Fully reversible via revert.sh.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user, not root."; exit 1; }

ALL=0; case "${1:-}" in -y|--yes) ALL=1 ;; -h|--help)
  echo "Usage: bash install.sh [-y]   (-y unifies every app family without asking)"; exit 0 ;;
esac

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
msg(){  printf '\n\033[1m:: %s\033[0m\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }
ask(){ [ "$ALL" = 1 ] && return 0; printf '  Unify %s? [Y/n] ' "$1"
       read -r r </dev/tty 2>/dev/null || r=n; case "$r" in [nN]*) return 1 ;; *) return 0 ;; esac; }

STATE="$HOME/.local/state/nimbus/appunify"
mkdir -p "$STATE"
# Gate marker for doctor.sh — also records WHICH families were chosen (each is
# opt-in), so the drift check only verifies what was actually configured.
MARKER="$STATE/.installed"; : > "$MARKER"

echo ":: Layer 11 — cross-app uniformity. Pick what you want (Enter = yes)."

if ask "Firefox (share the WhiteSur window frame)"; then
  msg "Firefox…";  bash "$HERE/firefox-apply.sh";  echo firefox >> "$MARKER"
fi

if ask "Chromium browsers — Chrome/Brave/Vivaldi/Edge (system frame + GTK colours)"; then
  msg "Chromium family…";  bash "$HERE/chromium-apply.sh";  echo chromium >> "$MARKER"
fi

if ask "VS Code / Electron (native window frame)"; then
  msg "Electron…";  bash "$HERE/electron-apply.sh";  echo electron >> "$MARKER"
fi

if ask "Flatpak apps (see the host WhiteSur theme + follow light/dark)"; then
  msg "Flatpak…";  bash "$HERE/flatpak-theme-apply.sh";  echo flatpak >> "$MARKER"
  # Arm the kdeglobals watcher that keeps the Flatpak GTK_THEME in sync on toggle
  # (and re-asserts at login) — the same decoupled pattern Layers 2 & 7 use.
  if command -v flatpak >/dev/null 2>&1; then
    install -Dm755 "$HERE/bin/nimbus-appunify-scheme.sh" "$HOME/.local/bin/nimbus-appunify-scheme.sh"
    install -Dm644 "$HERE/systemd/nimbus-appunify-scheme.path"    "$HOME/.config/systemd/user/nimbus-appunify-scheme.path"
    install -Dm644 "$HERE/systemd/nimbus-appunify-scheme.service" "$HOME/.config/systemd/user/nimbus-appunify-scheme.service"
    if systemctl --user daemon-reload 2>/dev/null && \
       systemctl --user enable --now nimbus-appunify-scheme.path 2>/dev/null; then
      ok "light/dark watcher armed (nimbus-appunify-scheme.path)"
    else
      warn "systemd --user unavailable now; theme set, light/dark sync arms at next login"
    fi
  fi
fi

cat <<'DONE'

   ────────────────────────────────────────────────────────────
   ✅  Layer 11 done — apps share the WhiteSur frame.

   • RELAUNCH each browser / VS Code to pick up the new titlebar.
   • Chromium-family browsers must have been CLOSED when this ran;
     re-run this layer for any that were open.
   • Flatpak GTK_THEME follows Meta+Ctrl+T; restart a running
     flatpak to apply. (GTK4/libadwaita flatpaks only follow
     light/dark, not full WhiteSur — by libadwaita design.)

   Revert:  ./revert.sh   (--purge also resets Flatpak overrides)
   ────────────────────────────────────────────────────────────
DONE
