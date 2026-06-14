#!/usr/bin/env python3
"""Offline tests for the composer — no Ollama, no GPU. The model call is injected as a
fake, so the whole assemble→validate→retry loop is deterministic. Run: `python3 test_compose.py`.
"""
from __future__ import annotations

import json
from datetime import datetime

import collect_digest
import compose
import dreamlib

CATALOG = dreamlib.load_catalog(compose.HERE / "catalog.json")

PREV = {
    "id": "leg-003",
    "theme": {"palette": ["#2a1d12"], "motif": "warm shrine"},
    "entry": {"at": [0, 2.6, 0], "forward": [0, 0, -1], "aperture": [6.0, 5.2]},
    "exit": {"at": [0, 2.6, -48], "forward": [0, 0, -1], "aperture": [6.0, 5.2]},
    "geometry": [{"kind": "corridor", "length": 48, "floor": "castle_wall_slates",
                  "ceiling": "medieval_blocks_02", "wall": "castle_brick_07", "trim": "castle_wall_slates"}],
}

GOOD_JSON = json.dumps({
    "theme": {"palette": ["#201", "#a63", "#79c"], "motif": "a sunken archive", "mood": "focused"},
    "geometry": [{"kind": "corridor", "length": 52, "floor": "medieval_blocks_02",
                  "ceiling": "castle_wall_slates", "wall": "castle_brick_07", "trim": "castle_wall_slates",
                  "col_spacing": 8, "torch_color": [1, 0.5, 0.2]}],
    "props": [{"model": "wooden_crate_01", "pos": [2.2, 0, -12], "rot_y": 0.4}],
    "lights": [{"kind": "glow", "pos": [-2, 1.2, -20], "color": [1, 0.6, 0.3], "intensity": 30000, "range": 7}],
    "atmosphere": {"fog_density": 0.008, "ambient_brightness": 40},
})

DIGEST = collect_digest.build_digest(datetime(2026, 6, 15, 23, 0), 7, ["feat: x", "fix: y"], ["nimbus"], 3, False)

_results: list[tuple[str, bool, str]] = []


def check(name, cond, detail=""):
    _results.append((name, bool(cond), detail))


def test_build_digest_shape():
    d = DIGEST
    check("digest has date/intensity/git", d["date"] == "2026-06-15" and d["intensity"] == "busy" and d["git"]["commits"] == 7)
    check("digest part_of_day computed", d["part_of_day"] == "night")


def test_extract_json_variants():
    check("plain json", compose.extract_json('{"a":1}') == {"a": 1})
    check("fenced json", compose.extract_json('```json\n{"a":2}\n```') == {"a": 2})
    check("think-wrapped", compose.extract_json('<think>hmm let me think</think>{"a":3}') == {"a": 3})
    check("prose-wrapped", compose.extract_json('Sure! Here is the leg:\n{"a":4}\nHope that helps.') == {"a": 4})
    check("nested object", compose.extract_json('noise {"a":{"b":5}} trailing') == {"a": {"b": 5}})
    check("no json → None", compose.extract_json("no object here") is None)


def test_prompt_is_grounded():
    msgs = compose.build_prompt(DIGEST, PREV, CATALOG)
    user = msgs[-1]["content"]
    for sid in CATALOG["stone"]:
        check(f"prompt lists stone {sid}", sid in user)
    check("prompt lists a model id", "marble_bust_01" in user)
    check("prompt carries prev motif", "warm shrine" in user)
    check("prompt carries today's signal", "7" in user and "busy" in user)


def test_compose_good():
    res = compose.compose(lambda m: GOOD_JSON, DIGEST, PREV, CATALOG, PREV["exit"], retries=2)
    check("good model composes ok", res["ok"], res.get("reason", ""))
    cand = res.get("candidate", {})
    check("seed_from = prev id", cand.get("seed_from") == "leg-003")
    check("portals forced (entry aperture == prev exit)", cand["entry"]["aperture"] == [6.0, 5.2])
    check("cross-section constant (exit aperture == prev)", cand["exit"]["aperture"] == [6.0, 5.2])
    check("model length flowed through", abs(cand["geometry"][0]["length"] - 52.0) < 1e-6)
    check("validated candidate carries the prop", any(p["model"] == "wooden_crate_01" for p in cand["props"]))


def test_compose_seam_safe_even_if_model_changes_width():
    weird = json.loads(GOOD_JSON)
    weird["geometry"][0]["width"] = 12  # model tries to change the cross-section
    res = compose.compose(lambda m: json.dumps(weird), DIGEST, PREV, CATALOG, PREV["exit"], retries=2)
    check("width override ignored → seam stays valid", res["ok"] and res["candidate"]["geometry"][0]["width"] == 6.0)


def test_compose_retries_on_bad_then_good():
    calls = {"n": 0}

    def flaky(_messages):
        calls["n"] += 1
        return "I think the corridor should be cozy." if calls["n"] == 1 else GOOD_JSON

    res = compose.compose(flaky, DIGEST, PREV, CATALOG, PREV["exit"], retries=3)
    check("recovers on retry after non-JSON", res["ok"] and res["attempts"] == 2)


def test_compose_drops_unknown_prop():
    m = json.loads(GOOD_JSON)
    m["props"].append({"model": "spaceship_42", "pos": [2, 0, -30]})
    res = compose.compose(lambda _m: json.dumps(m), DIGEST, PREV, CATALOG, PREV["exit"], retries=2)
    models = [p["model"] for p in res["candidate"]["props"]]
    check("unknown prop dropped by guardrails", "spaceship_42" not in models and "wooden_crate_01" in models)


def test_date_seed_deterministic():
    s1 = compose.date_seed("2026-06-14")
    s2 = compose.date_seed("2026-06-14")
    s3 = compose.date_seed("2026-06-15")
    check("seed stable for a given date", s1 == s2)
    check("seed differs across dates", s1 != s3)
    check("seed is a 32-bit int", isinstance(s1, int) and 0 <= s1 <= 0xFFFFFFFF)


def test_compose_stamps_date_seed():
    res = compose.compose(lambda m: GOOD_JSON, DIGEST, PREV, CATALOG, PREV["exit"], retries=2)
    check("leg carries the date seed", res["candidate"].get("seed") == compose.date_seed(DIGEST["date"]))


def main() -> int:
    for fn in sorted(k for k in globals() if k.startswith("test_")):
        try:
            globals()[fn]()
        except Exception as e:
            _results.append((fn, False, f"raised {type(e).__name__}: {e}"))
    passed = sum(1 for _, ok, _ in _results if ok)
    for name, ok, detail in _results:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if (detail and not ok) else ""))
    print(f"\n{passed}/{len(_results)} checks passed")
    return 0 if passed == len(_results) else 1


if __name__ == "__main__":
    import sys
    sys.exit(main())
