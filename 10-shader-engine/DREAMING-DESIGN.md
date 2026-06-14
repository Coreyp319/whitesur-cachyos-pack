# Dreaming phase — consolidated design + reconciliation (research pass, 2026-06-14)

Read first: `SCENE-COMPOSITION.md` (canonical conventions + decided architecture) and
`DREAMING-PHASE-HANDOFF.md` (open-problems map A–J). This doc records the research pass's
decisions, **reconciles a duplicate-build collision**, and carries the design for the one piece
that is still **unbuilt**: the WFC geometry subsystem.

## Reality check (who built what)
A concurrent session built **all of subsystem B** at **`10-shader-engine/dream/`** — and it is the
**canonical** implementation:
- `catalog.json`, `collect_digest.py` + `signals/` (collector + systemd sampler)
- `dreamlib.py` (`validate_leg`) + `dream.py` (validate/accept/revert, dry-run, ledger) — guardrail
- `compose.py` — the **model composer** (step 5), offline-testable via an injected `call_fn`,
  `<think>`-stripping, `assemble()` force-fixes seam geometry, validate→retry loop
- `test_dream.py` / `test_compose.py` (23/23 each). Hand-authored `leg-000..003` chain.

A **second** session (this one) independently built a parallel subsystem B at `12-dreaming/` before
discovering the above — a duplicate. **`dream/` wins; `12-dreaming/` is kept only as a reference for
three improvements to port (below), then retired.** Engine geometry is still **`corridor`-only** —
so **subsystem A (WFC) is the real remaining new work.**

## Decisions made this pass (with the user)
- **Camera / playback (D) — RESOLVED & implemented** by the concurrent session (wake-at-frontier +
  daily recap + state file). Spec: `SCENE-COMPOSITION.md → "Camera / playback policy"`.
- **Geometry vocabulary (B) — WFC** (`bevy_ghx_proc_gen`), **WFC-within-a-leg**. Unbuilt → §A below.
- **Model control (E+G) — semantic knobs + deterministic drift** was the choice *here*; the built
  `dream/compose.py` uses **fuller-manifest + harness-forced geometry** (`assemble()`), which
  mitigates the main risk. A soft divergence, not a safety gap — left as the canonical behaviour.
- **Day-signals (F) — all four:** git, music, apps, time.
- **Assets — CC0/procedural only; no AI-gen meshes.** Offline. Revertible/guardrailed.

## A. WFC geometry subsystem (UNBUILT — the real remaining work)
WFC fills each leg's *interior*; the macro portal-chaining between legs is untouched.
- **Crate:** `bevy_ghx_proc_gen = "0.8.0"` — **verified bevy-0.18 native**, supports **3D grids**
  (`new_cartesian_3d`), **boundary pinning** (`with_initial_grid` / `with_initial_nodes` → pin the
  entry/exit z-layers to portal tiles so the solver *must* grow a connected passage between them),
  and **`RngMode::Seeded(u64)`** (replayable per date). Escape hatch: roll-our-own AC-4 over the
  small (~48–192-cell) grid. (`ghx_proc_gen` pins `rand 0.8.5`; coexists with the tree's 0.9 — drive
  determinism through `RngMode::Seeded`, not a shared `rand`.)
- **3D tile vocabulary** (each mesh **parametric** via `rect`/`block`, or CC0): floor/ceiling/wall/
  corner/arch/pillar/stair/junction/cavern/solid(zero-entity)/`portal_cap`(pinned boundary archway).
  Typed sockets (`PASSAGE` only meets `PASSAGE`/`PORTAL`) guarantee walkable + connected +
  portal-terminating output. The entry `portal_cap` *is* the archway → exactly one arch per seam.
- **Knobs → WFC:** mood→tile-weight profile + fog; palette→material set + torch drift;
  motif→enabled tile subset; density→decorative weight; seed→`RngMode::Seeded`; seed-offset-by-leg +
  bounded weight drift from the prev leg = "related but progressing."
- **Integration — 4 small *additive* hooks (no rewrites), in a NEW sibling `src/wfc_leg.rs`:** a
  `Wfc` variant on `Geometry`; one match arm in `build_leg`; `mod wfc_leg;` in `main.rs`; promote
  `rect`/`block`/`stone_material`/`load_tex`/`place`/`spawn_torch`/`rgb` to `pub(crate)`. `corridor`
  stays as the always-available fallback. RT/Solari + camera spine + streaming need **zero** new work
  (`register_raytracing_meshes` + `LegMember(idx)` tagging pick WFC meshes up automatically).
- **De-risk gate:** prove one `wfc` leg joins a `corridor` leg seamlessly via a parked windowed
  capture **before** any model work. Solve once-at-spawn, single-digit ms; cap cells/leg ≤ 256.

> ⚠️ **Concurrency:** the 4 hooks touch `scene_journey.rs`/`main.rs`/`Cargo.toml`, **actively
> edited** by the streaming session (and the engine binary is running). `wfc_leg.rs` is a new file
> (safe to draft), but the hooks must land in a **coordinated commit** — never clobber that tree.

## Port these 3 wins from the `12-dreaming/` reference into `dream/` (coordinated — `dream/` is hot)
The `12-dreaming/` reference has the working code for each; apply into `dream/` when that session is
idle (do **not** edit `dream/` while it's active).
1. **Richer signals** — add to `collect_digest.py`: git **churn** (files/insertions/deletions via
   `--shortstat`), **app identity** (`collect_app_scores()` from `ui-audit-usage.py`, KActivities
   read-only), **music genre** (MPRIS via `qdbus6`), **active-hours** (`loginctl`). Keep their commit
   subjects (good *local* signal). Ref: `12-dreaming/skill/scripts/dream-digest.py`.
2. **Deterministic date-seed** — derive `seed = fnv1a(date)` and carry it so "same night = same
   leg." Additive, low-risk. Ref: `dream-compose.py:fnv1a` / `dream-apply.py`.
3. **Earned-autonomy / staging (their design call)** — for a *nightly autonomous change to the live
   desktop*, a trust ramp (stage → user `--approve` once → auto; low-confidence stages) is safer than
   `accept --apply` writing immediately. Recommended, but theirs to accept. Ref:
   `dream-apply.py` (`is_earned`, staging, confidence floor).

## Verification (recap)
- **Subsystem B (dream/):** `python3 dream/test_dream.py` + `test_compose.py` → 23/23 each (green).
- **`12-dreaming/` reference:** `python3 12-dreaming/tests/test_dream_apply.py` → 29/29; full
  pipeline (digest→compose→apply) verified end-to-end against live Ollama (`gemma4-64k`).
- **Subsystem A (WFC), when built:** windowed capture at the leg seam (one arch, continuous
  floor/walls, no z-fight) — `BEVY_ASSET_ROOT="$PWD" NIMBUS_FLUX_CAPTURE=1 NIMBUS_FLUX_SCENE=journey
  NIMBUS_FLUX_JOURNEY_CAM="0,2.6,2,0,2.6,-50" timeout 30 ./target/debug/nimbus-flux`.

## Sources
`bevy_ghx_proc_gen` (crates.io / github Henauxg — `with_initial_grid`, `RngMode::Seeded`); Ollama
structured outputs (`format`=schema)→llama.cpp GBNF; in-context enum + retry; bevy handle
ref-counting for streaming; fog/atmosphere interpolation + archway occluder + 0.01 z-offset for seams.
