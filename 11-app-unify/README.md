# Layer 11 — Cross-app uniformity (browsers · Electron · Flatpak)

The pack already dresses every **toolkit-native** app in WhiteSur — Qt/KDE via
Kvantum, GTK3/GTK4 via the WhiteSur GTK theme, fonts, icons, cursors, even GTK4
notifications. This layer goes after the hold-outs that **draw their own UI and
ignore the system theme**: Firefox, the Chromium family, Electron apps, and
sandboxed Flatpak apps.

**Durable only.** No `userChrome.css`, no Chrome `.crx` themes — both break on
browser updates. The biggest lever is the **window frame**: every browser /
Electron window is pushed onto the *system titlebar* so they share KWin's
WhiteSur Aurorae traffic-lights instead of each drawing its own.

```bash
bash install.sh        # pick per family (Enter = yes)
bash install.sh -y     # all families
bash revert.sh         # undo;  --purge also resets Flatpak overrides
bash doctor.sh         # drift check
```
No sudo. Relaunch each browser / VS Code afterwards to pick up the new frame.

## What each family does

| Family | Mechanism (durable) | File touched |
|---|---|---|
| **Firefox** | `browser.tabs.inTitlebar = 0` (system frame) + `prefers-color-scheme … = 2` (follow light/dark), in a marked `user.js` block | `<profile>/user.js` |
| **Chromium** (Chrome/Brave/Chromium/Vivaldi/Edge) | `browser.custom_chrome_frame = false` (system frame) + `extensions.theme.system_theme = 1` (**GTK** mode; KDE often defaults to `2`=Qt, the mismatch) | each profile's `Preferences` (merged, prior snapshotted) |
| **Electron** | VS Code `window.titleBarStyle = "native"`; global `ELECTRON_OZONE_PLATFORM_HINT=auto` | `…/User/settings.json`, `environment.d/` |
| **Flatpak** | global `--user` overrides expose `~/.themes`+icons read-only and set `GTK_THEME`; a kdeglobals watcher flips it on light/dark | `~/.local/share/flatpak/overrides/global` |

The Chromium browser **must be closed** when this runs (it rewrites `Preferences`
on exit); running browsers are skipped with a warning. Edits are JSON-merged by
`bin/jsontool.py` and the prior value of every touched key is snapshotted under
`~/.local/state/nimbus/appunify/` so `revert.sh` is exact.

## Light/dark
The static bits (titlebars, GTK mode) follow the scheme live. Only the Flatpak
`GTK_THEME` env needs flipping, done by `bin/nimbus-appunify-scheme.sh` via the
`nimbus-appunify-scheme.path` kdeglobals watcher (the same decoupled pattern as
Layers 2 and 7) — so it also re-asserts at login. Already-running Flatpak apps
pick up the new theme on their next launch.

## Honest limits
- **GTK4/libadwaita Flatpaks** ignore `GTK_THEME` by design — they follow
  light/dark but stay Adwaita-ish, not full WhiteSur. Qt/Electron Flatpaks
  (e.g. Spotify) aren't affected by `GTK_THEME` at all.
- **Self-framing Electron** apps (Discord, Spotify) draw their own titlebar with
  no durable switch — only VS Code is fully controllable.
- Forcing the system titlebar is **more "Linux-uniform" than macOS-authentic**
  (real macOS/Safari merge tabs into the titlebar). It's reversible per-browser:
  Firefox `browser.tabs.inTitlebar`→1, Chromium `custom_chrome_frame`→true.
- Re-running **Layer 1** rewrites Firefox's `user.js` wholesale — re-run
  `firefox-apply.sh` afterwards.
