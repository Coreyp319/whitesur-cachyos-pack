#!/usr/bin/env python3
"""Offline tests for the dreaming-journey guardrails — no engine, no GPU.

Validator unit tests (a bad manifest is rejected / clamped / dropped) plus an
accept→revert round-trip through the real CLI. Run: `python3 test_dream.py` (exit 0 = pass).
"""
from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import dreamlib

HERE = Path(__file__).resolve().parent
CATALOG = dreamlib.load_catalog(HERE / "catalog.json")
DREAM = HERE / "dream.py"

GOOD = {
    "id": "leg-test",
    "seed_from": "leg-000",
    "entry": {"at": [0.0, 2.6, 0.0], "forward": [0.0, 0.0, -1.0], "aperture": [6.0, 5.2]},
    "exit": {"at": [0.0, 2.6, -48.0], "forward": [0.0, 0.0, -1.0], "aperture": [6.0, 5.2]},
    "geometry": [{
        "kind": "corridor", "length": 48.0, "width": 6.0, "height": 5.2,
        "floor": "medieval_blocks_02", "ceiling": "castle_wall_slates",
        "wall": "castle_brick_07", "trim": "castle_wall_slates",
    }],
    "props": [{"model": "marble_bust_01", "pos": [-2.3, 1.2, -22.0], "scale": 1.6}],
    "lights": [{"kind": "key", "pos": [-1.8, 2.8, -22.0], "color": [1.0, 0.72, 0.42], "intensity": 60000, "range": 10.0}],
    "atmosphere": {"fog_density": 0.007, "ambient_brightness": 42.0},
}


def _has(issues, level, field_sub):
    return any(i["level"] == level and field_sub in i["field"] for i in issues)


_results: list[tuple[str, bool, str]] = []


def check(name, cond, detail=""):
    _results.append((name, bool(cond), detail))


def test_good_leg_passes():
    r = dreamlib.validate_leg(copy.deepcopy(GOOD), CATALOG, None)
    check("good leg accepted", r["ok"] and not r["rejected"], r.get("reason", ""))
    check("good leg has no reject issue", not _has(r["issues"], "reject", ""))


def test_unknown_kind_rejected():
    m = copy.deepcopy(GOOD)
    m["geometry"][0]["kind"] = "teleporter"
    r = dreamlib.validate_leg(m, CATALOG, None)
    check("unknown geometry kind rejected", r["rejected"], r.get("reason", ""))


def test_unknown_model_dropped():
    m = copy.deepcopy(GOOD)
    m["props"].append({"model": "dragon_99", "pos": [2.0, 0.0, -10.0]})
    r = dreamlib.validate_leg(m, CATALOG, None)
    check("unknown model → not rejected", r["ok"])
    check("unknown model dropped (issue)", _has(r["issues"], "drop", "props.model"))
    check("unknown model gone from sanitized", len(r["sanitized"]["props"]) == 1)


def test_unknown_stone_substituted():
    m = copy.deepcopy(GOOD)
    m["geometry"][0]["wall"] = "marble_unobtainium"
    r = dreamlib.validate_leg(m, CATALOG, None)
    check("unknown stone → not rejected", r["ok"])
    check("unknown stone substituted (issue)", _has(r["issues"], "drop", "geometry.wall"))
    check("sanitized wall is a catalog stone", r["sanitized"]["geometry"][0]["wall"] in CATALOG["stone"])


def test_bounds_clamped():
    m = copy.deepcopy(GOOD)
    m["props"][0]["scale"] = 99.0
    m["lights"][0]["intensity"] = 9_000_000_000.0
    m["atmosphere"]["fog_density"] = 0.9
    m["geometry"][0]["length"] = 9999.0
    r = dreamlib.validate_leg(m, CATALOG, None)
    check("over-scale clamped", r["sanitized"]["props"][0]["scale"] <= 6.0 and _has(r["issues"], "clamp", "props.scale"))
    check("runaway intensity clamped", r["sanitized"]["lights"][0]["intensity"] <= 400000.0)
    check("fog clamped", r["sanitized"]["atmosphere"]["fog_density"] <= 0.05)
    check("corridor length clamped", r["sanitized"]["geometry"][0]["length"] <= 120.0)


def test_aperture_matched_to_corridor():
    m = copy.deepcopy(GOOD)
    m["entry"]["aperture"] = [10.0, 9.0]  # inconsistent with 6×5.2 corridor
    r = dreamlib.validate_leg(m, CATALOG, None)
    check("inconsistent aperture clamped to cross-section", r["sanitized"]["entry"]["aperture"] == [6.0, 5.2])


def test_seam_mismatch_rejected():
    prev_exit = {"at": [0, 2.6, -48], "forward": [0, 0, -1], "aperture": [8.0, 6.0]}
    r = dreamlib.validate_leg(copy.deepcopy(GOOD), CATALOG, prev_exit)
    check("seam aperture mismatch rejected", r["rejected"], r.get("reason", ""))


def test_missing_portal_rejected():
    m = copy.deepcopy(GOOD)
    del m["entry"]
    r = dreamlib.validate_leg(m, CATALOG, None)
    check("missing entry portal rejected", r["rejected"])


def test_accept_revert_round_trip():
    with tempfile.TemporaryDirectory() as td:
        jdir = Path(td)
        # seed leg-000
        seed = copy.deepcopy(GOOD)
        seed["id"] = "leg-000"
        seed["seed_from"] = None
        (jdir / "leg-000.json").write_text(json.dumps(seed), encoding="utf-8")
        # candidate continuation
        cand = jdir / "candidate.json"
        cand.write_text(json.dumps(GOOD), encoding="utf-8")

        def run(*a):
            return subprocess.run([sys.executable, str(DREAM), "--journey", str(jdir), *a],
                                  capture_output=True, text=True)

        # dry-run accept writes nothing
        run("accept", str(cand))
        check("dry-run writes no leg", not (jdir / "leg-001.json").exists())
        # apply
        r = run("accept", str(cand), "--apply")
        check("accept --apply rc=0", r.returncode == 0, r.stderr)
        check("leg-001 written", (jdir / "leg-001.json").exists())
        check("ledger records the apply", "applied" in (jdir / "ledger.jsonl").read_text())
        # revert drops it
        r = run("revert", "--apply")
        check("revert --apply rc=0", r.returncode == 0, r.stderr)
        check("leg-001 removed", not (jdir / "leg-001.json").exists())
        # leg-000 (seed) is protected
        r = run("revert", "--apply")
        check("seed leg-000 protected from revert", (jdir / "leg-000.json").exists())


def main() -> int:
    for fn in sorted(k for k in globals() if k.startswith("test_")):
        try:
            globals()[fn]()
        except Exception as e:  # a thrown test = a failure, not a crash
            _results.append((fn, False, f"raised {type(e).__name__}: {e}"))
    passed = sum(1 for _, ok, _ in _results if ok)
    for name, ok, detail in _results:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if (detail and not ok) else ""))
    print(f"\n{passed}/{len(_results)} checks passed")
    return 0 if passed == len(_results) else 1


if __name__ == "__main__":
    sys.exit(main())
