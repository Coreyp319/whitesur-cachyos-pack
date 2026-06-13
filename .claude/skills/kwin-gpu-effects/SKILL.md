---
name: kwin-gpu-effects
description: >-
  Work with KWin GPU shader effects on KDE Plasma 6 / Wayland (CachyOS / Arch):
  enable, disable, and tune the blur forks (Better Blur/forceblur, Glass) and
  kwin-effect-shaders; blur the dock/panels and menus; author and install custom
  GLSL shaders; diagnose no-blur / changes-do-nothing / stutter / build issues. Use
  whenever the user wants to change desktop blur, frosted glass, rounded corners,
  sharpening (CAS), color grading, or any GPU UI effect.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# KWin GPU effects

Procedures for driving the GPU shader effects in this pack (Layer 9,
`9-gpu-effects/`). The whole Plasma 6 UI is already GPU-composited (KWin via
OpenGL/EGL; shell via the QtQuick scene graph) — you are changing *which* shaders
run in that pipeline, not adding GPU rendering.

> **Authoring a *material look* (frosted/clear glass, acrylic, brushed metal, …)?**
> Read `reference/shader-materials.md` first. It explains the one thing that trips
> people up — a compositor has **no 3-D normals or lights**, so every "material" is a
> screen-space recipe over the backdrop (blur + tint + noise + edge-Fresnel +
> refraction) — and gives per-material GLSL plus how each blur-fork knob maps to a
> material primitive.

**Always Wayland.** X11 disables compositing for fullscreen apps and breaks these
effects. Confirm with `echo $XDG_SESSION_TYPE` (must be `wayland`).

## Always do this first: read current state

Run the bundled inspector before changing anything — it prints which blur/shader
effects are active (stock `blur` vs the forks `forceblur`/`glass`), whether they're
actually *loaded* in the compositor, and flags the only-one-may-run conflict:

```bash
bash .claude/skills/kwin-gpu-effects/scripts/effect-state.sh
```

### Applying changes live — pick the RIGHT call (this matters)

After editing `kwinrc` you must tell the *running* compositor to pick it up. Which
call depends on the effect:

- **Stock KWin effects** (`blur` and most built-ins) honour:
  ```bash
  qdbus6 org.kde.KWin /KWin reconfigure
  ```
- **Third-party effect forks** (`forceblur`, `glass`, `kwin_effect_shaders`) **ignore
  `/KWin reconfigure`** — it silently no-ops, so the change looks like it did nothing.
  Drive them through the `/Effects` interface instead:
  ```bash
  qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.reconfigureEffect glass   # re-read its settings
  qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect    glass     # turn OFF live
  qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect      glass     # turn ON  live
  qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.toggleEffect    glass     # flip (quick A/B)
  ```
  Confirm what is *actually* running — config saying `glassEnabled=true` does **not**
  prove the effect reloaded:
  ```bash
  qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadedEffects
  ```

If a blur/shader change "does nothing," 90% of the time it's this: `/KWin reconfigure`
was used on a forked effect. Use `reconfigureEffect <id>`.

## The three effects and their exact IDs (verified)

KWin effects are toggled in `kwinrc` under `[Plugins]` with the key `<id>Enabled`,
and configured under `[Effect-<id>]`. The IDs here are confirmed, not guessed:

| Effect | Plugin id | Enable key | Config group | Source |
|---|---|---|---|---|
| Stock blur (Layer 1) | `blur` | `blurEnabled` | `Effect-blur` | ships with KWin |
| Better Blur | `forceblur` | `forceblurEnabled` | `Effect-forceblur` | AUR `kwin-effects-forceblur` (archived) |
| **Glass** | `glass` | `glassEnabled` | `Effect-glass` | AUR `kwin-effects-glass-git` (maintained) |
| Desktop shaders | `kwin_effect_shaders` | `kwin_effect_shadersEnabled` | — | built from source (Layer 9) |

`blur`, `forceblur`, and `glass` are all forks of the **same** KWin blur effect.
**Critical conflict: only ONE may run at a time.** Enabling one *requires disabling
the others*, or blur breaks entirely. Always check the inspector for which fork is
active before tuning — writing settings to a disabled fork's `Effect-*` group
silently does nothing.

> **This machine currently runs Glass** (`glassEnabled=true`, stock `blur` off). Its
> dock/menu blur is gated by `[Effect-glass] BlurDocks` / `BlurMenus` (both default
> true); strength is `[Effect-glass] BlurStrength` (0–15). Apply Glass changes with
> `reconfigureEffect glass`, **never** `/KWin reconfigure`.

## Common tasks

### Switch between blur forks (stock ↔ Better Blur ↔ Glass)
Disable the current one, enable the new one, then load/unload through `/Effects`
(`/KWin reconfigure` will **not** load a fork):
```bash
# e.g. stock blur -> Glass
kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled  false
kwriteconfig6 --file kwinrc --group Plugins --key glassEnabled true
qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect blur
qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect   glass
```
Verify with `…Effects.loadedEffects` — exactly one blur fork should be listed. The
pack's `9-gpu-effects/revert.sh` reverses this and only restores stock blur if a fork
was actually active.

### Tune blur strength
`BlurStrength` (0–15) is honoured by **all** blur forks — but write it to the group
of the effect that is actually **active** (the inspector prints which one), and apply
with the matching call:
- stock blur active  → `Effect-blur`       → apply with `/KWin reconfigure`
- Better Blur active → `Effect-forceblur`  → apply with `reconfigureEffect forceblur`
- Glass active       → `Effect-glass`      → apply with `reconfigureEffect glass`

Writing it to the *inactive* fork's group silently does nothing.
```bash
# e.g. Glass is the active blur — dial it down and apply the RIGHT way:
kwriteconfig6 --file kwinrc --group Effect-glass --key BlurStrength 8
qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.reconfigureEffect glass
```
**15 is the maximum** (Layer 1's "heavy" default) — from there you can only go
*subtler*, not stronger. If the user wants "more blur" and it's already 15, that
needs Better Blur (more iterations) or Background Contrast, not a bigger number.
Better Blur has many more keys (rounded corners, brightness/contrast/saturation,
static-blur, per-window force-blur rules). **Do not guess key names** — they drift
across versions. To discover the real keys: set the option once in *System Settings
→ Desktop Effects → Better Blur (gear)*, then read them back:
```bash
kreadconfig6 --file kwinrc --group Effect-forceblur --key <Key>
# or dump the whole group:
awk '/^\[Effect-forceblur\]/{f=1;next}/^\[/{f=0}f' ~/.config/kwinrc
```

### Blur the dock / panels (Glass / Better Blur)
Panels — the WhiteSur dock included — are `Dock`-type windows. The forks blur them
via `BlurDocks` (menus via `BlurMenus`) in their config group, but **two conditions
must both hold**:
1. the fork's `BlurDocks=true` (Glass default), **and**
2. the **panel opacity is Translucent or Adaptive**, not Opaque — blur only shows
   *through* translucency. Panel opacity is `panelOpacity` in
   `~/.config/plasma-org.kde.plasma.desktop-appletsrc` on the dock's
   `[Containments][N]`: `0`=Adaptive, `1`=Opaque, `2`=Translucent. Find the dock by
   the containment holding `icontasks`/`org.kde.plasma.taskmanager`.
```bash
kwriteconfig6 --file kwinrc --group Effect-glass --key BlurDocks true
qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.reconfigureEffect glass
```
Reveal an auto-hide dock (mouse to its screen edge) to see it.

### Turn the desktop shader pass on
The `kwin_effect_shaders` plugin can be *enabled* yet show nothing — the visible
pass is gated behind a toggle shortcut (off by default, safe). To make it visible:
1. `kwriteconfig6 --file kwinrc --group Plugins --key kwin_effect_shadersEnabled true`
   then load it: `qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect kwin_effect_shaders`
2. Bind a key: *System Settings → Shortcuts → KWin → "Toggle Shaders"*, then press it.

### Pick / tune which shaders run
Shaders live in `~/.local/share/kwin-effect-shaders_shaders/`; the active set and
their parameters are controlled by `1_settings.glsl` in that dir. Good low-cost
defaults: **CAS** (contrast-adaptive sharpening) + **deband**. Heavy: FakeHDR,
adaptive-sharpen. Edit `1_settings.glsl`, then reconfigure.

### Author + install a custom GLSL shader (for kwin-effect-shaders)
This is the easy path for a one-off filter (vignette, tint, CRT, etc.). For a
*material* look (frosted/clear glass, acrylic, metal), work from
`reference/shader-materials.md` §3 (screen-space GLSL) and §5 (porting 3-D tutorials).
1. Drop a `.glsl` file into `~/.local/share/kwin-effect-shaders_shaders/` following
   the form of the existing shaders there (read one first — they expose a `main()`
   that reads `texture(...)` and writes the post-processed color).
2. Reference/enable it from `1_settings.glsl`.
3. Requires **GLSL 1.40+** (desktop GL) or **ES 3.0+**. `qdbus6 ... reconfigure`,
   then toggle the pass to see it.

### Author a custom KWin effect with QSB shaders (advanced)
For a *true* per-window or compositor effect (not a screen post-process), write a
KWin effect that loads `.qsb` shaders (Plasma 6's Qt6 shader format): author GLSL,
compile with the `qsb` tool, load via the effect's `ShaderManager`. This is real
C++/QML plugin work — scaffold from an existing effect (e.g. the KDE invert or
KDE-Rounded-Corners source) rather than from scratch. Reference:
https://discuss.kde.org/t/help-with-custom-qsb-shaders-in-kwin-plasma-6-wayland/39830

### Interactive aurora wallpaper (custom GLSL wallpaper plugin)
Layer 9 also ships a custom **Plasma 6 wallpaper plugin** `com.whitesur.aurora`
(`9-gpu-effects/interactive-bg/`) — an animated, cursor-reactive, light/dark-aware
GLSL aurora drawn by a `ShaderEffect` on the QtQuick scene graph (NOT a KWin effect).
This is the easiest path to a *full-screen custom shader background* without touching
KWin's private headers. Author `contents/shaders/aurora.frag` (Vulkan GLSL,
`#version 440`), compile with `/usr/lib/qt6/bin/qsb --qt6`, install/activate via
`interactive-bg/apply.sh` (revert: `restore.sh`). Plasma-6 wallpaper gotchas
(WallpaperItem root, no `Kirigami.Theme` scheme tracking → poll `kdeglobals`) and the
window-reactive design are written up in `interactive-bg/README.md` +
`WINDOW-REACTIVE-HANDOFF.md`.

## Troubleshooting

- **A change does nothing / "I can't see a difference"** → most common cause: you
  applied a *forked* effect (`forceblur`/`glass`/`kwin_effect_shaders`) with
  `/KWin reconfigure`, which they ignore. Re-apply with
  `…Effects.reconfigureEffect <id>` and verify with `…Effects.loadedEffects`. Second
  cause: you wrote settings to a *disabled* fork's `Effect-*` group. Third: nothing
  translucent on screen to blur — open a menu or reveal the dock, not an opaque window.
- **No blur at all** → more than one of `blur`/`forceblur`/`glass` enabled (conflict),
  or all disabled. Check with the inspector; ensure exactly one is `true`. A surface
  must have a **translucent** region for blur to show (force-blur/glass can bypass via
  per-window rules).
- **Better Blur installed but greyed out / missing** → AUR build is for the wrong
  KWin version. Upstream `kwin-effects-forceblur` is archived; install the
  maintained fork `kwin-effects-glass` instead.
- **Shaders effect won't build** → it compiles against KWin's *private* headers and
  breaks across KWin point releases. Ensure `extra-cmake-modules kwin cmake` are
  installed; if it still fails, it's a version mismatch — not fixable without an
  upstream patch. The desktop is unaffected by the failed build.
- **Stutter / cursor lag under heavy shader load** → set, in
  `~/.config/environment.d/kwin-gpu.conf` (then log out/in):
  - `KWIN_DRM_NO_AMS=1` — disable atomic modesetting
  - `KWIN_FORCE_SW_CURSOR=1` (or `0`) — toggle software cursor
- **Wrong GPU on a hybrid/dual-GPU box** → `MESA_VK_DEVICE_SELECT=vendorID:deviceID`
  or `DRI_PRIME=1` in the same `environment.d` file.
- **Effect won't turn off even after `…Enabled=false` + `/KWin reconfigure`** → forks
  don't unload on `/KWin reconfigure`; the running compositor keeps rendering it. Use
  `qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect <id>`, and confirm
  with `…Effects.loadedEffects`.

## Driver baseline (CachyOS)

Effects are only as smooth as the ICD: AMD `vulkan-radeon mesa` · Intel
`vulkan-intel` (Broadwell+) · NVIDIA proprietary `nvidia`. KWin's Vulkan backend is
still experimental as of 2026 — everything here is GLSL on the OpenGL/EGL backend.

## Live tweak vs lasting change — handle them differently

Decide which the user is actually asking for before you touch anything:

- **Ephemeral / "let me see it now"** (experimenting, tuning a value, trying a look):
  change **only live config** (`kwriteconfig6` + `qdbus6 … reconfigure`). Do **NOT**
  edit the pack's source scripts for a throwaway tweak — leave `1-base/` and
  `9-gpu-effects/` alone. Editing a tracked install script for a quick experiment is
  surprising and unwanted.
- **Lasting / "make this the default"**: this pack's principle is that every standing
  system tweak goes through an install/revert pair. Only then, mirror the change into
  the owning layer so it survives a reinstall and stays undoable —
  `9-gpu-effects/{install,revert}.sh` for the GPU effects, or
  `1-base/whitesur-cachyos-macos.sh` for the stock-blur default.

When it's ambiguous, treat it as **ephemeral** (live only) and tell the user the
one-line command to persist it if they want it to stick.
