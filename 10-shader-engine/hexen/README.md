# Nimbus Hexen — gothic dungeon wallpaper + theme (Layer 10)

A **2.5D gothic-dungeon** live wallpaper for the Nimbus pack, in the mood of Raven's
**Hexen / Heretic** — a torch-lit stone corridor rendered in real time by the Layer-10
**bevy/wgpu** engine (`nimbus-flux`), plus a matching **Nimbus-Hexen** Plasma colour
scheme (light + dark) and an aurora-palette tie-in.

It's a *modern-fidelity* homage, not a pixel filter: real 3-D masonry built
procedurally and clad in **Poly Haven CC0** PBR stone, gothic props dressing the hall,
warm flickering torches against a cool moonlit ambient, soft fog and HDR bloom, with a
slow camera glide down the nave toward a marble bust.

## Run it

```bash
# live desktop wallpaper (Wayland wlr-layer-shell; first run builds release, ~min).
# Ray tracing is ON BY DEFAULT here — see the RT note below.
NIMBUS_FLUX_WALLPAPER=1 bash 10-shader-engine/run.sh
# …or the cleaner, noise-free raster path as the wallpaper:
NIMBUS_FLUX_RT=0 NIMBUS_FLUX_WALLPAPER=1 bash 10-shader-engine/run.sh
# stop it:
pkill -x nimbus-flux

# or windowed (a normal window; raster by default — add NIMBUS_FLUX_RT=1 for RT):
NIMBUS_FLUX_SCENE=hexen bash 10-shader-engine/run.sh

# make it come back on every login (XDG autostart; reversible):
bash 10-shader-engine/hexen/apply.sh --autostart
```

Assets are **not committed** — fetch the ~59 MB of CC0 stone + props first (idempotent):

```bash
bash 10-shader-engine/fetch-hexen-assets.sh
```

## Theme (colour scheme + aurora tie-in)

```bash
bash 10-shader-engine/hexen/apply.sh            # install + activate Nimbus-Hexen (dark)
bash 10-shader-engine/hexen/apply.sh --light    # …the parchment light variant
bash 10-shader-engine/hexen/apply.sh --start    # …and fetch+build+launch the wallpaper now
bash 10-shader-engine/hexen/apply.sh --autostart # …and install a login autostart entry
bash 10-shader-engine/hexen/restore.sh          # revert scheme + aurora palette + autostart
bash 10-shader-engine/hexen/restore.sh --purge  # …also remove scheme files + assets
```

`apply.sh` backs up your current colour scheme and the live aurora palette to
`~/.local/state/nimbus/hexen/` and writes the gothic torch-amber ramp
(`#120d0a → #f2c879`) into the Layer-9 aurora config, so whichever background you use
matches. `--autostart` writes `~/.config/autostart/nimbus-hexen-wallpaper.desktop`
(→ `hexen/autostart-launch.sh`, which waits for the session then launches the wallpaper).
`restore.sh` puts the scheme + palette back and removes the autostart entry.

## How it's built

- **Scene:** `nimbus-flux/src/scene_hexen.rs` — selected by `NIMBUS_FLUX_SCENE=hexen`
  (the default when `NIMBUS_FLUX_WALLPAPER=1`). Procedural corridor (floor/ceiling/walls
  as tiled `Rectangle`s, columns/ribs/pedestal as `Cuboid`s), Poly Haven stone
  materials (`arm` map → bevy metallic-roughness + occlusion), glTF props, warm
  flickering `PointLight` torches + emissive flame spheres, and a cosine-eased dolly.
- **Modern lighting stack (all real-time):** shadow-casting torches + moonlight so the
  columns throw rhythmic shadows; **volumetric fog** (`FogVolume` + `VolumetricLight`)
  for the dusty torch shafts/god-rays; **SSAO** for contact occlusion in the masonry;
  a glossier (wet-flagstone) floor for torch glints; HDR camera with `Bloom` +
  `TonyMcMapface` tonemapping over a thin exponential `DistanceFog`. ~200 FPS on the 4090.
- **Window-move reactivity:** while a window is dragged, the camera leans in the
  direction it moved, then eases back — debounced and critically-damped-spring smoothed
  (`window_react.rs`, reading the Layer-9 `windows.json` bridge; run `windows-apply.sh`
  in `9-gpu-effects/interactive-bg/` to enable the feed). Direction/sign is unit-tested.
- **Ray tracing + DLSS — default for the wallpaper:** the live wallpaper uses bevy 0.18's
  experimental `bevy_solari` hardware ray-traced global illumination by default, denoised
  by **NVIDIA DLSS Ray Reconstruction** (DLAA / native-res). `NIMBUS_FLUX_RT=0` falls back
  to the raster path; windowed runs are raster unless `NIMBUS_FLUX_RT=1`. Solari is
  *layered on top* of the atmospheric scene (normal-mapped/parallax stone, volumetric
  god-rays, shadows all stay): it adds `SolariLighting` + a storage-bindable main texture
  to the camera and `RaytracingMesh3d` to every mesh (procedural immediately, glTF as it
  loads), and `add_dlss_denoiser` attaches Ray Reconstruction when the GPU supports it.
  Two gotchas it taught us, both handled in `scene_hexen.rs`:
    - Solari **replaces surface PBR lighting and ignores the flat `AmbientLight`** the
      raster path leans on, so the RT path drives the *real* interior emitters much
      brighter (torches ~900k, emissive flames doubling as Solari area lights, moonlight
      ~7000 lux) — the grazing torchlight is what makes the masonry relief pop.
    - Solari outputs **physical radiance**, so bevy's default daylight exposure
      (`Exposure` ev100 9.7) badly under-exposes a torch-lit interior — the RT camera uses
      an indoor `Exposure { ev100: 6.5 }`. *This, not light count, was the real fix for the
      "RT looks dark" problem.*
  Needs a ray-tracing GPU (the 4090 qualifies) + the DLSS SDK at build time (below). Note:
  on **NVIDIA + Wayland** the *windowed* path can panic on a swapchain-acquire timeout (a
  hardcoded bevy quirk, worse with Solari's heavy first frame); the live-wallpaper
  layer-shell path is unaffected.

  ```bash
  NIMBUS_FLUX_WALLPAPER=1 bash 10-shader-engine/run.sh                    # RT+DLSS wallpaper (default)
  NIMBUS_FLUX_RT=0 NIMBUS_FLUX_WALLPAPER=1 bash 10-shader-engine/run.sh   # raster wallpaper
  NIMBUS_FLUX_RT=1 NIMBUS_FLUX_SCENE=hexen bash 10-shader-engine/run.sh   # RT windowed
  ```

  **DLSS SDK setup (one-time, no sudo):** the denoiser links NVIDIA's DLSS SDK + needs
  Vulkan headers at build time. `run.sh` auto-detects both and builds `--features dlss`,
  staging the runtime `.so` next to the binary:
  ```bash
  bash 10-shader-engine/setup-dlss.sh   # clones the DLSS SDK + Vulkan headers (no sudo)
  ```
  Without the SDK everything still builds + runs (RT just un-denoised). If you ever
  redistribute, comply with the DLSS SDK `LICENSE.txt`.
- **Live wallpaper:** `bevy_live_wallpaper` renders the scene onto a wlr-layer-shell
  background surface (`NIMBUS_FLUX_WALLPAPER=1` → `WallpaperDisplayMode::Wallpaper`),
  with a `LiveWallpaperCamera` marker on the camera. It sits *below* the Plasma
  wallpaper and covers it, so you stop it with `pkill -x nimbus-flux` (it isn't
  changeable from System Settings).
- **Verify a frame headlessly:** `NIMBUS_FLUX_SCENE=hexen NIMBUS_FLUX_CAPTURE=1`
  renders to `/tmp/nimbus-flux-frame.png` and logs FPS, then exits.

## Assets (Poly Haven, CC0 / public domain)

Fetched by `fetch-hexen-assets.sh` from <https://polyhaven.com>:

- **Textures:** `castle_brick_07` (walls), `medieval_blocks_02` (floor),
  `castle_wall_slates` (ceiling / columns).
- **Models:** `marble_bust_01`, `Barrel_01`, `brass_candleholders`, `Lantern_01`.

All are CC0 — no attribution required, credited here as a courtesy. Poly Haven is
supported by its patrons.
