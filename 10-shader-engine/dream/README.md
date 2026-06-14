# `dream/` — dreaming-journey guardrails (catalog · validator · ledger)

The trust boundary between a **candidate leg manifest** and the live Layer-10 bevy
journey. The model (step 5) proposes a new leg; **this disposes** — exactly the shape of
`6-local-ai/ui-audit/`: deny-by-default allowlist, bounds clamping, schema validation,
append-only ledger, one-command revert. Pure data + Python, **no engine**, so a bad
manifest can never reach the composer and the whole thing is unit-testable offline.

## Files
- **`catalog.json`** — the only ids a leg may reference: procedural `geometry_kinds`
  (with param ranges), CC0 `stone` textures + `models` (category/license/bbox), and
  `bounds` (clamp ranges + seam tolerance). The single source of truth; the fetcher can
  also be driven from it.
- **`dreamlib.py`** — `validate_leg(manifest, catalog, prev_exit)` → `{ok, rejected,
  reason, sanitized, issues}`. Pure. Unknown geometry kind / broken schema / un-seamable
  aperture → **reject** (leg not applied). Unknown prop → **drop**; unknown stone →
  **substitute** the catalog default; out-of-range value → **clamp**. Each fix is logged.
- **`dream.py`** — CLI over `dreamlib` + the ledger. **Dry-run by default**; `--apply`
  writes. The journey dir is the SAME one the bevy composer reads
  (`$NIMBUS_FLUX_JOURNEY_DIR`, else `../nimbus-flux/journey`); the ledger is
  `<journey>/ledger.jsonl`. Beyond manual `accept`/`revert` it carries the **earned-autonomy
  ramp** — `stage` → `approve`/`reject`, a `trust.json` streak that lets `land` auto-apply
  unattended only after N human approvals (and revokes it on any reject or revert).
- **`collect_digest.py`** — the **single** day-signal collector (problem F), consolidating the
  former `signals/collect-signals.py`: git commits + conventional types/scopes + language
  buckets, active-hours, window layout, the optional dwell sampler, audio level off the
  `nimbus-aurora` bridges, time-of-day → a compact, grounded **day-digest** (with a model-facing
  `summary[]`). Local-only, best-effort. `signals/collect-signals.py` is now a thin CLI/sampler
  shim over it (a hyphen made it un-importable — which is why the rich signals never reached the
  composer until the consolidation).
- **`compose.py`** — the model composer (problems E + G): day-digest + previous leg + catalog
  → grounded prompt (leads with the digest's `summary[]`) → **Ollama `/v1`** (model-agnostic,
  `$NIMBUS_DREAM_MODEL`, default `hermes4-14b` — a small model fits alongside the live RT
  wallpaper; the guardrails, not the model, enforce integrity, and the call retries transient
  VRAM-contention errors) → tolerant JSON extract → **assemble** (force
  seam-safe portals + constant cross-section, so continuity never depends on the model) →
  `validate_leg` → **retry** with the reason on a miss. A **deterministic date-seed** makes a
  given day replayable. The model call is injected, so the loop is testable offline.
- **`dream-cycle.sh`** — one autonomous cycle: compose today's leg → `dream.py land` it through
  the ramp. Idempotent per day. The unit of work the nightly timer / supervisor loop runs.
- **`nimbus-dream.{service,timer}`** — opt-in user units that run `dream-cycle.sh` nightly (see below).
- **`test_dream.py` / `test_compose.py`** — offline checks (reject/drop/clamp/seam +
  accept/stage/approve/reject/revert round-trips; digest/prompt-grounding/JSON-extract/retry/seed
  with a fake model). Each exits 0 = pass.

## Workflow
```bash
# autonomous (what the timer / supervisor loop runs):
bash dream-cycle.sh                          # compose today's leg → land/stage through the ramp
python3 dream.py trust                       # show earned-autonomy state + any staged leg
python3 dream.py approve --apply             # land the staged candidate (+earns trust)
python3 dream.py reject  --apply             # drop it (revokes auto-apply)

# manual / inspection:
python3 collect_digest.py                    # today's rich day-digest (stdout)
python3 compose.py                           # digest → model → candidate (dry: /tmp/...json)
python3 dream.py catalog --check-assets      # catalog summary; verify every id has files
python3 dream.py list                        # legs + recent ledger
python3 dream.py validate cand.json          # dry validate + issue report (writes nothing)
python3 dream.py land     cand.json --apply  # auto-apply IF trusted, else stage
python3 dream.py accept   cand.json --apply  # manual: append as next leg-NNN + ledger
python3 dream.py revert   --n 1 --apply       # drop the last N legs (leg-000 is protected)
```

## Run it autonomously (opt-in user units — reversible, nothing auto-installs)
```bash
cd 10-shader-engine/dream
mkdir -p ~/.config/systemd/user
cp nimbus-dream.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now nimbus-dream.timer    # compose one leg nightly (23:30 local)
# stop + remove:
systemctl --user disable --now nimbus-dream.timer
rm ~/.config/systemd/user/nimbus-dream.{service,timer}
```
The timer **stages** each night's leg until the **trust ramp** is earned: approve the first few
(`dream.py approve --apply`) and `land` flips to unattended auto-apply; a `reject`/`revert` revokes
it. A Claude `/loop` can play that supervisor role and hand off across context windows. Select
**“Dream journey (evolving)”** in System Settings → Wallpaper to render it live.

## Where this sits
`leg-000..003` are hand-authored (steps 1–3). **Step 5 (done)** wires a Layer-6 local model to
dream the creative half of a leg from the day-digest; the mechanical/seam half is forced and
every candidate goes through the guardrails, so only catalog-grounded, bounds-clamped, seam-valid
legs land. **Step 6 (done)** is the nightly `nimbus-dream.timer` + the earned-autonomy ramp: it
stages a leg a night, a supervisor (you, or a Claude `/loop`) approves the first few, then it runs
unattended — the journey extends itself from your real days.

> Assets are **CC0 / procedural only** (standing rule — [[no-untrusted-third-party-services]]).
> The catalog *is* that allowlist; the validator enforces it.
