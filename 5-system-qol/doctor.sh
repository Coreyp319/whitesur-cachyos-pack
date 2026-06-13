#!/usr/bin/env bash
# Layer 5 drift check — system QoL grab-bag. Each piece is opt-in, so this is an
# inventory (notes), not pass/fail: as long as something's present the layer is OK.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"; . "$SELF/../lib/doctor-lib.sh"

qol_any(){ has_pkg pacman-contrib flatpak timeshift starship zoxide fzf; }
gate "no QoL packages present" qol_any

flathub=""; flatpak remote-list 2>/dev/null | grep -q flathub && flathub=" + flathub"
fish_tools=""; for p in starship zoxide fzf fd bat eza; do has_pkg "$p" && fish_tools+="$p "; done

note "paccache.timer: $(systemctl is-enabled paccache.timer 2>/dev/null || echo n/a)"
note "flatpak:        $(has_pkg flatpak && echo "installed$flathub" || echo absent)"
note "timeshift:      $(has_pkg timeshift && echo installed || echo absent)"
note "fish tooling:   ${fish_tools:-none}"

doctor_done
