# Layer 12 — the dreaming composer

A nightly **local-AI "dreaming" phase**: a Layer-6 model reflects on the day and composes a new
**leg** of the Layer-10 `journey` wallpaper — so the desktop becomes an endless, evolving journey you
wake into each morning. The model proposes high-level **knobs**; a guardrail disposes, turning them
into a validated `leg-NNN.json` that the already-compiled bevy composer (`nimbus-flux`, scene
`journey`) renders. Every nightly change is **ledgered and trivially revertible**.

Full design: [`../10-shader-engine/DREAMING-DESIGN.md`](../10-shader-engine/DREAMING-DESIGN.md)
(and `SCENE-COMPOSITION.md` / `DREAMING-PHASE-HANDOFF.md`). The trust boundary mirrors
`6-local-ai/ui-audit/`: **the model proposes; deterministic Python disposes.**

## Pipeline (nightly)
```
dream-digest.py   day signals (git/music/apps/time) → day-digest.json      BUILT & VERIFIED
dream-compose.py  digest + catalog → semantic-knobs JSON (Ollama, schema)  BUILT & VERIFIED
dream-apply.py    knobs → validated leg-NNN.json + ledger + backup/revert   BUILT & VERIFIED
dream-fetch.py    catalog-driven CC0 fetch (extends fetch-hexen-assets.py)  [TODO]
nightly-dream.sh  one-command chain (digest→compose→GPU-yield→apply)        BUILT & VERIFIED
```
Run the whole thing once (dry by default — composes + would-stage, writes no live leg):
```bash
bash 12-dreaming/nightly-dream.sh                 # dry-run
bash 12-dreaming/nightly-dream.sh --apply         # let the guardrail stage/append for real
NIMBUS_DREAM_MODEL=qwen3.6-27b-64k bash 12-dreaming/nightly-dream.sh   # pick the model
```

The model emits only **knobs** — `mood`, `palette_direction`, `motif`, `density`, `length_bias`,
`light_bias`, `seed`, `seed_from`, and prop picks **by catalog id**. There is no free-form geometry
field to hallucinate into. `dream-apply.py` maps knobs → concrete `LegManifest` fields
deterministically (seeded), clamps every numeric, drops unknown ids, asserts portal chaining, and
stages/applies under earned-autonomy. It targets the **`corridor`** geometry the engine ships today;
it gains a `wfc` branch when the WFC geometry subsystem (`nimbus-flux/src/wfc_leg.rs`) lands.

## `catalog.json`
Single source of truth: the validator's **enum** (what the model may reference) *and* the fetcher's
download list. CC0 only. Widen the model's vocabulary by adding a row here — not in code.

## Guardrail (`dream-apply.py`)
```
dream-apply.py --knobs KNOBS.json --journey-dir .../nimbus-flux/journey [--apply]
dream-apply.py --approve leg-007        # promote a staged leg to live + earn the pipeline
dream-apply.py --revert  20260614-0315  # restore the journey/ a run backed up
dream-apply.py --drop-last 1            # delete the last N live legs
```
- **Staged by default.** Nothing auto-applies to the live journey until you `--approve` one leg
  (graduates the pipeline to auto). Low-confidence legs always stage.
- **Reversible.** The whole `journey/` dir is backed up once per run; `--revert`/`--drop-last` undo.
- **Robust.** A malformed/over-constrained leg is rejected and ledgered, never written. (The engine
  *also* skips bad legs at load — this is defence-in-depth.)
- Runtime state under `~/.hermes/dreaming/` (override with `NIMBUS_DREAM_HOME`).

## Tests
```bash
python3 tests/test_dream_apply.py    # 29 offline adversarial checks, no GPU/Ollama/signals
```
Feeds hallucinated ids, out-of-bounds values, broken chaining, prose-wrapped/malformed JSON, the
earned-autonomy graduation, and revert/drop-last round-trips against a temp home + journey dir.

## Status
**Pipeline built & verified end-to-end** (digest → compose → apply, via `nightly-dream.sh`):
`catalog.json`, `dream-digest.py` (real signals on this box), `dream-compose.py` (live Ollama,
`gemma4-64k`), `dream-apply.py` (29/29 adversarial checks), `nightly-dream.sh` (one-command, dry).
TODO: `dream-fetch.py` (only needed once the catalog grows past the on-hand hexen assets); the
systemd `--user` timer + `install.sh`/`revert.sh`/`doctor.sh` + `nimbus.layers` registration (a
standing system change — install consciously); and the engine-side `wfc` geometry branch
(subsystem A) whose hooks wait on the concurrent streaming session's tree.
