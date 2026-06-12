# WhiteSur CachyOS pack — macOS-style desktop + OS customization

A personal **CachyOS + KDE Plasma 6 (Wayland)** customization. Layers 1–4 turn a
stock install into a cohesive macOS-style desktop; Layer 5 adds general system
quality-of-life that has nothing to do with the *look*. Five independent layers —
install any subset.

```bash
bash install.sh          # interactive, pick layers
bash install.sh -y       # install all five, no prompts
bash revert.sh           # undo (add --purge to delete installed files)
```

> Run as your **normal user** (not root). `sudo` is used for packages, Layer 3's
> milou patch, Layer 4's SDDM theming, and Layer 5's installs. **Log out / back
> in** afterward to activate `Meta+Space` and `Meta+Ctrl+T` (Wayland binds global
> shortcuts at login).

---

## Layers

### 1 · Base mac desktop  — `1-base/`
WhiteSur global theme (Plasma + Qt/Kvantum + GTK light & dark), icons, mac
cursors, **Inter** UI font + **MesloLGS** (Menlo-like) mono for Konsole/code ·
Big Sur wallpaper · floating **auto-hide dock** with Launchpad + pinned apps,
a **curated system tray** (essentials shown, the rest collapsed — still editable
in Configure System Tray) and an **Inter panel clock** ·
**Spotlight** (centered KRunner, `Meta+Space`) + file search · mac-style window
animations (scale/squash/maximize at a ~0.9 duration tuned to match the Spotlight
motion), Mission-Control hot corner, edge tiling · **WhiteSur window decoration**
(Aurorae traffic-light buttons) · heavy blur · frosted menus & Konsole · mac-style
**font smoothing** (no hinting + RGB subpixel) · 10px floating dock bottom-margin ·
**WhiteSur boot splash** · top-right notifications · **one-click light↔dark toggle**
(dock icon / Spotlight / `Meta+Ctrl+T`) that also flips **window decoration, splash,
and the Big Sur wallpaper** light↔dark · Firefox set to **follow the system**
light/dark theme · QoL: NumLock on at login, Night Color (warm evenings).

⚠ **Replaces your panel/dock** (any panel with a task manager is rebuilt as the
mac dock) and restarts plasmashell. Reverting: System Settings → Global Theme →
Breeze, then remove the dock panel.

### 2 · System Settings refine  — `2-settings-refine/`
Uniform **monochrome line icons** for the System Settings sidebar sections
(replaces the mixed colorful set). A small **systemd path-watcher** re-tints them
to the active text color on every light↔dark switch (~400 ms) **and re-emits the
icon-changed signal** so the running taskbar/tray follow live, and flips the
theme's inherit order so non-overridden icons track the scheme (light-first in
light mode) instead of washing out. Also ships an optional **Kvantum whitespace
fork** (`WhiteSurRefined` + `WhiteSurRefinedDark`, not auto-selected) that adds
breathing room in classic Qt dialogs; if enabled, the watcher rides it light↔dark
too. Fully reversible: `2-settings-refine/revert.sh`.

> Scope note: the Settings sidebar *spacing/layout* is compiled Kirigami QML and
> is **not** reachable by any theming overlay — only the iconography and selection
> colors are. This layer does the reachable part well.

### 3 · KRunner finder  — `3-krunner-finder/`
- **Row styling** *(needs sudo)*: 48px icons, two-line rows (filename + greyed
  path), tighter gutter, fade/lift animations. Patches milou's QML and installs a
  **pacman hook** so it survives milou upgrades. Backs up originals; revert with
  `sudo bash 3-krunner-finder/row-tweak/revert.sh`.
- **Web / Claude runner** *(no sudo)*: type and pause ~3 s for "Search the web"
  rows, or prefix for instant — `s …`/`ddg …` (DuckDuckGo), `gh …` (GitHub),
  `w …` (Wikipedia), `yt …` (YouTube). `c …`/`ai …` → **Ask Claude**, shown only
  if the `claude` CLI is on `PATH` (otherwise it stays hidden).

### 4 · Login + lock screen  — `4-login-lock/`
Brings the two stock-Breeze surfaces into line so **login → lock → desktop** read
as one environment, by giving them the same Big Sur wallpaper:
- **Lock screen** *(no sudo)*: WhiteSur color scheme + Big Sur wallpaper.
- **SDDM login** *(sudo)*: overlays the breeze SDDM theme's background via a
  **non-destructive** `theme.conf.user` (the shipped theme is left untouched).

Run as your normal user — the lock part applies immediately and `sudo` prompts
once for the SDDM part. Revert: `4-login-lock/revert.sh`.

### 5 · System QoL  — `5-system-qol/`
General OS ergonomics — **not** desktop look. Each item is offered as its own
prompt (Enter = yes; `-y` accepts all), reversible, `sudo` for package installs:
- **`paccache.timer`** — weekly prune of old cached packages (needs `pacman-contrib`).
- **Flatpak + Flathub** — installs Flatpak and adds the Flathub remote for Discover.
- **Shell tooling (fish)** — `zoxide` (`z` smart-cd), **starship** prompt, and `fzf`
  keybindings (`Ctrl-R` history · `Ctrl-T` files w/ `bat` preview · `Alt-C` cd),
  dropped in as a guarded `~/.config/fish/conf.d/qol.fish` (no-op until the tools
  exist; doesn't duplicate the CachyOS fish defaults).
- **Timeshift** — installed in rsync mode (ext4-friendly); you pick the target +
  schedule once in `sudo timeshift-gtk`.

Revert: `5-system-qol/revert.sh` (`--purge` also removes the packages).

---

## Requirements
- Arch / CachyOS (`pacman`), **KDE Plasma 6**, **Wayland**
- Layer 1 installs (via sudo): `kvantum sassc optipng`
- Layer 3 runner deps: `python-dbus python-gobject` (web/Claude runner)
- Internet (Layer 1 clones the WhiteSur themes + downloads the Inter font)

## Caveats (please read)
- **Version fragility:** Layer 3's QML patch and the refined icons target *this*
  Plasma/milou (6.6.x). On a very different version the milou patch may no-op
  (the pacman hook re-applies on update); the rest degrades gracefully.
- **Community themes:** built on [vinceliuice/WhiteSur](https://github.com/vinceliuice)
  plus locally-authored overlay files. Installed under `$HOME`. Provided **as-is,
  no warranty** — skim the scripts before trusting them.
- Test on a spare machine / VM before sharing widely.

## Reverting everything
```bash
bash revert.sh           # layers 2–5 fully; layer 1 prints manual steps
bash revert.sh --purge   # also deletes the installed overlay files
```

## Layout
```
install.sh  revert.sh  README.md
1-base/            whitesur-cachyos-macos.sh
2-settings-refine/ install.sh revert.sh icons/ kvantum/ systemd/ bin/
3-krunner-finder/  install.sh revert.sh row-tweak/ claude-runner/
4-login-lock/      install.sh revert.sh
5-system-qol/      install.sh revert.sh fish/
```
