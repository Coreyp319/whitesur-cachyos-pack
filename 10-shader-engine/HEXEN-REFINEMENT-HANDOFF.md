# Hexen scene — refinement handoff (continuing + autonomizing)

**Task:** keep refining the Layer-10 `hexen` gothic-dungeon bevy wallpaper toward *deep,
material-rich, atmospheric* — **and** set it up so a **Layer-6 local model can run the refinement
loop itself, on an ongoing basis**. This supersedes the original "it reads flat — add normal
maps / props" handoff: that diagnosis is **done** (normals/ARM/tangents/props all existed or were
added; the flatness causes — no parallax, matte stone, monochrome wash, bare foreground — are
fixed). What follows is the *next* lap plus the autonomy playbook.

> **✅ The "First move" below is DONE (2026-06-14) — see `HEXEN-TUNING-LOOP.md`.** The
> 3-knob spike (`wall_roughness`/`wall_depth`/`moonlight`) is externalized to
> `NIMBUS_FLUX_HEXEN_TUNING` JSON (`scene_hexen.rs::HexenTuning`, clamped on load, raster/
> shared only), with `hexen-tune.py` (clamp/stage/capture/accept/revert/**ledger**) +
> `hexen-vision-judge.py` (local `gemma4-64k`/`qwen3.6-27b-64k` verdict). Proven: no-compile
> data path (two JSON values, one binary → different renders) + one full vision-judged
> iteration (`moonlight 850→1150`, judged better @0.95, accepted+ledgered). **Next:** widen
> the knob set (add to `KNOBS` + `HexenTuning` together), wrap an autonomous driver around
> the four loop commands, and wire the launcher to export the env (the go-live step). The
> Rust externalization is on disk but **uncommitted** — `scene_hexen.rs` is the DLSS
> session's untracked file too; commit it together with their next sync.

## ⚠️ Read first
- **`10-shader-engine/SCENE-COMPOSITION.md`** — the canonical conventions (coords, placement,
  material/parallax recipe + gotchas, lighting recipe, two render paths, capture-verify loop).
- Memories: `hexen-gothic-wallpaper`, `verify-effect-not-command`, `deterministic-debugging`,
  `no-untrusted-third-party-services`, `ui-audit-toolkit`, `local-ai-layer`, `bevy-wallpaper-mode`,
  `dreaming-phase-wallpaper`.

## Status — done this session (2026-06-14), all verified via windowed raster capture
- **Parallax-occlusion relief** on walls/floor/ceiling via baked **inverted** depth maps
  (`fetch-hexen-assets.py:do_displacement` bakes `_disp_` from Poly Haven's `_height_`). Trim
  parallax **disabled** (it smeared on the stretched single-tile UV — the "funky beams" bug).
- **Lower stone roughness** so grazing torch speculars reveal the normal + parallax relief.
- **Warm-torch / cool-moonlight contrast + thinner fog** → broke the flat monochrome-orange wash.
- **Foreground/mid-hall props** distributed (crates, wine barrel, bucket, rubble, leaning shield).
- **Treasure chest → end of the hall** (focal reward at the bust shrine); **bust now faces the
  viewer** (was 180° backwards).
- Added `NIMBUS_FLUX_HEXEN_CAM="x,y,z,lx,ly,lz"` — a debug-cam park for deterministic captures.

## Still open — next refinement levers (ranked)
1. **Verify/fix the leaning shield** — `kite_shield` was placed *blind* (right wall, composite
   rotation `Quat::from_rotation_y(-FRAC_PI_2)*from_rotation_x(0.2)`). Confirm it leans naturally
   or adjust/remove.
2. **Composition & lighting polish** — floor reads uniform; the cool key barely penetrates the
   ceilinged interior (a 2nd cool accent or a grazing fill deeper in would help); the near entrance
   could use one tall vertical.
3. **Texel density** — 2k maps tiled large; bump UV repeat or fetch 4k for crisper brick.
4. **SSAO-in-wallpaper** — only the *raster* wallpaper (`NIMBUS_FLUX_RT=0`) lacks it; the **RT
   default has traced occlusion**, so this is lower-priority than the original handoff implied.
   Real fix = ensure the camera view size is ready when SSAO prepares under the layer-shell surface.
5. **More prop variety/placement** — `fetch-hexen-assets.py:MODELS` + the placement loop.

**Owned elsewhere — DO NOT touch:** the **RT/Solari graininess** is being solved by a concurrent
session wiring **DLSS Ray Reconstruction** (`--features dlss`; the `if rt {…}` lighting branches and
`Dlss*` imports/systems in `scene_hexen.rs`). They actively co-edit this file's **RT branches** — so
stay in the **raster (`else`) knobs**, re-read before every edit, commit with explicit pathspecs.

---

## ⭐ Making a local model do the refinement (the "ongoing basis" ask)
**The enabler:** two Layer-6 locals are **vision-capable** — `gemma4-64k` (8B, vision+audio) and
`qwen3.6-27b-64k` (vision). So a model can run the **exact see-and-adjust loop done by hand this
session**: change a knob → render → *look at the PNG* → judge → keep or revert. A text-only model
(Hermes) can still drive the *parameter search* but needs a vision model (or a human) for the
"look" step.

### Recommended architecture — externalize the knobs to `hexen-tuning.json`
Today every knob is hardcoded in `scene_hexen.rs`. A model editing Rust + rebuilding is fragile
(must emit valid Rust, builds fail, and it **collides with the concurrent DLSS session**). Instead:
- Add a `HexenTuning` struct the scene **deserializes from `hexen-tuning.json`** at `setup()`
  (path via env, e.g. `NIMBUS_FLUX_HEXEN_TUNING`; missing/invalid → today's hardcoded defaults).
  **Bounds-clamp every field on load** to the safe ranges below.
- The model edits **validated data, never code, never compiles** — mirrors the dreaming-phase
  manifest decision and the `6-local-ai/ui-audit/` guardrail pattern (collector → ops → guardrail
  applier → ledger). It's the *small sibling* of the dreaming composer; build it as a 2–3-knob spike
  first, then widen.
- **Ledger** every accepted change (before/after + the model's rationale + the capture path);
  one-command revert restores the last-good tuning. Keep the last-good PNG as the comparison baseline.

This removes the rebuild from the loop entirely (knobs are data, read at startup) — the model just
re-runs the capture with a new JSON.

### The refinement loop (one iteration the model executes)
1. Pick **ONE** goal from the rubric (e.g. "left wall still reads flat").
2. Pick **ONE** knob + a small in-range delta (table below).
3. Apply — edit `hexen-tuning.json` (post-externalization) **or**, pre-externalization, the named
   field in `scene_hexen.rs` then `cargo build`.
4. Capture: `cd nimbus-flux && BEVY_ASSET_ROOT="$PWD" NIMBUS_FLUX_CAPTURE=1 NIMBUS_FLUX_SCENE=hexen \
   [NIMBUS_FLUX_HEXEN_CAM="0,2.2,23,0,0.4,9"] timeout 30 ./target/debug/nimbus-flux`
   → `/tmp/nimbus-flux-frame.png` (snaps ~4 s). Park the cam for prop/area closeups.
5. **View the PNG**; score it against the *previous* capture (keep both).
6. Better → keep + ledger. Worse / no visible change → **revert**. Never batch knobs; never judge an
   un-rebuilt binary.

### Knobs + safe ranges (the tuning surface — current raster values)
| Knob | Where (`scene_hexen.rs`) | Now | Safe range | Visual effect |
|---|---|---|---|---|
| floor roughness / depth | `stone_material("medieval_blocks_02", …)` | 0.45 / 0.03 | 0.35–0.7 / 0–0.05 | wetter flagstone glint / floor relief |
| ceiling roughness / depth | `stone_material("castle_wall_slates", …)` (ceil) | 0.85 / 0.025 | 0.6–1.0 / 0–0.04 | ceiling sheen / relief |
| **wall** roughness / depth (hero) | `stone_material("castle_brick_07", …)` | 0.7 / 0.045 | 0.5–0.95 / 0–**0.06** | brick gloss + relief; **>0.06 depth smears** |
| trim roughness / depth | `stone_material("castle_wall_slates", …)` (trim) | 0.8 / **0.0** | 0.6–1.0 / **keep 0.0** | columns/ribs; parallax **smears** on stretched UV → leave 0 |
| torch intensity / range | `spawn_torch` raster `base` / `range` | 160 000 / 19 | 90k–240k / 14–22 | warm-pool brightness & spread (rhythm/contrast) |
| moonlight illuminance | `DirectionalLight` **`else` branch** | 850 | 400–1400 | cool key strength (warm/cool contrast) |
| ambient brightness | `AmbientLight.brightness` | 42 | 25–80 | global fill (lower = deeper shadows) |
| DistanceFog density | `FogFalloff::Exponential` | 0.007 | 0.004–0.012 | far-fade depth vs. detail wash |
| FogVolume density_factor | `FogVolume` | 0.028 | 0.015–0.05 | god-ray haze vs. curtaining |
| bust/candle/lantern key | those `PointLight.intensity` **raster** values | 120k/26k/30k | ±50% | focal pop at the shrine |
| prop transforms | the props loop + chest/bust spawns | — | x: \|x\|≳2 (hug walls); y=0 (base-origin); scale = metres | placement/scale |

**Hard rule:** the **`if rt {…}` branches are the DLSS session's** — never touch them; tune only the
raster (`else`/shared) values.

### Aesthetic rubric (what "better" means — spell it out; a model can't intuit it)
- **Depth/contrast** — warm pools against cool shadow, a real dark↔bright range; never one flat hue.
- **Material richness** — brick/stone relief visible (grazing speculars + parallax), not matte-flat.
- **Composition** — the hall *leads* to the focal shrine; foreground dressed, not bare; props hug walls.
- **Mood/legibility** — torch-lit gothic; fog atmospheric but not curtaining; far end melts to dark.
- **No artifacts** — no texture smear/swim (parallax), no floating/sunk props, no blown-out bloom.

### Guardrails (non-negotiable for autonomous runs)
- Clamp every knob to range; **one knob per iteration**; **always rebuild / reload before judging**.
- **Verify the EFFECT, not the command** — "exit 0 / it compiled" ≠ better (`verify-effect-not-command`).
- Revert on regression; **ledger** every accepted change; keep the last-good capture as baseline.
- **CC0 / procedural assets only** (`no-untrusted-third-party-services`).
- **Don't edit RT/DLSS code**; **don't** touch the live wallpaper to judge (capture windowed).
- Launcher runs the **newest of `target/{release,debug}`** — final `--release` build goes live.

## Learnings (the hard-won gotchas a fresh model MUST carry in)
- **`parallax_depth_scale` is relative to ONE TILE's world size** → on a stretched single-tile UV it
  smears hugely. Big planes ≤0.06; trim 0.
- **Poly Haven ships HEIGHT maps; bevy reads DEPTH (inverted)** → bake `_disp_` from `_height_`
  (else mortar bulges, bricks sink).
- **Roughness reveals relief** — a fully matte surface hides normal + parallax; lower it for grazing
  speculars.
- **Warm/cool complementary contrast = perceived depth** — a single warm wash reads flat.
- **Normal/ARM/disp load NON-sRGB** (`is_srgb=false`); only base color is sRGB; `_nor_gl` is the
  bevy-correct (OpenGL +Y) normal. **`jpeg` feature required** or .jpg maps silently fail → flat.
- **Two render paths:** raster (capture default, +SSAO) vs RT/Solari (wallpaper default, grainy until
  DLSS). Material/parallax/props apply to both; lighting balance differs — tune raster via capture.
- **Verify with a WINDOWED capture; the live wallpaper (layer-shell) can't be screenshotted.**
- **The launcher runs the NEWEST binary** — a stale build silently shadows fresh code (bit us twice).

## Key files
- `10-shader-engine/nimbus-flux/src/scene_hexen.rs` — scene, `stone_material`/`load_tex`, props,
  lighting, the SSAO wallpaper guard, the debug-cam env, the props loop. *(co-edited — RT branches
  are the DLSS session's.)*
- `10-shader-engine/fetch-hexen-assets.py` (+ `.sh`) — CC0 fetch (`TEXTURES`, `TEX_MAPS`,
  `do_displacement`, `MODELS`).
- `10-shader-engine/SCENE-COMPOSITION.md` — conventions + the dreaming-phase design.
- `10-shader-engine/nimbus-flux/assets/hexen/{textures,models}/` — fetched assets (gitignored).
- `6-local-ai/ui-audit/` — the guardrailed local-model pipeline to mirror for the tuning ledger.
- *(to create)* `hexen-tuning.json` + its ledger — the externalized knob surface.
- Run live: `~/.local/bin/nimbus-flux-wallpaper hexen`; stop: `pkill -x nimbus-flux`. Settings →
  Wallpaper → "Nimbus Flux (3D Engine)" → Scene: Hexen.

## First move
Externalize **2–3 knobs** (wall roughness/depth, moonlight illuminance) into `hexen-tuning.json` with
clamp + ledger, then have a vision model run **one** documented loop iteration end-to-end. Prove the
data-driven, no-compile, vision-judged loop works before widening to the full knob set.
