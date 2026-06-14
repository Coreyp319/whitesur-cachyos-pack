# Dreaming phase — design & build handoff

**Task:** build the **"dreaming" wallpaper** — a nightly **local-AI** reflection (one of the Layer-6
models — see "Model choice" below) that **composes a new 3-D scene** appended to the Layer-10 bevy
wallpaper, so the desktop becomes an **endless, evolving journey** you wake into each morning: a
replay-as-architecture of the previous day. This doc is for digging into the *design* and standing
up the *MVP*.

## ⚠️ Read first
- **`10-shader-engine/SCENE-COMPOSITION.md`** — the canonical scene-composing conventions
  (coordinate system, placement rules, the material/parallax recipe + gotchas, lighting recipe,
  the two render paths, the capture-verify loop) **and** the decided dreaming architecture +
  manifest-schema sketch + guardrails. Everything below assumes it.
- Memory: `dreaming-phase-wallpaper` (this project), `ui-audit-toolkit` (the guardrail pattern to
  copy), `local-ai-layer` (Hermes/Ollama + the reasoning-token gotcha), `bevy-wallpaper-mode`,
  `hexen-gothic-wallpaper`, `no-untrusted-third-party-services`.

## The model in brief (already decided — don't re-litigate)
- **Representation:** the model emits a **JSON scene manifest** (not code). A generic, compiled bevy
  **composer scene** renders it at runtime. Hot-loadable; no compiling AI output.
- **Content:** **hybrid** — real day signals (apps/windows, git, music, time) seed a skeleton;
  the model dresses it into a symbolic scene.
- **Transition:** an **endless evolving procession**. `journey/leg-NNN.json`, append-only;
  `leg-000` = the hand-authored seed (port of the hexen corridor). Each leg **continues from the
  previous leg's exit**, is **related to** it (inherits palette/motif/material) but **progresses**
  (mutates + pushes onward), "leading somewhere indefinite." The camera travels forward forever.
- **Autonomy:** staged + guardrailed, auto-applied, **revertible**, ledgered. CC0/procedural assets
  **only** (catalog allowlist); bounds-clamped; schema-validated before accept.

## Open design problems to dig into (ranked — this is the real work)
**A. Portal / handoff contract (highest technical risk — solve first).** Define how legs align so
the join is seamless. Proposed: author every leg in its **own local frame** with the **entry portal
at the origin facing +Z**; the composer computes each leg's world transform by chaining
`world(N) = world(N-1) · exit_local(N-1) · entry_local(N)⁻¹`. A portal is a `(transform, aperture
w×h)`; validate that consecutive apertures match within tolerance. Get two hand-authored legs to
join invisibly *before* any AI is involved.

**B. Procedural geometry vocabulary.** The manifest references geometry `kind`s — design the actual
parameterised primitives the composer can build (like hexen's `rect`/`block`): `corridor`,
`room`, `stair`, `bridge`, `archway/junction`, `cavern`. Each must expose a standard entry+exit
portal so any two can connect. This is the "Lego set" the model arranges.

**C. Leg streaming / windowing.** Keep only ~2–3 legs live; **preload** leg N+1 before the camera
reaches the handoff (glTF/texture latency is real — see hexen), **despawn** legs left behind. Trigger
on the camera crossing a per-leg threshold. Bounded GPU cost no matter how long the journey grows.

**D. Camera / playback policy — RESOLVED 2026-06-14 (user).** *Wake at the frontier* + *daily recap*:
each session spawns ≈ one leg *behind* the newest leg and slow-dollies **forward** through last
night's leg (live window `{N-1, N}`); at `leg[N].exit` it eases out to a slow hover (never loops/
reverses — the procession only goes forward); on the **first wake of the day** it plays a brief
fast-travel recap through the last ~3 legs then settles. Full spec (state file, env knobs,
deterministic `NIMBUS_FLUX_JOURNEY_CAM`/`_LEG`, reduced-motion) in **SCENE-COMPOSITION.md →
"Camera / playback policy"**. This is what step 3 below builds.

**E. Evolution model ("related but progressing").** Define what a leg **inherits** from `seed_from`
(palette, material set, motif, scale trend) vs. **mutates** (seeded by the day digest + the model).
Make "progress" legible — e.g. slow palette drift, a recurring motif that transforms, architecture
that opens up or tightens. Avoid both "identical every night" and "jarring non-sequitur."

**F. Day-signal collector.** Decide the signals + collection (privacy-aware, local-only). Reuse the
existing **`$XDG_RUNTIME_DIR/nimbus-aurora/windows.json`** bridge pattern (KWin→file; read by
`window_react.rs`) and the audio bridge. Candidates: active apps/windows + dwell, git commits across
known repos, music played (playerctl/audio bridge), active hours, time-of-day. Emit a compact
**day-digest JSON** for the model. Don't over-collect.

**G. Local-model JSON discipline + grounding (copy `6-local-ai/ui-audit/`).** Whichever model drives
it must emit STRICT schema-valid JSON referencing **only catalog ids** (no confabulated assets — the
ui-audit toolkit exists precisely because local models confabulate). Talk to Ollama's
**OpenAI-compatible `/v1`** endpoint with the **model name configurable** (don't hardcode one).
Reuse ui-audit's collector→ops→guardrail-applier→ledger shape. Gotchas: Hermes-4 returns **empty
content on small `max_tokens`** (reasoning tokens — see `local-ai-layer`); the `/v1` endpoint ignores
runtime `num_ctx` so use the **`-64k` baked variants**; validate+retry on schema miss; deny
load-bearing keys.

**H. Catalog + validator + ledger + revert.** A catalog file (asset id → category, bbox,
base-origin?, license) that the fetcher pulls from and the validator checks manifests against.
Ledger every applied leg with provenance; `revert` drops the last N legs. Composer must be robust to
a missing/invalid leg (skip + log, **never crash the wallpaper**).

**I. `leg-000` bootstrap (great forcing-function).** Port the current hexen corridor into a
`leg-000.json`. This proves the schema is expressive enough for a real scene and gives the journey a
seed. Decide what the manifest captures vs. what the composer supplies as defaults (flicker,
volumetric god-rays, window reactivity are probably composer features, not per-manifest data).

**J. Cross-leg continuity.** Interpolate lighting/fog/palette across the handoff so there's no hard
seam even when leg N+1's theme differs — fade atmosphere over the transition zone.

## MVP build order (each step independently verifiable)
1. **`src/scene_journey.rs` + manifest loader** — new bevy plugin, selected by
   `NIMBUS_FLUX_SCENE=journey` (register in `main.rs`). Renders one hand-authored `leg-000.json`
   (geometry kinds + props + lights from the schema). *Accept:* windowed capture matches a
   hand-built scene; zero AI involved.
2. **Portal handoff + two legs** — add `leg-001.json`, implement the entry/exit chaining (problem A),
   prove the join is invisible. *Accept:* capture at the seam shows no discontinuity.
3. **Endless camera + leg streaming** (problems C, D) — forward dolly across N legs, preload/despawn
   windowing. *Accept:* runs indefinitely with bounded entity/VRAM count.
4. **Catalog + validator + ledger** (problem H) — pure data, unit-testable offline, no engine. Feed
   it a bad manifest → it's rejected/clamped, logged, never reaches the composer.
5. **Model composer** (problems E, F, G) — day-digest collector → model prompt → manifest →
   validated through (4). Mirror `6-local-ai/ui-audit/`; model name configurable.
6. **Nightly timer** — Layer-6 systemd timer stages the new leg + exposes a one-command revert.

## Constraints & gotchas
- **Assets: CC0 (Poly Haven/ambientCG) or procedural only. No AI-gen meshes** (standing rule).
  The composer arranges a **vetted catalog**; it never fetches an unknown/untrusted asset.
- **Reversible + guardrailed by default** — a nightly autonomous change to the live desktop MUST be
  ledgered and trivially revertible. Model on `6-local-ai/ui-audit/`.
- **Verify with a WINDOWED capture, never the live wallpaper** (layer-shell surface can't be
  screenshotted): `cd nimbus-flux && BEVY_ASSET_ROOT="$PWD" NIMBUS_FLUX_CAPTURE=1
  NIMBUS_FLUX_SCENE=journey timeout 30 ./target/debug/nimbus-flux` → `/tmp/nimbus-flux-frame.png`.
  Park the camera deterministically with `NIMBUS_FLUX_HEXEN_CAM="x,y,z,lx,ly,lz"` (the journey scene
  should honour an equivalent debug-cam env). Add `NIMBUS_FLUX_RT=1` to preview the Solari path.
- **Launcher runs whichever of `target/{release,debug}` is NEWEST** — rebuild before judging; final
  `--release` build for the live wallpaper.
- **`scene_hexen.rs` is co-edited by a concurrent session (DLSS work)** — but `scene_journey.rs` is
  **new**, so build there to avoid collisions. Commit with explicit pathspecs.
- bevy **0.18.1** (features `wayland, jpeg, bevy_solari`); the two render paths (raster+SSAO /
  RT+Solari) both apply — see SCENE-COMPOSITION.md.

## Key files & prior art
- `10-shader-engine/SCENE-COMPOSITION.md` — conventions + decided design + schema sketch.
- `10-shader-engine/nimbus-flux/src/main.rs` — scene selector (`NIMBUS_FLUX_SCENE`), wallpaper/RT/
  capture wiring.
- `…/src/scene_hexen.rs` — the reference scene to port to `leg-000`; material/lighting recipes.
- `…/src/window_react.rs` + `…/src/scene_cyberpunk.rs` — the `windows.json` data-bridge pattern to
  copy for the day-signal collector.
- `…/fetch-hexen-assets.py` — the CC0 fetcher (extend into the catalog fetcher).
- **`6-local-ai/ui-audit/`** — the guardrailed local-model pipeline to mirror (collector → ops →
  guardrail applier → ledger); `6-local-ai/hermes-forge/` — related Hermes-driven authoring spike.
- `10-shader-engine/wallpaper-plugin/` — add a "Dream Journey" scene option here once it's real.

### Model choice (Layer 6 — all installed, all Agent-ready ≥64K ctx)
The composer should be **model-agnostic** (Ollama `/v1`, configurable name); evaluate these for
JSON-manifest quality + grounding, don't assume Hermes:
- `hermes4-14b` / `hermes4.3-36b` — Nous Research, agent/tool-use focused (the original intent).
- `gemma4-64k` (8B, fast, multimodal vision+audio) / `gemma4-26b-64k` (MoE, ~4B active, "smarter").
- `qwen3.6-27b-64k` — Alibaba, dense, vision+tools+thinking, very large native context.
(Created by `6-local-ai/install.sh` from the `Modelfile.*`; pin via `ollama-kv-cache.conf`.)

## First move
Don't start by coding the AI. Start with **steps 1–2** (composer + two hand-authored legs joining
seamlessly) — that de-risks the whole concept (problem A) and forces the schema to be real, all with
zero AI. Then resolve the **camera/playback policy (D)** with the user before building streaming.
