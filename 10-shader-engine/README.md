# Layer 9½ / 10 — Nimbus Flux (GPU shader engine)

A **standalone Rust/[bevy](https://bevyengine.org) + wgpu** shader engine, separate
from the KDE desktop — the "wow ceiling" track of the pack's shader work. Where the
Layer 9 aurora wallpaper is a single-pass procedural `ShaderEffect` on the QtQuick
scene graph, this is a real **GPU compute-shader fluid simulation**: an Eulerian
stable-fluids (Jos Stam) Navier-Stokes solver running entirely on the GPU.

On an RTX 4090 it runs the full solver at the display refresh rate with the GPU
barely awake (>200 FPS uncapped at 1280×720).

## Install / run

```bash
bash 10-shader-engine/install.sh   # builds release + adds an app-menu launcher
bash 10-shader-engine/run.sh       # or just run it directly
bash 10-shader-engine/revert.sh    # removes the launcher (--purge also cargo-cleans)
```

| Input | Action |
|---|---|
| move / drag cursor | push the fluid + inject dye |
| `1` `2` `3` | style: **ink** · **mercury** · **water** |
| `D` | toggle light / dark |
| close window | quit |

First launch builds a release binary (a few minutes; bevy is large). Subsequent
launches are instant.

## How it works

`nimbus-flux/` is a Cargo crate (bevy 0.18, wgpu Vulkan backend).

- **`assets/shaders/fluid.wgsl`** — every solver pass as a compute entry point
  (`advect_vel`, `advect_dye`, `splat_vel`, `splat_dye`, `divergence`, `jacobi`,
  `gradient_subtract`, `copy`, `render`). All passes share **one** bind-group layout
  `(read, read, write, uniform)`; the CPU routes different physical textures through
  those slots per pass.
- **`src/fluid.rs`** — the bevy plugin: ping-pong storage textures (velocity, dye,
  pressure, divergence), pipeline setup, per-frame bind groups, and a render-graph
  node that dispatches the passes in order each frame:

  `advect velocity → add forces → divergence → 30× Jacobi pressure →
   subtract gradient → advect dye → inject dye → render`

  Velocity and dye persist across frames; pressure warm-starts. The cursor injects a
  force impulse + colored dye; two slow orbiting emitters keep it alive with no input.
- **`src/main.rs`** — window, plugin wiring, and a capture mode
  (`NIMBUS_FLUX_CAPTURE=1`) that saves a frame to `/tmp/nimbus-flux-frame.png` and
  logs FPS for headless verification.

## Styles

- **Ink** — colored dye glows over a deep Big Sur backdrop, Reinhard-tonemapped.
- **Mercury** — the dye height field is lit as flowing liquid chrome (Blinn-Phong +
  rim/Fresnel off the density gradient normal).
- **Water** — depth-tinted pools with specular sheen and caustic glints along the
  ripple crests.

## Scenes & wallpaper mode

Beyond the fluid sim, the engine hosts asset-driven 3-D scenes (select with
`NIMBUS_FLUX_SCENE`) and can render as a live **desktop wallpaper**
(`NIMBUS_FLUX_WALLPAPER=1`, via `bevy_live_wallpaper` on a wlr-layer-shell surface; stop
with `pkill -x nimbus-flux` — it can't be changed from System Settings while running):

| `NIMBUS_FLUX_SCENE` | What |
|---|---|
| *(unset)* | the GPU fluid sim above (window default) |
| `cyberpunk` | neon-city flythrough showpiece (`scene_cyberpunk.rs`) |
| `hexen` | gothic **Hexen/Heretic** dungeon (`scene_hexen.rs`) — Poly Haven CC0 stone + props, window-move camera reactivity, and **ray tracing (`bevy_solari`) + DLSS Ray Reconstruction** by default as a wallpaper. The default scene when `NIMBUS_FLUX_WALLPAPER=1`. **Full details + DLSS/autostart setup: [`hexen/README.md`](hexen/README.md).** |

`NIMBUS_FLUX_RT=0|1` overrides ray tracing (hexen only; on by default as a wallpaper).
`NIMBUS_FLUX_CAPTURE=1` saves a frame to `/tmp/nimbus-flux-frame.png` and logs FPS.

## Status / roadmap

- [x] Compute fluid solver, 60+ FPS, cursor-interactive
- [x] Ink / mercury / water styles, light/dark aware
- [x] Install/revert + app-menu launcher; wired into the top-level installer
- [x] Asset-driven 3-D scenes (cyberpunk city, hexen gothic dungeon)
- [x] Live desktop-wallpaper mode (`bevy_live_wallpaper`) + login autostart
- [x] Hardware ray tracing (`bevy_solari`) + DLSS Ray Reconstruction denoising (hexen)
- [ ] Shader-driven interactive UI overlay (controls as GPU surfaces)
- [ ] Self-contained binary (embed the shader to drop the BEVY_ASSET_ROOT step)

> The **integrated** version of the fluid lives in the desktop wallpaper itself —
> Layer 9's aurora "Liquid (fluid sim)" style — which also gains persistent
> cursor/music/window reactivity via a shared RGBA16F feedback buffer. This
> standalone engine is the max-power showpiece (real compute shaders + the
> mercury/water looks).
