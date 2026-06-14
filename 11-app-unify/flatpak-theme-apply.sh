#!/usr/bin/env bash
# Layer 11 — Flatpak: let sandboxed GTK apps see the host WhiteSur theme.
#
# Flatpak apps can't read ~/.themes by default. We add GLOBAL (--user) overrides
# that (a) expose the theme + icon dirs read-only into every sandbox and (b) set
# GTK_THEME to the current scheme's WhiteSur variant. The scheme half is flipped
# on every light/dark toggle by nimbus-appunify-scheme.sh (kdeglobals watcher).
#
# Stored in ~/.local/share/flatpak/overrides/global (separate from the per-app
# override files), so it's cleanly reversible. Honest ceiling: GTK_THEME themes
# GTK3 flatpaks well; GTK4/libadwaita apps largely ignore it (Adwaita by design);
# Qt/Electron flatpaks (e.g. Spotify) aren't affected at all.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }
info(){ printf '  \033[2m·\033[0m %s\n' "$1"; }

command -v flatpak >/dev/null 2>&1 || { warn "flatpak not installed — skipped (Layer 5 installs it)"; exit 0; }

# WhiteSur lives in ~/.themes on this pack (the GTK installer's default). Expose
# both that and the XDG theme dir, plus icons, so whatever path is used is visible.
if flatpak override --user \
     --filesystem="$HOME/.themes:ro" \
     --filesystem="$HOME/.local/share/themes:ro" \
     --filesystem="$HOME/.icons:ro" \
     --filesystem="$HOME/.local/share/icons:ro" \
     --filesystem=xdg-config/gtk-3.0:ro \
     --filesystem=xdg-config/gtk-4.0:ro >/dev/null 2>&1; then
  ok "Flatpak sandboxes can now read ~/.themes + icons (read-only)"
else
  warn "couldn't set Flatpak filesystem overrides"
fi

# GTK_THEME = current scheme's WhiteSur variant (the watcher keeps it in sync).
"$HERE/bin/nimbus-appunify-scheme.sh" && ok "Flatpak GTK_THEME set to the active scheme"
info "GTK3 flatpaks match WhiteSur; GTK4/libadwaita follow light/dark only; restart a running flatpak to apply."
