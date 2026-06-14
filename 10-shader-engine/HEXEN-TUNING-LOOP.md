# Hexen tuning loop — data-driven, no-compile, vision-judged refinement

The Layer-10 `hexen` wallpaper is refined by a **see-and-adjust loop** that a local vision
model (or a human) can run on an ongoing basis: change ONE knob → render → *look at the
PNG* → judge against the last-good baseline → keep or revert. The knobs are **externalized
to a JSON file the scene reads at startup**, so the loop **never compiles**, never breaks
the build, and never collides with the concurrent RT/DLSS source edits in `scene_hexen.rs`.

This is the small, working sibling of the dreaming-phase composer and `6-local-ai/ui-audit/`:
the model edits *validated data, never code*. Built as a **3-knob spike** (proven
2026-06-14); widen the knob surface once the loop is trusted.

## The pieces
| Piece | What it does |
|---|---|
| `scene_hexen.rs::HexenTuning` | Deserializes `NIMBUS_FLUX_HEXEN_TUNING` (a JSON path) at `setup()`. **Missing/invalid → the hardcoded defaults.** Every field is **clamp-bounded on load** — the renderer never trusts the file. Only **raster/shared** values are externalized; the `if rt {…}` lighting stays the DLSS session's. |
| `hexen-tune.py` | Guardrail manager: `set` (clamp+stage) · `capture` (run binary **headless/offscreen** — no window/swapchain, save frame) · `accept` (promote tuning→last-good + capture→baseline + **ledger**) · `revert` (restore last-good) · `show`/`ledger`/`knobs`. |
| `hexen-vision-judge.py` | The **look** step: hands BEFORE+AFTER frames + the rubric to a local Ollama vision model, returns a strict `{better,reason,artifacts,confidence}` verdict. Exit 0 = keep, 10 = revert. **Default model `qwen3.6-27b-64k` (discriminates); NOT gemma4-64k (rubber-stamps)** — see below. |
| `hexen-autotune.py` | The **autonomous driver**: PROPOSE (vision model picks one knob from `baseline.png`) → set → capture → JUDGE → accept\|revert → ledger, looping N times. Separate `--model` (proposer) and `--judge-model` (the integrity-critical one). |
| `~/.nimbus/hexen-tune/` | State: `tuning.json` (live knobs the scene reads), `last-good.json` (revert target), `baseline.png` (comparison anchor), `captures/`, `ledger.jsonl`. Not in the repo — machine state, like `~/.hermes/ui-audit/`. |

## Knob surface (the 3-knob spike — ranges mirror the Rust clamps)
| Knob | Default | Safe range | Effect |
|---|---|---|---|
| `wall_roughness` | 0.7 | 0.5–0.95 | hero brick gloss; lower = wetter, reveals relief |
| `wall_depth` | 0.045 | 0.0–0.06 | hero brick parallax; **>0.06 smears** the stretched UV |
| `moonlight` | 850 | 400–1400 | cool key illuminance (raster); warm/cool contrast = depth |
| `floor_roughness` | 0.45 | 0.35–0.7 | floor gloss; lower = wetter flagstone glint |
| `floor_depth` | 0.03 | 0.0–0.05 | floor parallax relief |
| `ambient` | 42 | 25–80 | `AmbientLight` fill (raster); lower = deeper shadows |
| `fog_density` | 0.007 | 0.004–0.012 | `DistanceFog` far-fade depth vs. detail wash |
| `fogvolume_density` | 0.028 | 0.015–0.05 | god-ray haze vs. curtaining |

`./hexen-tune.py knobs` emits this surface as JSON (the single source the autotuner reads).
The remaining levers (ceiling/torch/props/…) are in `HEXEN-REFINEMENT-HANDOFF.md`. To **widen**:
add the field to `KNOBS` in `hexen-tune.py` **and** to `HexenTuning` (struct + `Default` +
clamped `load`) in `scene_hexen.rs`, then rebuild once. After that, tuning that field is
data-only again. (torch intensity/range need a `spawn_torch` signature change, so they're not
in the spike's single-literal set yet.)

## One iteration (what the loop runs)
```bash
cd 10-shader-engine
# 0. (first time) establish the baseline at the current best:
./hexen-tune.py capture --label baseline && ./hexen-tune.py accept -m "baseline"

# 1. pick ONE goal + ONE knob + a small in-range delta:
./hexen-tune.py set moonlight=1150 -m "raise cool key to penetrate the interior"
# 2. render (NO compile — just re-reads the JSON):
./hexen-tune.py capture --label moon1150
# 3. the model looks and judges (before = baseline, after = the new capture):
./hexen-vision-judge.py --before ~/.nimbus/hexen-tune/baseline.png \
    --after ~/.nimbus/hexen-tune/captures/moon1150.png --goal "raised moonlight for depth"
# 4. keep or revert on the verdict:
./hexen-tune.py accept -m "<verdict>" --capture ~/.nimbus/hexen-tune/captures/moon1150.png
#   or, if not better:
./hexen-tune.py revert
```
`capture` parks a deterministic camera (`--cam`, default `0,2.2,23,0,0.4,9`) so before/after
differ ONLY by the knob; `--cam dolly` lets it glide; `--rt` previews the RT path; `--label`
names the frame. The launcher/loop always runs the **newest** of `target/{release,debug}`.

## Running it autonomously (the "ongoing basis" ask)
`hexen-autotune.py` IS that driver — no human in the loop. Per iteration it: shows the
vision model the current best (`baseline.png`) and asks for ONE `{knob,value,goal}`
(PROPOSE), then `set` → `capture` → `hexen-vision-judge.py` (JUDGE) → `accept` (exit 0) or
`revert` (exit 10), ledgering each accept. It only orchestrates the three single-purpose
tools, so all guardrails live in one place and a bad proposal is harmless (clamped,
rendered, judged, reverted).
```bash
./hexen-autotune.py --iterations 5                 # gemma proposes, qwen judges (defaults)
./hexen-autotune.py --iterations 3 --dry-propose   # just print what it would try
```

### ⚠️ The judge model is the make-or-break choice (verified 2026-06-14)
A confabulating judge makes the whole loop worthless — it accepts noise and regressions.
**`gemma4-64k` (8B) RUBBER-STAMPS**: it returned `better @0.95` even on a deliberately-WORSE
frame (a dark, flat, low-contrast wash), with a confident confabulated reason.
**`qwen3.6-27b-64k` DISCRIMINATES**: correct in both directions (worse→false, swapped→true)
with grounded reasons, and it caught a real in-loop regression (an added-fog change that
"washes out contrast and softens speculars"). So **qwen is the default judge**; gemma is
fine only as the *proposer* (`--model` = proposer, `--judge-model` = judge). **Always
sanity-check a new judge model against a known-worse pair before trusting it** — this is the
vision-form of the Hermes-confabulation lesson (`ui-audit-toolkit`, `verify-effect-not-command`).
A text-only model (Hermes) can drive the *parameter search* but still needs a discriminating
vision model (or a human) for the look.

### Capture is headless/offscreen (swapchain contention SOLVED)
`capture` renders the scene to an **offscreen image** (`main.rs`: `NIMBUS_FLUX_CAPTURE=1`
&& not wallpaper → a render-target `Image`, the camera redirected to it, `Screenshot::image`
+ `save_to_disk`) — **no window, no compositor surface, no swapchain**. This sidesteps the
old failure where a windowed capture raced the live **RT hexen wallpaper** for the NVIDIA
swapchain and panicked `Couldn't get swap chain texture … timeout` (verified: windowed = 0/5
under the live wallpaper; headless = 5/5). Two implementation notes that bit during the build:
a windowless bevy app must drop `WinitPlugin` and run under `ScheduleRunnerPlugin` (winit
won't pump the update loop with no window → the app hangs at startup); and the target image
needs `COPY_SRC` added (`new_target_texture` only sets `RENDER_ATTACHMENT|TEXTURE_BINDING|
COPY_DST`). `--retries` stays as cheap insurance against a transient GPU-init hiccup.

**Guardrails (non-negotiable):** clamp every knob (enforced twice — script + renderer);
**one knob per iteration** (the judge must be able to attribute the change); **always
re-render before judging**; **verify the EFFECT, not the command** (exit 0 ≠ better);
revert on regression; **ledger every accept**; keep the last-good capture as the baseline;
**never edit the `if rt {…}` RT/DLSS branches**; **don't judge on the live wallpaper** (a
layer-shell surface can't be screenshotted — always capture windowed).

## Making an accepted tuning go live (wired — explicit promotion)
Promotion is **explicit**, so an in-flight tune never surprises the desktop:
```bash
./hexen-tune.py go-live        # copy last-good.json -> live.json (promote)
./hexen-tune.py go-live --off  # remove live.json (back to hardcoded defaults)
```
The launcher (`wallpaper-plugin/nimbus-flux-wallpaper.sh`) exports
`NIMBUS_FLUX_HEXEN_TUNING=~/.nimbus/hexen-tune/live.json` for the hexen scene **when that
file exists**; the renderer clamps every field and falls back to defaults if it's
missing/invalid. Takes effect on the **next wallpaper (re)start** (the running wallpaper is
left alone). **⚠️ RT/raster transfer:** the live wallpaper runs the **RT** path, so only the
**path-shared** knobs carry over — materials (`wall_roughness/depth`, `floor_roughness/depth`),
parallax, and fog (`fog_density`, `fogvolume_density`). The **raster-only lighting** knobs
(`moonlight`, `ambient`) live in `if rt {…}`/ambient-fill branches and **do not affect the RT
wallpaper** — the loop tunes them for the windowed capture only. (Don't do a plain
`cargo build --release` to "go live": that would shadow the DLSS session's `--features dlss`
release binary the launcher picks by mtime — release builds are theirs, via `run.sh`.)

## Status
- 2026-06-14 (spike): proved the data-driven path mechanically (two JSON values, **one
  binary, no rebuild** → different renders) and one human-confirmed vision-judged iteration
  (`moonlight 850→1150`, accepted + ledgered).
- 2026-06-14 (widen + autonomy): widened to **8 knobs** (added floor_roughness/floor_depth/
  ambient/fog_density/fogvolume_density — all single-literal raster/shared); built
  `hexen-autotune.py` and ran it end-to-end (PROPOSE→capture→JUDGE→accept|revert→ledger),
  with safe degradation verified (failed captures revert, no bad state).
- **Judge finding (the important one):** `gemma4-64k` rubber-stamps (`better @0.95` on a
  worse frame); `qwen3.6-27b-64k` discriminates (both directions + caught a real regression)
  → made the default judge. The gemma-rubber-stamped `wall_depth`/`fog` accepts were
  re-judged by qwen and **reverted**; live tuning reset to the verified anchor `moonlight=1150`.
- 2026-06-14 (headless capture): `main.rs` now renders captures **offscreen** (no window/
  swapchain) under `ScheduleRunnerPlugin` → the live-RT-wallpaper contention is gone
  (windowed 0/5 → headless 5/5). Capstone run: gemma proposed more fog, **qwen judged it
  WORSE and the loop reverted** — reliable capture + discriminating judge, end-to-end.
- 2026-06-14 (go-live wired): all Rust now **committed** (the concurrent session committed
  the base `HexenTuning`; the 8-knob widening + headless capture committed on top, raster-only).
  `hexen-tune.py go-live` promotes `last-good → live.json`; the launcher exports
  `NIMBUS_FLUX_HEXEN_TUNING` for hexen when it exists (verified by parts; applies on next
  wallpaper restart, running wallpaper left alone). No `--release` build (would shadow the
  DLSS release binary).
- **Open / next:** (a) the loop tunes **raster**, but the live wallpaper is **RT** — only
  shared material/fog knobs transfer; closing that gap means tuning the RT path (the DLSS
  session's territory, grainy pre-DLSS). (b) accumulate transferable material/fog improvements
  via `hexen-autotune.py` (qwen judge is strict — that's the point). (c) widen to torch
  knobs (needs a `spawn_torch` signature change).
