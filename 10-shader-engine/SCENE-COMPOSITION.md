# Scene composition notes (Nimbus Flux / Layer 10)

Living notes on **how a bevy wallpaper scene is composed** in this engine, so the work is
repeatable — by a human, by future-me, or by the **"dreaming" agent** (a Layer-6 local model — see
the last section). Grounded in the `hexen` scene (`src/scene_hexen.rs`); the conventions generalise.

> **Standing rule — assets are CC0 or procedural, never untrusted AI-gen.** Poly Haven /
> ambientCG (CC0), procedural meshes, or Blender-authored (the forge). No Hyper3D/Rodin/etc.
> (memory `no-untrusted-third-party-services`). A "dreamed" scene *arranges* a vetted catalog;
> it does not invent meshes from an untrusted generator.

## Coordinate system & the corridor template
- bevy is **Y-up, right-handed, metres**. glTF imports at real-world scale (load at `scale 1.0`).
- `hexen` is a hall along **−Z**: width `HALL_W=6` (x∈[−3,3]), height `HALL_H=5.2`,
  length `HALL_LEN=60` (z∈[−30,30]). Camera dollies z≈**25 → −17**, always looking at the
  far focal point `BUST_Z=−26`. So **low z = far/deep**, **high z = near the viewer**.
- Columns at x≈±2.7, torches at the bays (`COL_SPACING=7.5`), alternating sides.

## Placement rules (learned this session)
- **Hug the walls** (|x| ≳ 2) so props never block the central dolly path.
- **Scatter in z**; don't cluster everything at one depth or the rest reads empty.
- Most Poly Haven props are **base-origin** → spawn at `y=0` to sit on the floor (rocks can
  be centre-origin and half-embed, which is fine for rubble).
- **Focal object at the far end** (`z≈BUST_Z`), framed by a key light, scaled up so it still
  registers through the distance haze. The bust shrine + treasure chest is the template:
  the corridor *leads somewhere*.
- Verify orientation/scale of every prop — model "front" and pivot vary per asset.

## Materials — `stone_material()` recipe
- Poly Haven set `<id>_{diff,nor_gl,arm,disp}`. **sRGB only for base color**; normal/arm/disp
  load **linear** (`is_srgb=false`). Use the **`_nor_gl`** (OpenGL +Y) normal for bevy.
- `arm` packs AO=R, Rough=G, Metal=B → drives `metallic_roughness_texture` + `occlusion_texture`.
  `metallic=1.0` is safe because arm.B≈0 for stone keeps it dielectric.
- **Roughness reveals relief.** A fully matte surface hides both the normal and the parallax —
  lower `perceptual_roughness` (it *scales* arm.G) so grazing torchlight throws a specular that
  models the stone. Damp-dungeon look: walls ~0.7, floor ~0.45 (wettest), ceiling ~0.85.
- **Parallax = real grazing relief** via `depth_map` + `parallax_depth_scale`
  (`ParallaxMappingMethod::Relief { max_steps: 8 }`). Two gotchas, both cost-real:
  1. **Poly Haven ships a HEIGHT map; bevy's sampler reads DEPTH (inverted).** The fetcher bakes
     an inverted `_disp_` from the raw `_height_` (see `fetch-hexen-assets.py:do_displacement`),
     else mortar bulges and bricks sink.
  2. **`parallax_depth_scale` is relative to ONE TILE's world size**, not the surface. On big
     planes a tile is metres wide → keep scale ≈0.03–0.06. On **small/stretched-UV trim**
     (columns/ribs clad in a single stretched tile) any parallax smears horribly — **disable it
     there** (`depth=0` skips the depth_map entirely). This was the "funky beams" bug.

## Lighting & atmosphere recipe
- **Warm torches vs. cool key is the depth cue.** A single warm wash reads flat/monochrome.
  Warm flickering point lights (≈1.0,0.55,0.22) + a **cool moonlight** `DirectionalLight`
  (≈0.55,0.65,0.95) + a **dim cool `AmbientLight`** (low brightness so shadows stay deep and
  torches model form). Complementary contrast = perceived depth.
- **Fog is mood but washes detail** — keep it thin (`DistanceFog` Exp density ≈0.007;
  `FogVolume` density_factor ≈0.028). `VolumetricFog` + `VolumetricLight` give god-ray shafts.
- Camera: `Hdr` + `Tonemapping::TonyMcMapface` + `Bloom::NATURAL`; emissive (e.g. flames)
  blooms into glow. `Msaa::Off` (required by both SSAO and Solari).

## Two render paths (know which you're tuning)
- **Raster** (windowed default, or wallpaper with `NIMBUS_FLUX_RT=0`): adds **SSAO** for
  contact occlusion. Clean. *SSAO is currently disabled in wallpaper mode* — it panics under
  the layer-shell surface (view size not ready at prepare → 1×1 mip). Open lever.
- **RT / Solari** (wallpaper default): traced GI + soft shadows, **no SSAO needed**. Currently
  **grainy** without a denoiser — DLSS Ray Reconstruction is being wired (`--features dlss`).
- Material/parallax/prop changes apply to **both**; lighting balance differs per path.

## Verify loop (never trust "it compiled")
- **Windowed capture, not the live wallpaper** (a layer-shell surface behind your windows can't
  be screenshotted): `BEVY_ASSET_ROOT="$PWD" NIMBUS_FLUX_CAPTURE=1 NIMBUS_FLUX_SCENE=hexen
  timeout 30 ./target/debug/nimbus-flux` → reads `/tmp/nimbus-flux-frame.png` (snaps ~4s).
- **Deterministic framing:** `NIMBUS_FLUX_HEXEN_CAM="x,y,z,lx,ly,lz"` parks the camera (instead
  of dollying) so you can inspect a specific prop cluster. Add `NIMBUS_FLUX_RT=1` to preview the
  Solari path.
- The launcher runs **whichever of `target/{release,debug}` is NEWEST** — rebuild before judging,
  and do a final `--release` build so the live wallpaper picks up the optimized binary.

---

## Dreaming phase (planned — nightly local-model scene composer)
**Vision (user):** a nightly local-AI "dreaming" phase where a Layer-6 model reflects on the day and
**composes a new 3-D scene** appended to the bevy wallpaper, with a **seamless transition** from
the original scene into the "dreamed" one — the effect acting like a **replay of the previous
day's session**. Custom scenes accumulate over time.

### Decided architecture (2026-06-14)
- **Representation — JSON manifest → runtime composer.** A Layer-6 **local model** emits a **scene
  manifest** (a structured spec, *not* code). An already-compiled, generic bevy "composer" scene
  reads it and instantiates geometry/props/lights at runtime. No compiling AI output nightly;
  hot-loadable; the same data-bridge pattern as `windows.json` / `audio.json`.
- **Model — any of the Layer-6 locals, configurable (not just Hermes).** Installed & Agent-ready
  (≥64K ctx) via Ollama `/v1`: `hermes4-14b`, `hermes4.3-36b` (Nous, agent/tool-focused),
  `gemma4-64k` / `gemma4-26b-64k` (Google, multimodal + thinking), `qwen3.6-27b-64k` (Alibaba,
  dense, huge ctx). Pick per JSON/grounding quality.
- **Content — hybrid.** Each leg's character is seeded by **real signals from the day** (apps /
  windows used, git commits, music, time-of-day) as a skeleton, then **the model dresses it** into
  a symbolic scene. Grounded but expressive.
- **Transition — an endless evolving procession.** *Not* a fixed room or a discrete anthology.
  Each night's leg **continues from the previous leg's exit**, is **related to it** (inherits
  palette/motif/architecture) but **makes progress** — evolving and pushing the journey onward,
  "leading somewhere indefinite." The camera travels forward forever; the vanishing point always
  recedes. The base `hexen` corridor is `leg-000`, the hand-authored seed.
- **Autonomy — staged + guardrailed, auto-applied, revertible.** Generated nightly into a
  ledgered staging slot, auto-applied to the live wallpaper, trivially revertible, with an
  allowlist of what a manifest may reference (cf. `ui-audit-toolkit`).

### The journey model
- `journey/leg-NNN.json` — an ordered, append-only sequence. `leg-000` = the base corridor.
  Each dreaming night appends `leg-{N+1}`.
- Each leg is a self-contained segment with an **entry** (where the camera arrives from leg N−1)
  and an **exit** (hands off to leg N+1). `leg[N+1].entry` aligns to `leg[N].exit` → seamless
  spatial continuity, no teleport.
- The composer keeps only a **window** of legs live (stream the next as the camera nears the
  exit, unload legs left behind) so GPU cost stays bounded no matter how long the journey grows.
- "Related but progressing": a new leg **inherits** attributes from `seed_from` (its predecessor)
  and **mutates** them per the day's signals + the model's interpretation; it physically continues
  onward, never loops back.

### Camera / playback policy (resolved 2026-06-14 — *wake at the frontier* + *daily recap*)
Layout puts `leg-000` at the origin and each new leg *ahead* of the last, so **forward travel =
toward the newest leg**: the most recently dreamed leg is the **frontier** (its exit is the absolute
leading edge — nothing dreamed beyond it yet) and the deep past trails behind. Given that:
- **Start — wake at the frontier.** Each session the camera spawns `BACKOFF` (default ≈ one leg
  length) *behind* the newest leg's entry — i.e. back in `leg[N-1]` — and slow-dollies **forward**
  into and through `leg[N]` (last night's dream). You always live near the leading edge: the
  freshest days front-and-centre, the live streaming window naturally `{N-1, N}` (cf. problem C).
- **Frontier — ease-out to a hover, never loop.** As the camera nears `leg[N].exit` it
  **decelerates (ease-out)** to a slow hover at the threshold, looking out at the receding vanishing
  point ("somewhere indefinite"). It does **not** loop back or reverse — the procession only ever
  goes forward. Atmosphere/flicker/god-rays + the window-react nudge keep the hover alive. When
  tonight's `leg[N+1]` is composed & applied it appears ahead, extending the corridor; next session
  the frontier has moved one leg on. Pace the dolly **slow** (default ≈ one leg / 20–30 min
  wall-clock) so a normal session rarely reaches the hover.
- **Wake intro — daily recap, then settle.** On the **first wake of the day** (persisted
  `last_recap` date ≠ today) play a brief **fast-travel recap** forward through the last
  `RECAP_LEGS` legs (default 3) — a montage of recent days — then decelerate and settle into the
  normal slow-drift at the start position. Later unlocks the same day **skip the recap** and resume
  the slow-drift from saved progress. Recap ≈ 6–10 s, eased; it briefly widens the live window to
  `RECAP_LEGS+1` then despawns back to the 2–3 window once settled.
- **State** — persist `{ last_recap: "YYYY-MM-DD", progress }` under `$XDG_STATE_HOME/nimbus-flux/`
  (survives reboot within a day, unlike `$XDG_RUNTIME_DIR`). Key "first wake of the day" off this,
  not process start, so a mid-day reboot doesn't replay the recap.
- **Reduced motion** — honour a reduced-motion preference: skip the recap montage and freeze the
  dolly to a near-static parallax hover (cf. the design-ux accessibility ladder).
- **Deterministic framing (verify loop)** — `NIMBUS_FLUX_JOURNEY_CAM="x,y,z,lx,ly,lz"` parks the
  camera (the journey analogue of `NIMBUS_FLUX_HEXEN_CAM`), bypassing dolly + recap; pair with
  `NIMBUS_FLUX_JOURNEY_LEG=N` to spawn at a chosen leg to inspect a specific handoff under
  `NIMBUS_FLUX_CAPTURE=1`.
- **Knobs (env, sane defaults):** `NIMBUS_FLUX_JOURNEY_SPEED` (dolly units/s), `…_BACKOFF` (start
  distance behind the newest entry), `…_RECAP_LEGS` (default 3), `…_JOURNEY_CAM` / `…_JOURNEY_LEG`
  (deterministic). The camera also accepts the existing `windows.json` window-react nudge.

### Manifest schema (sketch — to harden during implementation)
```jsonc
{
  "id": "leg-001", "seed_from": "leg-000", "day": "2026-06-14",
  "theme":   { "palette": ["#.."], "motif": "flooded crypt", "mood": "focused" },
  "entry":   { "at": [x,y,z], "facing": [dx,dy,dz] },   // == prev.exit
  "exit":    { "at": [x,y,z], "facing": [dx,dy,dz] },    // hands to next
  "geometry":[ { "kind": "corridor|room|stair|bridge", "transform": {..}, "stone": "castle_brick_07" } ],
  "props":   [ { "model": "wooden_crate_01", "pos": [..], "rot_y": 0.4, "scale": 1.0 } ],
  "lights":  [ { "kind": "torch|key|moon", "pos": [..], "color": [..], "intensity": 160000 } ],
  "atmosphere": { "fog_density": 0.007, "ambient": [..], "bloom": "natural" },
  "provenance": { "from_signals": ["git: 7 commits", "music: 2h"], "model": "hermes4.3-36b", "model_notes": ".." }
}
```

### Guardrails (every manifest, before it goes live)
- **Catalog allowlist** — `model`/`stone` must be a known CC0 id (Poly Haven catalog + procedural
  kinds). Unknown → dropped + logged; never 404 at runtime, never fetch an untrusted asset.
- **Bounds clamp** — transforms/scales/intensities clamped to sane ranges (no 500 m prop, no
  runaway light); entry must align to the previous exit within tolerance.
- **Schema validation** before accept; **ledger** every applied leg with provenance; one-command
  revert drops the last N legs.

### Suggested build order (MVP-first)
1. **Composer scene** (`scene_journey.rs`) that renders a single hand-authored `leg-000.json`
   (port the current hexen corridor to the manifest) — proves the runtime path with zero AI.
2. **Endless camera + leg streaming** across entry/exit handoffs (start with two static legs).
3. **Catalog + validator + ledger** (the guardrail layer) — pure data, testable offline.
4. **Model composer**: day-signal collector → prompt → manifest, validated through (3)
   (model-agnostic over the Layer-6 locals; mirror `6-local-ai/ui-audit/`).
5. **Nightly scheduler** (Layer-6 systemd timer) staging the new leg + revert command.
