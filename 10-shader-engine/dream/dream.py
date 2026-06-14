#!/usr/bin/env python3
"""`dream` — stage / accept / revert dreaming-journey legs through the guardrails.

The model (step 5) will emit a candidate leg manifest; THIS validates it against the
catalog (`dreamlib.validate_leg`) and, only if it survives, appends it to the journey as
the next `leg-NNN.json` and ledgers it. Dry-run by default — nothing is written without
`--apply`. Revert drops the last N legs (leg-000, the seed, is protected). Mirrors the
guardrail-applier + ledger shape of `6-local-ai/ui-audit/`.

The journey directory is the SAME one the bevy composer reads — `$NIMBUS_FLUX_JOURNEY_DIR`
if set, else `../nimbus-flux/journey`. The ledger lives at `<journey>/ledger.jsonl`.

Usage:
    dream.py validate CANDIDATE.json              # dry validate + report (writes nothing)
    dream.py accept   CANDIDATE.json [--apply]    # validate → append as next leg + ledger (manual)
    dream.py land     CANDIDATE.json [--apply]    # autonomous: auto-apply IF trusted, else stage
    dream.py stage    CANDIDATE.json [--apply]    # validate → hold as the pending candidate
    dream.py approve  [--apply]                   # land the staged candidate (+earns trust)
    dream.py reject   [--apply]                   # drop the staged candidate (revokes auto-apply)
    dream.py trust    [--threshold N]             # show/adjust the earned-autonomy ramp
    dream.py revert   [--n N] [--apply]           # drop the last N legs (not leg-000; revokes auto)
    dream.py list                                 # legs + recent ledger
    dream.py catalog  [--check-assets]            # catalog summary (+ on-disk asset check)

Earned autonomy: composed legs are STAGED, not auto-landed, until `land` has earned a streak
of `threshold` human approvals; a reject or a revert revokes auto-apply and resets the streak.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import dreamlib

HERE = Path(__file__).resolve().parent
DEFAULT_CATALOG = HERE / "catalog.json"
ASSET_ROOT = HERE.parent / "nimbus-flux" / "assets" / "hexen"

LEG_RE = re.compile(r"^leg-(\d+)\.json$")


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def journey_dir(arg: str | None) -> Path:
    import os

    if arg:
        return Path(arg)
    env = os.environ.get("NIMBUS_FLUX_JOURNEY_DIR")
    if env:
        return Path(env)
    return HERE.parent / "nimbus-flux" / "journey"


def list_legs(jdir: Path) -> list[tuple[int, Path]]:
    out = []
    if jdir.is_dir():
        for p in jdir.iterdir():
            m = LEG_RE.match(p.name)
            if m:
                out.append((int(m.group(1)), p))
    out.sort()
    return out


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def last_exit(jdir: Path) -> dict | None:
    """The newest leg's exit portal — what a continuing candidate's entry must match."""
    legs = list_legs(jdir)
    if not legs:
        return None
    try:
        return load_json(legs[-1][1]).get("exit")
    except Exception:
        return None


def ledger_path(jdir: Path) -> Path:
    return jdir / "ledger.jsonl"


def append_ledger(jdir: Path, rec: dict) -> None:
    jdir.mkdir(parents=True, exist_ok=True)
    with ledger_path(jdir).open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")


def read_ledger(jdir: Path) -> list[dict]:
    p = ledger_path(jdir)
    if not p.exists():
        return []
    out = []
    for line in p.read_text(encoding="utf-8").splitlines():
        try:
            out.append(json.loads(line))
        except Exception:
            continue
    return out


# --------------------------------------------------------------------------- #
# earned autonomy — a trust ramp so the nightly / dev-agent loop can land legs
# UNATTENDED only after it has earned a streak of human approvals, and loses that
# the moment a candidate is rejected or a leg is reverted. Staging holds the one
# pending candidate; trust.json holds the ramp state. Both live in the journey dir.
# --------------------------------------------------------------------------- #

DEFAULT_THRESHOLD = 3  # consecutive human approvals before unattended auto-apply unlocks


def trust_path(jdir: Path) -> Path:
    return jdir / "trust.json"


def default_trust() -> dict:
    return {"version": 1, "proposed": 0, "approved": 0, "rejected": 0, "auto_applied": 0,
            "streak": 0, "auto": False, "threshold": DEFAULT_THRESHOLD, "updated": None}


def load_trust(jdir: Path) -> dict:
    p = trust_path(jdir)
    if p.exists():
        try:
            t = default_trust()
            t.update(json.loads(p.read_text(encoding="utf-8")))
            return t
        except Exception:
            pass
    return default_trust()


def save_trust(jdir: Path, t: dict) -> dict:
    t["updated"] = now()
    jdir.mkdir(parents=True, exist_ok=True)
    trust_path(jdir).write_text(json.dumps(t, indent=2) + "\n", encoding="utf-8")
    return t


def trust_approve(t: dict) -> dict:
    t["approved"] += 1
    t["streak"] += 1
    t["auto"] = t["streak"] >= t["threshold"]
    return t


def trust_reject(t: dict) -> dict:
    t["rejected"] += 1
    t["streak"] = 0
    t["auto"] = False
    return t


def trust_auto(t: dict) -> dict:
    t["auto_applied"] += 1  # an unattended land — trust neither earned nor lost
    return t


def trust_revoke(t: dict) -> dict:
    t["streak"] = 0
    t["auto"] = False
    return t


def staging_path(jdir: Path) -> Path:
    return jdir / "staging.json"


def load_staging(jdir: Path) -> dict | None:
    p = staging_path(jdir)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def write_staging(jdir: Path, sanitized: dict, issues: list[dict], source: str) -> None:
    jdir.mkdir(parents=True, exist_ok=True)
    staging_path(jdir).write_text(json.dumps({
        "ts": now(), "source": source,
        "issues": dreamlib.summarize_issues(issues), "issue_detail": issues,
        "candidate": sanitized,
    }, indent=2) + "\n", encoding="utf-8")


def clear_staging(jdir: Path) -> None:
    staging_path(jdir).unlink(missing_ok=True)


def _land_leg(jdir: Path, sanitized: dict, issues: list[dict], via: str) -> tuple[str, dict]:
    """Write `sanitized` as the next leg-NNN (id := filename) and ledger it. Shared by
    accept (manual), approve (human-gated), and land (auto)."""
    legs = list_legs(jdir)
    next_idx = (legs[-1][0] + 1) if legs else 0
    fname = f"leg-{next_idx:03d}.json"
    leg = dict(sanitized)
    leg["id"] = f"leg-{next_idx:03d}"  # the file IS the id; a composer placeholder is overwritten
    (jdir / fname).write_text(json.dumps(leg, indent=2) + "\n", encoding="utf-8")
    rec = {
        "ts": now(), "status": "applied", "via": via,
        "leg": leg["id"], "file": fname,
        "seed_from": leg.get("seed_from"), "seed": leg.get("seed"), "day": leg.get("day"),
        "issues": dreamlib.summarize_issues(issues), "issue_detail": issues,
        "provenance": leg.get("provenance", {}),
    }
    append_ledger(jdir, rec)
    return fname, rec


def print_issues(issues: list[dict]) -> None:
    if not issues:
        print("  (no issues — clean)")
        return
    for i in issues:
        mark = {"reject": "✗ REJECT", "drop": "– drop", "clamp": "~ clamp", "warn": "! warn"}.get(i["level"], i["level"])
        print(f"  {mark:9} {i['field']}: {i['detail']}")


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #

def cmd_validate(args) -> int:
    catalog = dreamlib.load_catalog(args.catalog)
    jdir = journey_dir(args.journey)
    candidate = load_json(Path(args.candidate))
    res = dreamlib.validate_leg(candidate, catalog, last_exit(jdir))
    print(f"validate {args.candidate} (id={candidate.get('id', '?')}) against {jdir}")
    print_issues(res["issues"])
    print(f"=> {'REJECTED: ' + res['reason'] if res['rejected'] else 'OK (would apply)'}")
    return 1 if res["rejected"] else 0


def cmd_accept(args) -> int:
    catalog = dreamlib.load_catalog(args.catalog)
    jdir = journey_dir(args.journey)
    candidate = load_json(Path(args.candidate))
    prev = last_exit(jdir)
    res = dreamlib.validate_leg(candidate, catalog, prev)

    legs = list_legs(jdir)
    next_idx = (legs[-1][0] + 1) if legs else 0
    fname = f"leg-{next_idx:03d}.json"

    print(f"accept {args.candidate} → {fname} in {jdir}")
    print_issues(res["issues"])
    if res["rejected"]:
        print(f"=> REJECTED: {res['reason']} — NOT applied")
        return 1
    if not args.apply:
        print(f"=> dry-run: would write {fname} ({dreamlib.summarize_issues(res['issues'])}). Re-run with --apply.")
        return 0
    fname, rec = _land_leg(jdir, res["sanitized"], res["issues"], via="manual")
    print(f"=> APPLIED {fname} (ledgered). issues={rec['issues']}")
    return 0


def cmd_stage(args) -> int:
    catalog = dreamlib.load_catalog(args.catalog)
    jdir = journey_dir(args.journey)
    candidate = load_json(Path(args.candidate))
    res = dreamlib.validate_leg(candidate, catalog, last_exit(jdir))
    print(f"stage {args.candidate} → {staging_path(jdir).name} in {jdir}")
    print_issues(res["issues"])
    if res["rejected"]:
        print(f"=> REJECTED: {res['reason']} — NOT staged")
        return 1
    if not args.apply:
        print("=> dry-run: would stage (pending approval). Re-run with --apply.")
        return 0
    write_staging(jdir, res["sanitized"], res["issues"], source="stage")
    t = load_trust(jdir); t["proposed"] += 1; save_trust(jdir, t)
    print("=> STAGED (pending approval). Approve with `dream.py approve --apply`.")
    return 0


def cmd_approve(args) -> int:
    jdir = journey_dir(args.journey)
    staged = load_staging(jdir)
    if not staged:
        print("nothing staged to approve")
        return 1
    if not args.apply:
        print(f"=> dry-run: would approve staged candidate (day={staged.get('candidate', {}).get('day')}). Re-run with --apply.")
        return 0
    fname, rec = _land_leg(jdir, staged["candidate"], staged.get("issue_detail", []), via="approved")
    t = save_trust(jdir, trust_approve(load_trust(jdir)))
    clear_staging(jdir)
    tail = " — auto-apply UNLOCKED" if t["auto"] else f" ({t['streak']}/{t['threshold']} toward auto)"
    print(f"=> APPROVED → {fname} (ledgered).{tail}")
    return 0


def cmd_reject(args) -> int:
    jdir = journey_dir(args.journey)
    staged = load_staging(jdir)
    if not staged:
        print("nothing staged to reject")
        return 1
    if not args.apply:
        print("=> dry-run: would reject staged candidate. Re-run with --apply.")
        return 0
    save_trust(jdir, trust_reject(load_trust(jdir)))
    append_ledger(jdir, {"ts": now(), "status": "rejected", "via": "human",
                         "day": staged.get("candidate", {}).get("day"),
                         "provenance": staged.get("candidate", {}).get("provenance", {})})
    clear_staging(jdir)
    print("=> REJECTED staged candidate (auto-apply revoked; streak reset).")
    return 0


def cmd_land(args) -> int:
    """Autonomous entrypoint: validate, then land directly IF trust has earned auto-apply,
    else stage for human approval. This is what the nightly / dev-agent loop calls."""
    catalog = dreamlib.load_catalog(args.catalog)
    jdir = journey_dir(args.journey)
    candidate = load_json(Path(args.candidate))
    res = dreamlib.validate_leg(candidate, catalog, last_exit(jdir))
    print(f"land {args.candidate} in {jdir}")
    print_issues(res["issues"])
    if res["rejected"]:
        print(f"=> REJECTED: {res['reason']} — NOT landed")
        return 1
    t = load_trust(jdir)
    if not args.apply:
        mode = "auto-apply" if t["auto"] else "stage (awaiting approval)"
        print(f"=> dry-run: trust auto={t['auto']} → would {mode}. Re-run with --apply.")
        return 0
    t["proposed"] += 1
    if t["auto"]:
        fname, rec = _land_leg(jdir, res["sanitized"], res["issues"], via="auto")
        clear_staging(jdir)
        save_trust(jdir, trust_auto(t))
        print(f"=> AUTO-APPLIED → {fname} (trusted; ledgered).")
        return 0
    write_staging(jdir, res["sanitized"], res["issues"], source="land")
    save_trust(jdir, t)
    print(f"=> STAGED (untrusted; {t['streak']}/{t['threshold']} toward auto). Approve with `dream.py approve --apply`.")
    return 0


def cmd_trust(args) -> int:
    jdir = journey_dir(args.journey)
    t = load_trust(jdir)
    staged = load_staging(jdir)
    print(f"trust ({jdir}):")
    print(f"  auto-apply : {'ON' if t['auto'] else 'off'}  (streak {t['streak']}/{t['threshold']})")
    print(f"  decisions  : {t['approved']} approved, {t['rejected']} rejected, "
          f"{t['auto_applied']} auto, {t['proposed']} proposed")
    print(f"  staged     : {'yes — day ' + str(staged.get('candidate', {}).get('day')) if staged else 'none'}")
    if args.threshold is not None:
        t["threshold"] = max(1, args.threshold)
        t["auto"] = t["streak"] >= t["threshold"]
        save_trust(jdir, t)
        print(f"  => threshold set to {t['threshold']}")
    return 0


def cmd_revert(args) -> int:
    jdir = journey_dir(args.journey)
    legs = list_legs(jdir)
    droppable = [(i, p) for (i, p) in legs if i > 0]  # leg-000 (seed) is protected
    if not droppable:
        print("nothing to revert (only the seed leg-000 remains)")
        return 0
    victims = droppable[-args.n:]
    print(f"revert last {len(victims)} leg(s) from {jdir}:")
    for i, p in victims:
        print(f"  - {p.name}")
    if not args.apply:
        print("=> dry-run: nothing deleted. Re-run with --apply.")
        return 0
    for i, p in victims:
        p.unlink(missing_ok=True)
        append_ledger(jdir, {"ts": now(), "status": "reverted", "leg": f"leg-{i:03d}", "file": p.name})
    save_trust(jdir, trust_revoke(load_trust(jdir)))  # a revert is dissatisfaction → re-earn autonomy
    print(f"=> reverted {len(victims)} leg(s) (ledgered; auto-apply revoked)")
    return 0


def cmd_list(args) -> int:
    jdir = journey_dir(args.journey)
    legs = list_legs(jdir)
    print(f"journey: {jdir}  ({len(legs)} leg(s))")
    for i, p in legs:
        try:
            m = load_json(p)
            motif = (m.get("theme", {}) or {}).get("motif", "")
            print(f"  {p.name:14} {m.get('id', ''):10} {motif}")
        except Exception as e:
            print(f"  {p.name:14} (unreadable: {e})")
    led = read_ledger(jdir)
    if led:
        print(f"ledger: {len(led)} record(s); most recent:")
        for r in led[-5:]:
            print(f"  {r.get('ts', '')[:19]}  {r.get('status', ''):9} {r.get('leg', '')}  {r.get('issues', '')}")
    return 0


def cmd_catalog(args) -> int:
    catalog = dreamlib.load_catalog(args.catalog)
    kinds = list(catalog.get("geometry_kinds", {}))
    stone = list(catalog.get("stone", {}))
    models = list(catalog.get("models", {}))
    print(f"catalog v{catalog.get('version')}: {len(kinds)} geometry kind(s), {len(stone)} stone, {len(models)} models")
    print(f"  kinds : {', '.join(kinds)}")
    print(f"  stone : {', '.join(stone)}")
    print(f"  models: {', '.join(models)}")
    if args.check_assets:
        missing = []
        for s in stone:
            if not (ASSET_ROOT / "textures" / s).is_dir():
                missing.append(f"stone/{s}")
        for m in models:
            if not (ASSET_ROOT / "models" / m).is_dir():
                missing.append(f"model/{m}")
        if missing:
            print(f"  ⚠ {len(missing)} catalog id(s) have NO files under {ASSET_ROOT} (run fetch-hexen-assets):")
            for x in missing:
                print(f"      {x}")
        else:
            print(f"  ✓ all catalog ids have asset files under {ASSET_ROOT}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Dreaming-journey leg guardrails (catalog + validator + ledger).")
    ap.add_argument("--catalog", default=str(DEFAULT_CATALOG))
    ap.add_argument("--journey", help="journey dir (default: $NIMBUS_FLUX_JOURNEY_DIR or ../nimbus-flux/journey)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("validate"); p.add_argument("candidate"); p.set_defaults(fn=cmd_validate)
    p = sub.add_parser("accept"); p.add_argument("candidate"); p.add_argument("--apply", action="store_true"); p.set_defaults(fn=cmd_accept)
    p = sub.add_parser("stage"); p.add_argument("candidate"); p.add_argument("--apply", action="store_true"); p.set_defaults(fn=cmd_stage)
    p = sub.add_parser("land"); p.add_argument("candidate"); p.add_argument("--apply", action="store_true"); p.set_defaults(fn=cmd_land)
    p = sub.add_parser("approve"); p.add_argument("--apply", action="store_true"); p.set_defaults(fn=cmd_approve)
    p = sub.add_parser("reject"); p.add_argument("--apply", action="store_true"); p.set_defaults(fn=cmd_reject)
    p = sub.add_parser("trust"); p.add_argument("--threshold", type=int, default=None); p.set_defaults(fn=cmd_trust)
    p = sub.add_parser("revert"); p.add_argument("--n", type=int, default=1); p.add_argument("--apply", action="store_true"); p.set_defaults(fn=cmd_revert)
    p = sub.add_parser("list"); p.set_defaults(fn=cmd_list)
    p = sub.add_parser("catalog"); p.add_argument("--check-assets", action="store_true"); p.set_defaults(fn=cmd_catalog)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
