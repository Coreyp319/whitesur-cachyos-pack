# WhiteSur Aurora — interactive wallpaper

A Plasma 6 wallpaper plugin (`com.whitesur.aurora`) that renders an animated
Big Sur / WhiteSur aurora with a GLSL fragment shader on the QtQuick scene graph.
Part of Layer 9 (GPU effects). Wayland + Plasma 6.

## What it does (v1 — shipped)

- **Animated aurora** — a domain-warped flowing gradient over a calm vertical
  "sky", drifting on its own (frame-synced time).
- **Cursor-reactive** — a warm light blooms under the pointer and gently bends the
  flow toward it. Tracked hover-only (`MouseArea`, `Qt.NoButton`) so desktop clicks
  and the right-click menu pass straight through.
- **Themes** — Big Sur · Monterey · Graphite · Sunset · Nord presets, selectable in
  *System Settings → Wallpaper → Configure*.
- **Styles** — a **Style** control switches the *base look* (how the background field
  is drawn) while every theme, the light/dark lift, and all reactivity stay shared:
  **Flow** (domain-warped fbm ribbons, the default), **Mesh gradient** (drifting soft
  colour sources — the Sonoma look), **Silk curtains** (vertical aurora-borealis
  bands), **Caustics** (slow water-light shimmer). Each is built only from the palette
  stops, so all four work across every theme + custom palette. Add one in
  `baseLook()` (see `BASE-VARIATIONS-HANDOFF.md`).
- **Custom palette** — a "Custom" theme (last in the list) exposes five colour
  pickers (shadow → highlight). Seeded with the Big Sur palette.
- **Light/dark** — Follow colour scheme (default) / Always light / Always dark.
- **Motion**, **Cursor influence**, **Vividness**, and **React to windows** sliders.
- **Reduce-motion aware** — freezes the drift when KDE's animation speed is set to
  *Instant* (`AnimationDurationFactor = 0`); polled live like the colour scheme.
- **Window-reactive** (opt-in, v2 — shipped) — drag a window and the aurora bends
  the flow outward around every window edge, glows along the borders, and trails a
  velocity-driven **wake** behind the one you're moving. Needs the bridge (below);
  scaled by the *React to windows* slider, zero-cost at 0.
- **Music-reactive** (opt-in — shipped) — the aurora pulses with whatever's playing:
  **bass** surges/zooms the flow and blooms a warm core, **loudness** swells the
  brightness, **treble** adds shimmer, **beats** ripple from centre. Driven by the
  audio bridge (`audio-apply.sh`): a `systemd --user` service taps the default sink's
  monitor with `pw-cat`, FFTs it (numpy), and writes bass/mid/treble/level/beat to
  `audio.json` in the runtime dir for the wallpaper to poll. Your own output only —
  no mic, no D-Bus. Scaled by the *React to music* slider, zero-cost at 0.

## Layout

```
metadata.json                      KPackageStructure: Plasma/Wallpaper
contents/ui/main.qml               WallpaperItem root; drives the ShaderEffect
contents/ui/config.qml             Configure page (theme, colours, sliders)
contents/config/main.xml           KConfigXT schema (Theme, Style, Appearance, Color0..4, Speed, Interactivity, Intensity)
contents/shaders/aurora.frag       GLSL source (Vulkan dialect, #version 440)
contents/shaders/aurora.frag.qsb   compiled shader (rebuilt at install if qsb present)
apply.sh / restore.sh              install+activate / revert (saves prior wallpaper)

— window reactivity (v2 bridge) —
kwin-script/                       KWin/Script package: watches windows, pushes
                                     geometry over D-Bus (sandboxed: no file I/O)
aurora-bridge.py                   D-Bus daemon org.whitesur.Aurora → state file
whitesur-aurora-bridge.service     systemd --user unit for the daemon
windows-apply.sh / windows-restore.sh   install+enable / disable the bridge

— music reactivity —
aurora-audio-bridge.py             pw-cat monitor → numpy FFT → audio.json
whitesur-aurora-audio.service      systemd --user unit for the audio bridge
audio-apply.sh / audio-restore.sh       install+enable / disable the bridge

— lock screen (opt-in) —
lockscreen-apply.sh / lockscreen-restore.sh   mirror the desktop aurora onto
                                     kscreenlocker's greeter / put it back. Forces
                                     WindowReact=0 & MusicReact=0 and an explicit
                                     light/dark (the greeter is sandboxed). Re-run
                                     apply after changing desktop settings to re-sync.
```

Build the shader by hand: `qsb --qt6 -o contents/shaders/aurora.frag.qsb contents/shaders/aurora.frag`
(`qsb` ships in `qt6-shadertools`, at `/usr/lib/qt6/bin/qsb`).

## Install / revert

Driven by Layer 9 (`9-gpu-effects/install.sh` item 3 / `revert.sh`), or directly:

```bash
bash interactive-bg/apply.sh              # compile, install, set as wallpaper
bash interactive-bg/restore.sh            # restore the previous wallpaper
bash interactive-bg/restore.sh --purge    # …and delete the plugin
```

`apply.sh` saves the current wallpaper plugin + image to
`~/.cache/whitesur-gpu-effects/aurora-prev-wallpaper` so revert is faithful.

## Window reactivity — the bridge (why it's not just a QML change)

A Plasma wallpaper runs inside `plasmashell` and, on Wayland, has **no access to
other windows** — geometry or pixels; that lives in the compositor (KWin). And a
KWin *script* (the only thing that can see live window geometry) is **sandboxed: no
filesystem**. So the data takes three hops:

```
KWin script ──D-Bus──► aurora-bridge daemon ──state file──► wallpaper ──► shader
(live geometry +    (org.whitesur.Aurora;     ($XDG_RUNTIME_DIR/   (polls @30 Hz,
 move velocity;      atomic write — the only   whitesur-aurora/     normalises per
 throttled ~30 Hz)   hop allowed to touch fs)  windows.json)        screen, smooths)
```

- **`kwin-script/`** — connects `interactiveMoveResizeStepped/Finished`,
  `frameGeometryChanged`, `windowAdded/Removed/Activated`; sends up to 6 window
  rects + the moving one's velocity (global px) via `callDBus`, throttled to ~33 ms.
- **`aurora-bridge.py`** — owns `org.whitesur.Aurora`, `UpdateWindows(s)` writes the
  JSON atomically (`mkstemp` + `os.replace`) so the wallpaper never reads a torn file.
- **`main.qml`** — a `Timer` polls the file (XHR `file://`, with an exec-`cat`
  fallback), maps global px → this screen's 0..1 via the `Screen` attached props
  (multi-monitor safe), and feeds `uWin0..5` / `uActiveWin` / `uActiveVel` /
  `uActiveMove`. `aurora.frag` does a box-distance field per rect: outward flow
  displacement + edge glow, plus a velocity wake on the moving window (the cursor
  bloom is the template). All gated by `uWinReact` (the slider) — 0 ⇒ no work.

Geometry needs no special auth (unlike `ScreenShot2`, see below), so the bridge is
purely a geometry pipe — no window *content* is ever read.

## v2 roadmap — remaining

1. **Complement the active window's dominant colour** — on focus change, capture
   the active window via `org.kde.KWin.ScreenShot2` (`CaptureActiveWindow`),
   downsample, extract the dominant colour, derive a *complementary* 5-stop palette
   (rotate hue ~180°, spread tints/shades), and drive the wallpaper's custom palette
   (`Theme = Custom`, animate `Color0..4` to the new stops). Tradeoffs to settle
   before building:
   - **Privacy/perf**: this periodically screenshots the focused window's content.
     Trigger only on *focus change* (not continuously), debounce, and make it an
     explicit opt-in mode — never the default.
   - **Excludes**: skip capturing sensitive/own windows; let the user denylist apps.
   - **Colour math**: dominant via k-means/median-cut on a downscaled grab;
     complement vs. analogous harmony as a sub-option.
