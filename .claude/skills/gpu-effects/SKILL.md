---
name: gpu-effects
description: >-
  Work with the pack's GPU shader effects on KDE Plasma 6 / Wayland (CachyOS / Arch):
  the blur forks (Better Blur/forceblur, Glass) and kwin-effect-shaders (enable/disable/
  tune, blur dock/panels/menus, author+install custom GLSL); the interactive
  `com.nimbus.aurora` wallpaper and its styles (incl. the multi-pass "Liquid" GPU fluid
  via RGBA16F ShaderEffectSource feedback) and cursor/music/window reactivity; and the
  standalone Layer-10 bevy/wgpu fluid engine (nimbus-flux). Diagnose no-blur /
  changes-do-nothing / stutter / build issues. Also carries expert design/UI/UX
  judgment (`reference/design-ux.md`): Apple HIG deference/clarity/depth, the
  materials & vibrancy ladder, legible glassmorphism (WCAG contrast, scrim, blur),
  depth/hierarchy, motion timing & easing tables, accessibility (reduced
  transparency/motion), and when an effect serves the UI vs. is vanity. Also carries the
  **Blender hero-asset pipeline** (`reference/blender-pipeline.md`): authoring 3-D assets
  (the neon "core" + any new mesh) in flatpak Blender 5.1 driven by the `blender` MCP
  server (bpy over your lane, default `:9876`), for the aurora turntable sprite (EEVEE) and the Layer-10
  bevy glTF — bpy automation, modeling/scene hygiene, PBR/emission materials, lighting &
  transparent turntable rendering, and the glTF→bevy 0.18 export contract. Use whenever
  the user wants to change desktop blur, frosted glass, rounded corners, sharpening
  (CAS), color grading, the animated/reactive wallpaper, a GPU fluid sim, any GPU
  UI/shader effect, or to **author/edit a Blender 3-D asset or its render/export** — or
  wants design/UX guidance on how an effect should look or feel.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# GPU effects

Procedures for driving the GPU shader effects in this pack (Layer 9,
`9-gpu-effects/`). The whole Plasma 6 UI is already GPU-composited (KWin via
OpenGL/EGL; shell via the QtQuick scene graph) — you are changing *which* shaders
run in that pipeline, not adding GPU rendering.

> **Making an *aesthetic* decision — add/tune/remove an effect, "make it look more
> like Big Sur," how much blur/glow/motion is right?** Read `reference/design-ux.md`
> first. It's the expert design/UI/UX judgment for this pack: Apple's
> deference/clarity/depth lens, the materials & vibrancy ladder, glassmorphism that
> stays legible (contrast ≥4.5:1, scrim, blur-more-on-busy-bg), depth/hierarchy,
> motion timing/easing tables (with the latency ceilings the aurora reactivity must
> hit), accessibility (reduced-transparency/motion), and a pre-deploy design-review
> checklist. **The meta-rule: effects serve the content — know when to stop.**

> **Authoring a *material look* (frosted/clear glass, acrylic, brushed metal, …)?**
> Read `reference/shader-materials.md` first. It explains the one thing that trips
> people up — a compositor has **no 3-D normals or lights**, so every "material" is a
> screen-space recipe over the backdrop (blur + tint + noise + edge-Fresnel +
> refraction) — and gives per-material GLSL plus how each blur-fork knob maps to a
> material primitive. (`design-ux.md` says *how far* to push those knobs; this says
> *how to build* them.)

> **Authoring a 3-D *hero asset* in Blender (the neon "core", or any new mesh for the
> aurora sprite / Layer-10 bevy engine)?** Read `reference/blender-pipeline.md` first.
> The pack drives **flatpak Blender 5.1 via the `blender` MCP server** (Python over the
> lane socket `localhost:${NIMBUS_BLENDER_PORT:-9876}` — you send `bpy` code, you can't see the
> viewport; start the lane with `blender-mcp.sh up`), feeding two paths:
> a **turntable PNG sprite sheet** (EEVEE → wallpaper) and a **glTF/GLB** (→ bevy 0.18).
> The doc's §0 is the operating reality + live-verified facts about this exact build
> (e.g. it's **EEVEE-only — no Cycles**, so in-Blender baking is unavailable;
> `scene.node_tree` is gone; EEVEE "Bloom" is gone → use the Compositor Glare node),
> then bpy automation, modeling/scene hygiene, materials, lighting/render/turntable, and
> the glTF→bevy export contract (the 0.18 coordinate gotcha, what survives export, emissive→bloom).

**Always Wayland.** X11 disables compositing for fullscreen apps and breaks these
effects. Confirm with `echo $XDG_SESSION_TYPE` (must be `wayland`).

## Always do this first: read current state

Run the bundled inspector before changing anything — it prints which blur/shader
effects are active (stock `blur` vs the forks `forceblur`/`glass`), whether they're
actually *loaded* in the compositor, and flags the only-one-may-run conflict:

```bash
bash .claude/skills/gpu-effects/scripts/effect-state.sh
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

> **This machine currently runs stock `blur`** (`blurEnabled=true`, `BlurStrength=15`;
> Glass/forceblur off — verified via `scripts/effect-state.sh`). Stock blur honours
> `/KWin reconfigure`. The Glass fork *is installed* (`kwin-effects-glass-git`) and can
> be switched in (see "Switch between blur forks" below) — its dock/menu blur is gated
> by `[Effect-glass] BlurDocks` / `BlurMenus`, strength `[Effect-glass] BlurStrength`,
> applied with `reconfigureEffect glass` (**never** `/KWin reconfigure`). Always run the
> inspector first — the active fork can change.

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
Layer 9 also ships a custom **Plasma 6 wallpaper plugin** `com.nimbus.aurora`
(`9-gpu-effects/interactive-bg/`) — an animated, cursor/window/music-reactive,
light/dark-aware GLSL background on the QtQuick scene graph (NOT a KWin effect). The
easiest path to a *full-screen custom shader background* without KWin's private headers.
Author `contents/shaders/*.frag` (Vulkan GLSL `#version 440`), compile with
`/usr/lib/qt6/bin/qsb --qt6`, install/activate via `interactive-bg/apply.sh` (compiles
**all** `*.frag`; revert with `restore.sh`). Plasma-6 wallpaper gotchas (WallpaperItem
root, no `Kirigami.Theme` scheme tracking → poll `kdeglobals`) are in
`interactive-bg/README.md`.

**Styles** (config `Style` 0–8): 0–7 are single-pass procedural looks in `aurora.frag`
(Flow/Hills/Silk/Caustics/Ink + three raymarched 3-D scenes: **Laserwave** = a neon grid
on an INTERACTIVE reflective water surface — cursor/music/ambient ripples + a mirrored
sun; **Vaporwave** = "Elysium", an endless pastel-marble COLONNADE receding to the
Floral-Shoppe sun with a glossy checkered floor + iridescent focal sphere; **Cyberpunk** =
"Datascape", a Tron neon DATA-GRID flythrough with headlight/taillight TRAFFIC traces +
neon-haze atmosphere); **8 "Liquid"** is a real **multi-pass GPU fluid** (Eulerian
stable-fluids) rendered by `FluidLayer.qml` + `fluid_{velocity,pressure,dye,display}.frag`,
swapped in via a `Loader` when selected.

**Bloom + hero compositing (main.qml):** the whole aurora scene + a Blender-authored
**hero sprite** (`contents/assets/hero_core.png`, a 16-frame turntable shown on the neon
styles 5/7) are wrapped in `sceneRoot`, captured to a `ShaderEffectSource` (`reactBuf`
pattern), and drawn through a single-pass **bloom** composite (`bloom.frag`: 32-tap
golden-angle bright-pass glow; lighter in light mode; bypassed on Liquid). The SAME hero
is exported as glTF (`hero_core.glb`) and rendered live in 3-D (HDR + bevy `Bloom`) by the
Layer-10 engine. Author/re-render the hero (and any new mesh) via the `blender` MCP server
(`uvx blender-mcp`; needs Blender open on your lane — start it with
`.claude/skills/gpu-effects/blender-mcp.sh up`) — the full
authoring pipeline (bpy automation, modeling, materials, turntable render, glTF→bevy
export) is in **`reference/blender-pipeline.md`**.

**Multi-pass float feedback in pure QML (the key technique):** `ShaderEffectSource`
exposes `format: ShaderEffectSource.RGBA16F` (and `RGBA32F`) + `recursive: true` +
`live: true` → ping-pong **float** feedback buffers, enough precision for real
simulations (velocity/pressure/dye). 8-bit (default RGBA8) bands/drifts and is useless
for this. This powers (a) the Liquid fluid and (b) a **shared reactive feedback buffer**
`react.frag` → `reactBuf` that accumulates persistent cursor trails, music beat-ripples
and window wakes, decaying/diffusing each frame; `aurora.frag` samples it (`reactTex`)
for glow + flow-displacement, so EVERY style reacts with lingering motion, not just an
instantaneous response. Reactivity data comes from two `systemd --user` bridges:
`nimbus-aurora-bridge` (windows → `windows.json`) and `nimbus-aurora-audio`
(pw-cat→FFT → `audio.json`); enable music with `interactive-bg/audio-apply.sh`.

Switch style live (config change needs a plugin *bounce*, not a same-id no-op):
```bash
qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript '
  var d=desktops()[0]; d.currentConfigGroup=["Wallpaper","com.nimbus.aurora","General"];
  d.writeConfig("Style", 8);'                                  # 8 = Liquid
# then bounce so the running plugin re-reads config:
qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript 'desktops()[0].wallpaperPlugin="org.kde.image"'
qdbus6 org.kde.plasmashell /PlasmaShell evaluateScript 'desktops()[0].wallpaperPlugin="com.nimbus.aurora"'
```
Verify QML *rendering* (not just load) headlessly with `item.grabToImage(...saveToFile)`
in a tiny `qml -I <dir> harness.qml` — qmllint/`QQmlComponent.create` check construction,
not whether the feedback actually renders.

### Standalone GPU engine — Layer 10 (`10-shader-engine/`)
The max-power *showpiece* track: a standalone **Rust / bevy 0.18 / wgpu** app
(`nimbus-flux`). Originally a compute-shader Eulerian fluid (ink/mercury/water), it now
also hosts **asset-driven 3-D scenes** and can run **as the live desktop wallpaper**.
Build+run with `bash 10-shader-engine/run.sh`; install (release build + app-menu launcher)
/revert with `10-shader-engine/{install,revert}.sh`. Env selectors:
- `NIMBUS_FLUX_SCENE=cyberpunk|hexen` — pick a 3-D scene (else the fluid sim).
- `NIMBUS_FLUX_WALLPAPER=1` — render onto a wlr-layer-shell **desktop wallpaper** surface
  (`bevy_live_wallpaper`); covers the Plasma wallpaper + icons, stop with `pkill -x nimbus-flux`.
  Defaults to the `hexen` scene.
- `NIMBUS_FLUX_RT=0|1` — bevy_solari **hardware ray tracing** (hexen only; **on by default
  as a wallpaper**), denoised by **DLSS Ray Reconstruction** when the DLSS SDK is built in.
- `NIMBUS_FLUX_CAPTURE=1` — headless-verify a frame (`/tmp/nimbus-flux-frame.png` + FPS).

The **hexen** scene is the gothic Hexen/Heretic dungeon wallpaper (Poly Haven CC0 stone +
props, window-move camera reactivity, RT+DLSS, login autostart) — its own docs +
DLSS/Solari gotchas (Solari ignores `AmbientLight`; physical radiance needs an indoor
`Exposure`; NVIDIA+Wayland windowed swapchain-timeout panic) live in
`10-shader-engine/hexen/README.md`. Use this engine when you want compute/particle sims or
real-time RT that exceed QtQuick ShaderEffect; use the wallpaper "Liquid" style above for
the integrated desktop fluid. Asset note: a bare binary looks for `assets/` next to itself —
`run.sh` sets `BEVY_ASSET_ROOT`. Blender-authored hero mesh export contract (bevy 0.18
coordinate gotcha, emissive→bloom) is in `reference/blender-pipeline.md`.

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
  `1-base/nimbus-cachyos-macos.sh` for the stock-blur default.

When it's ambiguous, treat it as **ephemeral** (live only) and tell the user the
one-line command to persist it if they want it to stick.
