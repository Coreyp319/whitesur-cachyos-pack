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
  `<journey>/ledger.jsonl`.
- **`collect_digest.py`** — the day-signal collector (problem F): git commits/subjects (last
  24 h), window count + audio level off the `nimbus-aurora` bridges, time-of-day → a compact
  **day-digest** JSON. Local-only, best-effort (a missing source is omitted).
- **`compose.py`** — the model composer (problems E + G): day-digest + previous leg + catalog
  → prompt → **Ollama `/v1`** (model-agnostic, `$NIMBUS_DREAM_MODEL`, default `qwen3.6-27b-64k`)
  → tolerant JSON extract → **assemble** (force seam-safe portals + constant cross-section, so
  continuity never depends on the model) → `validate_leg` → **retry** with the reason on a miss.
  The model call is injected, so the loop is testable offline.
- **`test_dream.py` / `test_compose.py`** — offline checks (reject/drop/clamp/seam +
  accept→revert; digest/prompt-grounding/JSON-extract/retry with a fake model). Each exits 0 = pass.

## Workflow
```bash
python3 collect_digest.py                   # today's day-digest (stdout)
python3 compose.py                          # digest → model → candidate (dry: /tmp/...json)
python3 compose.py --apply                  # …then land it through the guardrails + ledger
# or drive the guardrails directly:
python3 dream.py catalog --check-assets     # catalog summary; verify every id has files
python3 dream.py list                       # legs + recent ledger
python3 dream.py validate cand.json         # dry validate + issue report (writes nothing)
python3 dream.py accept   cand.json --apply  # validate → append as next leg-NNN + ledger
python3 dream.py revert   --n 1 --apply      # drop the last N legs (leg-000 is protected)
```

## Where this sits
`leg-000..003` are hand-authored (steps 1–3). **Step 5 (done)** wires a Layer-6 local model to
dream the creative half of a leg from the day-digest; the mechanical/seam half is forced and
every candidate goes through `dream.py accept`, so only catalog-grounded, bounds-clamped,
seam-valid legs land. **Step 6** is the nightly systemd timer that runs `compose.py --apply`
(+ exposes `dream.py revert`).

> Assets are **CC0 / procedural only** (standing rule — [[no-untrusted-third-party-services]]).
> The catalog *is* that allowlist; the validator enforces it.
