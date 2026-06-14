#!/usr/bin/env python3
"""Offline adversarial tests for dream-apply.py — the dreaming guardrail.

No GPU, no Ollama, no system signals: pure Python over JSON against a temp
NIMBUS_DREAM_HOME + a temp journey dir seeded with leg-000/leg-001. Each test
feeds a knobs file and asserts on the result/ledger and the (non-)written leg.
The point: a bad manifest is dropped/clamped/rejected and NEVER reaches a live
leg. Exit 0 = all pass.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
APPLY = HERE.parent / "skill" / "scripts" / "dream-apply.py"
CATALOG = HERE.parent / "catalog.json"

RESULTS = []


def seed_leg(i):
    return {
        "id": f"leg-{i:03d}",
        "seed_from": None if i == 0 else f"leg-{i-1:03d}",
        "day": "seed",
        "entry": {"at": [0.0, 2.6, 0.0], "forward": [0.0, 0.0, -1.0], "up": [0.0, 1.0, 0.0], "aperture": [6.0, 5.2]},
        "exit": {"at": [0.0, 2.6, -48.0], "forward": [0.0, 0.0, -1.0], "up": [0.0, 1.0, 0.0], "aperture": [6.0, 5.2]},
        "geometry": [{"kind": "corridor", "length": 48.0, "width": 6.0, "height": 5.2,
                      "floor": "medieval_blocks_02", "ceiling": "castle_wall_slates",
                      "wall": "castle_brick_07", "trim": "castle_wall_slates"}],
    }


def valid_knobs(**over):
    k = {"mood": "calm", "palette_direction": "warmer", "motif": "deep_vault",
         "density": 0.6, "length_bias": 0.5, "light_bias": 0.5, "seed": 12345,
         "seed_from": "leg-001",
         "props": [{"id": "treasure_chest", "hint": "mid"}, {"id": "rock_07", "hint": "far"}],
         "rationale": "a productive, calm day", "confidence": 0.8}
    k.update(over)
    return k


def fresh():
    """(home, journey_dir) with leg-000 + leg-001 seeded."""
    home = Path(tempfile.mkdtemp(prefix="dreamhome-"))
    journey = Path(tempfile.mkdtemp(prefix="journey-"))
    for i in (0, 1):
        (journey / f"leg-{i:03d}.json").write_text(json.dumps(seed_leg(i)), encoding="utf-8")
    return home, journey


def run(home, journey, args, knobs=None, raw_knobs=None):
    """Run the applier; return its result dict. --journey-dir is always supplied
    (harmless for --revert, which derives the dir from the backup manifest)."""
    extra = []
    if knobs is not None or raw_knobs is not None:
        kf = home / "knobs.json"
        kf.write_text(raw_knobs if raw_knobs is not None else json.dumps(knobs), encoding="utf-8")
        extra = ["--knobs", str(kf)]
    env = dict(os.environ, NIMBUS_DREAM_HOME=str(home))
    r = subprocess.run([sys.executable, str(APPLY), "--catalog", str(CATALOG),
                        "--journey-dir", str(journey), *extra, *args],
                       capture_output=True, text=True, env=env)
    try:
        out = json.loads(r.stdout)
    except Exception:
        out = {"_stdout": r.stdout, "_stderr": r.stderr, "_rc": r.returncode}
    return out


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  — {detail}" if (detail and not cond) else ""))


def staged_leg(home, leg_id):
    p = home / "staging" / f"{leg_id}.json"
    return json.loads(p.read_text()) if p.exists() else None


def live_leg(journey, leg_id):
    p = journey / f"{leg_id}.json"
    return json.loads(p.read_text()) if p.exists() else None


def valid_leg_shape(leg):
    g = (leg.get("geometry") or [{}])[0]
    return (leg.get("id") and leg.get("entry") and leg.get("exit")
            and g.get("kind") == "corridor"
            and all(g.get(k) for k in ("floor", "ceiling", "wall", "trim")))


# ---------------------------------------------------------------------------

def t_stage_when_unearned():
    home, journey = fresh()
    res = run(home, journey, ["--apply"], knobs=valid_knobs())
    check("stage-when-unearned: status", res.get("status") == "staged", res)
    leg = staged_leg(home, "leg-002")
    check("stage-when-unearned: staged file valid", leg and valid_leg_shape(leg))
    check("stage-when-unearned: NOT written live", live_leg(journey, "leg-002") is None)


def t_drop_hallucinated_prop():
    home, journey = fresh()
    k = valid_knobs(props=[{"id": "dragon_hoard_99"}, {"id": "treasure_chest"}])
    res = run(home, journey, ["--apply"], knobs=k)
    leg = staged_leg(home, "leg-002")
    models = [p["model"] for p in (leg.get("props") or [])] if leg else []
    check("hallucinated-prop: dropped from leg", "dragon_hoard_99" not in models, models)
    check("hallucinated-prop: real prop kept", "treasure_chest" in models, models)
    check("hallucinated-prop: noted", any("dragon_hoard_99" in n for n in res.get("notes", [])), res.get("notes"))


def t_clamp_out_of_bounds():
    home, journey = fresh()
    k = valid_knobs(length_bias=50, density=9, light_bias=-3)
    run(home, journey, ["--apply"], knobs=k)
    leg = staged_leg(home, "leg-002")
    g = leg["geometry"][0]
    a = leg["atmosphere"]
    check("clamp: length 32..64", 32.0 <= g["length"] <= 64.0, g["length"])
    check("clamp: col_spacing 4..10", 4.0 <= g["col_spacing"] <= 10.0, g["col_spacing"])
    check("clamp: moon 400..1400", 400.0 <= a["moon_illuminance"] <= 1400.0, a["moon_illuminance"])
    check("clamp: ambient 25..80", 25.0 <= a["ambient_brightness"] <= 80.0, a["ambient_brightness"])


def t_reject_broken_chaining():
    home, journey = fresh()
    res = run(home, journey, ["--apply"], knobs=valid_knobs(seed_from="leg-999"))
    check("broken-chain: rejected-drift", res.get("status") == "rejected-drift", res)
    check("broken-chain: nothing staged", staged_leg(home, "leg-002") is None)
    check("broken-chain: nothing live", live_leg(journey, "leg-002") is None)


def t_enum_violation():
    home, journey = fresh()
    res = run(home, journey, ["--apply"], knobs=valid_knobs(motif="dragon_lair"))
    check("enum: bad motif rejected", res.get("status") == "rejected-malformed", res)
    res2 = run(home, journey, ["--apply"], knobs=valid_knobs(mood="hangry"))
    check("enum: bad mood rejected", res2.get("status") == "rejected-malformed", res2)


def t_prose_wrapped_and_malformed():
    home, journey = fresh()
    good = json.dumps(valid_knobs())
    res = run(home, journey, ["--apply"], raw_knobs=f"Sure! Here is the leg:\n{good}\nHope that helps!")
    check("prose-wrapped: parsed + staged", res.get("status") == "staged", res)
    home2, journey2 = fresh()
    res2 = run(home2, journey2, ["--apply"], raw_knobs="this is not json at all <<<")
    check("malformed: rejected", str(res2.get("status", "")).startswith("rejected"), res2)


def t_earned_via_approve():
    home, journey = fresh()
    run(home, journey, ["--apply"], knobs=valid_knobs())                 # stages leg-002
    run(home, journey, ["--approve", "leg-002", "--journey-dir", str(journey)])
    check("approve: leg-002 now live", live_leg(journey, "leg-002") is not None)
    ledger = (home / "ledger.jsonl").read_text() if (home / "ledger.jsonl").exists() else ""
    check("approve: ledgered accepted", '"accepted"' in ledger)
    # now earned: a confident leg chaining from leg-002 auto-applies live
    res = run(home, journey, ["--apply"], knobs=valid_knobs(seed_from="leg-002", seed=77))
    check("earned: auto-applied live", res.get("status") == "applied", res)
    check("earned: leg-003 live", live_leg(journey, "leg-003") is not None)


def t_revert_and_drop_last():
    home, journey = fresh()
    (home / "ledger.jsonl").write_text(json.dumps({"status": "accepted"}) + "\n")  # pre-earn
    res = run(home, journey, ["--apply"], knobs=valid_knobs())            # applied live leg-002
    check("revert-setup: applied", res.get("status") == "applied", res)
    rid = res.get("run_id")
    run(home, journey, ["--revert", rid])
    check("revert: leg-002 gone after --revert", live_leg(journey, "leg-002") is None)
    # re-apply then drop-last
    res2 = run(home, journey, ["--apply"], knobs=valid_knobs(seed=9))
    check("drop-setup: re-applied", res2.get("status") == "applied", res2)
    run(home, journey, ["--drop-last", "1", "--journey-dir", str(journey)])
    check("drop-last: leg-002 gone", live_leg(journey, "leg-002") is None)
    check("drop-last: leg-001 retained", live_leg(journey, "leg-001") is not None)


def t_quiet_day_defaults():
    home, journey = fresh()
    # minimal knobs: only the required seed_from + a seed; everything else defaults
    res = run(home, journey, ["--apply"], knobs={"seed_from": "leg-001", "seed": 3})
    check("quiet-day: staged (no confidence)", res.get("status") == "staged", res)
    leg = staged_leg(home, "leg-002")
    check("quiet-day: valid conservative leg", leg and valid_leg_shape(leg))
    if leg:
        check("quiet-day: default motif", leg["theme"]["motif"] == "gothic_nave", leg["theme"])


def main():
    print("dream-apply guardrail — offline adversarial tests")
    for t in (t_stage_when_unearned, t_drop_hallucinated_prop, t_clamp_out_of_bounds,
              t_reject_broken_chaining, t_enum_violation, t_prose_wrapped_and_malformed,
              t_earned_via_approve, t_revert_and_drop_last, t_quiet_day_defaults):
        t()
    passed = sum(1 for _, ok, _ in RESULTS if ok)
    total = len(RESULTS)
    print(f"\n{passed}/{total} checks passed")
    fails = [(n, d) for n, ok, d in RESULTS if not ok]
    if fails:
        print("FAILURES:")
        for n, d in fails:
            print(f"  - {n}: {d}")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
