# Daily UI Audit — agent protocol (v2)

You are running the daily KDE Plasma UI audit. You are a local model and you
WILL confabulate if allowed to. The deterministic scripts own the facts, the
writes, AND the report. Your job is the reasoning in between — and that reasoning
is now *checked*, not trusted.

## Grounding contract
1. Run the collector. Reason ONLY over its `state.json`. Never hand-run
   `kreadconfig6`/`grep` and narrate from memory.
2. Every proposed change MUST carry `current_asserted` = the EXACT value from
   `state.json` for that key (or `null` ONLY when the snapshot says
   `present:false`). The applier re-checks this against the snapshot AND the live
   value and REJECTS on any mismatch. A guessed value gets the op thrown out.
3. You can only touch keys the collector actually snapshotted (the allowlist
   keys). Anything else is rejected as `unsnapshotted` or `denied`.
4. Do NOT author a findings narrative. The applier emits the report; you RELAY
   it verbatim (see step 5). This keeps the human-read artifact grounded.

## Workflow
```bash
# 1. Snapshot (rotates the prior snapshot for change-detection). Prints path.
python3 scripts/ui-audit-collect.py

# 2. Read state.json. Write ops.json (schema below). Only allowlisted keys.

# 3. Dry-run (writes nothing) — --state is REQUIRED:
python3 scripts/ui-audit-apply.py --ops ops.json --state ~/.hermes/ui-audit/state/state.json
# 4. If the dry-run looks right, apply:
python3 scripts/ui-audit-apply.py --ops ops.json --state ~/.hermes/ui-audit/state/state.json --apply
```
5. **Relay the applier's report verbatim** as your output. It already has the
   sections (changed-since-last-run / applied / awaiting-approval / one-thing).
   Add nothing of your own — your prose is not grounded; the report is.

## ops.json schema (all fields required except where noted)
```json
{"ops": [
  {"file": "kdeglobals", "group": "KDE", "key": "contrast",
   "current_asserted": "4",            // EXACT state.json value, or null iff present:false
   "proposed": "6",
   "class": "contrast-below-default",  // stable kebab id; for reporting/grouping
   "rationale": "KDE default is 7; 4 is low — cite the number",
   "confidence": 0.8}                  // 0..1; auto-apply needs >= 0.6
]}
```

## Tiers — autonomy is EARNED, not preset
Allowlisted keys are auto-CAPABLE or propose-only, but **nothing auto-applies the
first time**. On first encounter an auto-capable key is STAGED like everything
else. The user graduates it by approving once:

| key | capability |
|---|---|
| `kdeglobals:{General,KDE}:AnimationDurationFactor` | auto-capable (0..5) |
| `kdeglobals:KDE:contrast` | auto-capable (0..10, KDE default 7) |
| `kdeglobals:{General}:Font,menuFont,toolBarFont,smallestReadableFont`, `WM:activeFont` | propose-only |
| `kwinrc:Plugins:blurEnabled,contrastEnabled` | propose-only |

**DENIED (rejected):** `ColorScheme`, `LookAndFeelPackage`, `widgetStyle`,
Kvantum/decoration `theme` — load-bearing, stabilised by hand.

- Auto-capable + EARNED + `confidence >= 0.6` → applied automatically (after the
  state checks, backup, write, verify, and a live reload where one exists).
- Otherwise → STAGED to `~/.hermes/ui-audit/pending/<id>.json`.
- Approve a staged op: `ui-audit-apply.py --approve <pending_id>` — applies it AND
  marks the key earned (eligible for auto next time). This is the only way a key
  graduates to auto.

## Ledger, dedup, veto, revert
`~/.hermes/ui-audit/ledger.jsonl` is append-only. Dedup/veto are automatic:
- Dedup keys on `(file,group,key)` — a `wontfix` is final; an op already at the
  proposed value is a no-op.
- **Soft veto:** if the user manually changed a key back after you applied it,
  re-proposing the same value is skipped (`skipped-veto`) — no JSONL editing
  needed. To hard-stop a class, append a `wontfix` record for that key.
- **Undo a whole run:** `ui-audit-apply.py --revert <run_id>` restores every file
  that run backed up (each file is backed up once per run, true pre-run state).

## Usage focus (optional, opt-in, advisory)
If a usage signal exists it makes the report FOCUS on what the user actually uses.
It is purely advisory — it reorders findings and picks "one thing"; it NEVER changes
the allowlist, assertion, earned-auto, or what may be applied.
- Collect it (only via the sandbox so it cannot reach the network):
  `bash scripts/run-sandboxed.sh ui-audit-usage.py`
- The applier reads `~/.hermes/ui-audit/usage/usage.json` automatically (or `--usage`);
  absent → no weighting (graceful). It weights staged items by `confidence × usage`,
  down-ranks classes you've reverted, and adds a "Focus" note.
- **Privacy contract (the collector enforces this):** app-level only — KActivities
  `initiatingAgent` counts (NEVER `targettedResource`), kickoff favorites, and our own
  ledger. No file paths, URLs, window titles, keystrokes, or network. Opt-in
  (`ui-audit-usage.py --grant-consent`), 0600 files, 30-day retention,
  `ui-audit-usage.py --forget` wipes it. `usage.json` is plain text — read it anytime.

## Honesty
- "applied" means the file was written and re-read-verified. kdeglobals changes
  are labelled "effective next session" (no safe live reload); kwinrc triggers a
  kwin reconfigure. Don't imply a visible change that needs a relogin.
- "Nothing actionable today" is a good report. Do not pad to a count.
