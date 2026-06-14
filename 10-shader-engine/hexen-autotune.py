#!/usr/bin/env python3
"""Autonomous driver for the hexen refinement loop — a local vision model runs it itself.

This is the "ongoing-basis" capability: one vision model both PROPOSES the next knob to
turn (looking at the current best render) and JUDGES the result, so the see-and-adjust
loop runs with no human in the loop. Each iteration:

  1. PROPOSE — show the model `baseline.png` (current best) + the live knob values +
     ranges + the rubric; it returns ONE {knob, value, goal} to try.
  2. APPLY   — `hexen-tune.py set knob=value` (clamped again there + in the renderer).
  3. CAPTURE — `hexen-tune.py capture` (re-reads the JSON; NO compile).
  4. JUDGE   — `hexen-vision-judge.py` compares baseline vs the new frame (exit 0=better).
  5. KEEP|REVERT — `hexen-tune.py accept` (ledger + promote baseline) or `revert`.

It only ORCHESTRATES the three single-purpose tools (compose, don't reimplement), so the
guardrails live in one place: clamp, one knob per iteration, revert on regression, ledger
every accept, last-good capture stays the baseline. A bad proposal is harmless — it gets
clamped, rendered, judged, and reverted. The model is the search + the eyes; the tooling
is the safety rail.

PROPOSER vs JUDGE are SEPARATE models on purpose. The proposer just needs sensible ideas
(gemma4-64k is fine, and fast). The JUDGE is the integrity-critical role: verified
2026-06-14, gemma4-64k rubber-stamps ("better @0.95" even on a worse frame) while
qwen3.6-27b-64k discriminates — so the judge defaults to qwen. A confabulating judge makes
the loop accept noise; never trust a judge model you haven't checked against a worse pair.

Usage:
    hexen-autotune.py --iterations 3 [--model gemma4-64k:latest]
        [--judge-model qwen3.6-27b-64k:latest] [--cam C] [--dry-propose]
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
TUNE = HERE / "hexen-tune.py"
JUDGE = HERE / "hexen-vision-judge.py"
STATE = Path.home() / ".nimbus" / "hexen-tune"
BASELINE = STATE / "baseline.png"
LASTGOOD = STATE / "last-good.json"
OLLAMA = "http://localhost:11434/api/chat"

RUBRIC = """\
Torch-lit gothic dungeon corridor (Hexen mood). "Better" =
- depth/contrast: warm torch pools vs cool shadow, real dark<->bright range, never one flat hue;
- material richness: brick/stone relief visible (grazing speculars + parallax), not matte-flat;
- composition: the hall leads to the far focal shrine; foreground dressed; props hug the walls;
- mood: torch-lit gothic; fog atmospheric but not curtaining; far end melts to dark;
- no artifacts: no smear/swim, no blown bloom, no washed-out or crushed-to-black loss of detail."""


def ollama_chat(model, prompt, images, temperature, timeout):
    body = {"model": model, "stream": False, "options": {"temperature": temperature},
            "messages": [{"role": "user", "content": prompt, "images": images}]}
    req = urllib.request.Request(OLLAMA, data=json.dumps(body).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8")).get("message", {}).get("content", "")


def parse_obj(text, required_key):
    for cand in (text, *re.findall(r"\{.*?\}", text, re.DOTALL)):
        try:
            o = json.loads(cand)
            if isinstance(o, dict) and required_key in o:
                return o
        except Exception:
            continue
    return None


def run(cmd):
    """Run a sibling tool, echoing its output; return (rc, stdout)."""
    p = subprocess.run([sys.executable, *cmd], capture_output=True, text=True)
    out = (p.stdout or "") + (p.stderr or "")
    for line in out.splitlines():
        print("    | " + line)
    return p.returncode, p.stdout or ""


def knob_surface():
    p = subprocess.run([sys.executable, str(TUNE), "knobs"], capture_output=True, text=True)
    return json.loads(p.stdout)


def propose(model, knobs, current, history, timeout):
    hist = "\n".join(
        f"- {h['knob']} -> {h['to']}: {'KEPT' if h['kept'] else 'REVERTED'} ({h['reason']})"
        for h in history[-5:]) or "(none yet)"
    ranges = {k: [v["lo"], v["hi"]] for k, v in knobs.items()}
    prompt = (
        "You are tuning a torch-lit gothic-dungeon corridor wallpaper. The attached image is "
        "the CURRENT BEST render. Propose ONE knob change that would most improve it.\n\n"
        f"Rubric:\n{RUBRIC}\n\n"
        f"Current knob values:\n{json.dumps(current)}\n\n"
        f"Allowed knobs and [min,max] (stay strictly inside, and pick a SMALL step):\n"
        f"{json.dumps(ranges)}\n\n"
        f"Recent attempts (don't repeat a reverted one):\n{hist}\n\n"
        'Respond with ONLY JSON: {"knob":"<allowed name>","value":<number in range>,'
        '"goal":"<one sentence on what you are improving>"}')
    raw = ollama_chat(model, prompt, [base64.b64encode(BASELINE.read_bytes()).decode()],
                      temperature=0.6, timeout=timeout)
    return parse_obj(raw, "knob"), raw


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iterations", type=int, default=3)
    ap.add_argument("--model", default="gemma4-64k:latest",
                    help="PROPOSER model (sensible ideas; fast is fine)")
    ap.add_argument("--judge-model", default="qwen3.6-27b-64k:latest",
                    help="JUDGE model — MUST discriminate (qwen3.6-27b does; gemma4-64k rubber-stamps)")
    ap.add_argument("--cam", default="")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--knobs", default="",
                    help="comma-separated subset the proposer may pick; overrides the "
                         "path-based default selection below")
    ap.add_argument("--rt", action="store_true",
                    help="tune + JUDGE the RT (Solari) path the LIVE wallpaper actually runs "
                         "(captures with --rt, re-establishes an RT baseline, and restricts "
                         "knobs to RT-relevant ones). Default: the raster preview path.")
    ap.add_argument("--dry-propose", action="store_true",
                    help="only print proposals; don't set/capture/judge/accept")
    args = ap.parse_args()

    if not BASELINE.exists():
        print(f"error: no baseline at {BASELINE}. Run `hexen-tune.py capture && accept` "
              "to establish one first.", file=sys.stderr)
        return 1
    knobs = knob_surface()
    if args.knobs:
        want = [k.strip() for k in args.knobs.split(",") if k.strip()]
        bad = [k for k in want if k not in knobs]
        if bad:
            print(f"error: unknown knob(s) in --knobs: {bad}. known: {', '.join(knobs)}",
                  file=sys.stderr)
            return 2
        knobs = {k: knobs[k] for k in want}
        print(f"proposer restricted to: {', '.join(knobs)}")
    else:
        # Only propose knobs that move the path we're judging — a knob that's a no-op on the
        # judged path is noise the judge can't attribute. RT tunes both-path + rt-only;
        # raster tunes both-path + raster-only.
        want_paths = {"both", "rt"} if args.rt else {"both", "raster"}
        knobs = {k: v for k, v in knobs.items() if v.get("path", "both") in want_paths}
        print(f"{'RT (Solari)' if args.rt else 'raster'} mode: tuning {', '.join(knobs)}")

    if args.rt and not args.dry_propose:
        # The judge compares baseline.png vs the new frame; both MUST be the SAME render path,
        # else it's grading RT-vs-raster. Re-establish baseline.png as an RT capture first.
        print("RT mode: re-establishing baseline.png as an RT capture (apples-to-apples) …")
        rc, _ = run([str(TUNE), "capture", "--rt", "--label", "rt-baseline"])
        rtb = STATE / "captures" / "rt-baseline.png"
        if rc != 0 or not rtb.exists():
            print("  error: RT baseline capture failed — aborting (won't judge RT vs raster).",
                  file=sys.stderr)
            return 1
        run([str(TUNE), "accept", "--capture", str(rtb), "-m", "RT baseline (autotune --rt)"])
    history = []

    for i in range(1, args.iterations + 1):
        print(f"\n=== iteration {i}/{args.iterations} ===")
        current = json.loads(LASTGOOD.read_text())
        try:
            prop, raw = propose(args.model, knobs, current, history, args.timeout)
        except Exception as e:
            print(f"  propose: model call failed ({e}); skipping iteration")
            continue
        if not prop:
            print(f"  propose: unparseable ({raw[:160]!r}); skipping")
            continue
        knob, val, goal = prop.get("knob"), prop.get("value"), prop.get("goal", "")
        if knob not in knobs:
            print(f"  propose: unknown knob {knob!r}; skipping")
            continue
        try:
            val = float(val)
        except (TypeError, ValueError):
            print(f"  propose: non-numeric value {val!r}; skipping")
            continue
        lo, hi = knobs[knob]["lo"], knobs[knob]["hi"]
        val = max(lo, min(hi, val))
        if abs(val - float(current.get(knob, knobs[knob]["default"]))) < 1e-9:
            print(f"  propose: {knob}={val} is already current; skipping (no-op)")
            continue
        print(f"  PROPOSE: {knob} -> {val}  — {goal}")
        if args.dry_propose:
            history.append({"knob": knob, "to": val, "kept": False, "reason": "dry-propose"})
            continue

        run([str(TUNE), "set", f"{knob}={val}", "-m", goal])
        label = f"auto-{i}-{knob}"
        cap_cmd = [str(TUNE), "capture", "--label", label]
        if args.rt:
            cap_cmd.append("--rt")
        if args.cam:
            cap_cmd += ["--cam", args.cam]
        rc, _ = run(cap_cmd)
        cap_path = STATE / "captures" / f"{label}.png"
        if rc != 0 or not cap_path.exists():
            print("  capture failed; reverting")
            run([str(TUNE), "revert"])
            history.append({"knob": knob, "to": val, "kept": False, "reason": "capture failed"})
            continue

        rc, jout = run([str(JUDGE), "--before", str(BASELINE), "--after", str(cap_path),
                        "--goal", goal, "--model", args.judge_model])
        verdict = parse_obj(jout, "better") or {}
        better = rc == 0 and verdict.get("better") is True
        reason = verdict.get("reason", "no reason")
        if better:
            print(f"  JUDGE: BETTER — {reason} -> ACCEPT")
            run([str(TUNE), "accept", "-m", f"auto: {goal} ({args.model}: {reason})",
                 "--capture", str(cap_path)])
        else:
            print(f"  JUDGE: not better — {reason} -> REVERT")
            run([str(TUNE), "revert"])
        history.append({"knob": knob, "to": val, "kept": better, "reason": reason})

    print("\n=== autotune summary ===")
    kept = [h for h in history if h["kept"]]
    for h in history:
        print(f"  {'KEEP ' if h['kept'] else 'drop '} {h['knob']} -> {h['to']}  ({h['reason']})")
    print(f"{len(kept)}/{len(history)} kept. Final last-good: {LASTGOOD}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
