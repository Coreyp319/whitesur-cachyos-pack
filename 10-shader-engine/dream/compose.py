#!/usr/bin/env python3
"""Model composer for the dreaming journey (handoff problems E + G).

A Layer-6 **local** model (Ollama, OpenAI-compatible `/v1`, **model-agnostic** — pick via
`NIMBUS_DREAM_MODEL`) dreams the *creative* half of a new leg from the day-digest + the
previous leg (inherit-and-evolve). The *mechanical* half — the entry/exit portals and the
seam-safe cross-section — is forced here, so continuity never depends on the model getting
geometry math right. The result is then run through the step-4 guardrails
(`dreamlib.validate_leg`): catalog-grounded, bounds-clamped, schema-valid, or it's rejected
and we **retry** with the reason fed back. Mirrors `6-local-ai/ui-audit/`: the model
proposes, the guardrails dispose.

Gotchas handled (see memory `local-ai-layer`): thinking models emit `<think>…</think>` /
prose around the JSON → tolerant extraction; Hermes-4 returns empty content on a small
`max_tokens` (reasoning eats the budget) → generous default; `/v1` ignores runtime num_ctx
→ default to a `-64k` baked model; validate + retry on a schema miss.

`compose(call_fn, …)` takes the model call as a parameter so the whole loop is testable
offline with a fake — no Ollama, no GPU.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional

import collect_digest
import dreamlib

HERE = Path(__file__).resolve().parent
# A SMALL model is the right composer: the guardrails (validate_leg) enforce integrity, so the
# model only needs sensible creative ideas — and a 14B fits alongside the live RT wallpaper on
# one GPU, where the 27B contends for VRAM (cold-load 500s / slow-gen timeouts). Override with
# $NIMBUS_DREAM_MODEL (any Ollama tag — it's model-agnostic).
DEFAULT_MODEL = "hermes4-14b:latest"
DEFAULT_URL = "http://localhost:11434/v1/chat/completions"
DEFAULT_CANDIDATE = Path("/tmp/nimbus-dream-candidate.json")


# --------------------------------------------------------------------------- #
# prompt
# --------------------------------------------------------------------------- #

SYSTEM = (
    "You compose ONE leg of an endless dream-corridor wallpaper. The corridor goes forward "
    "forever; your leg continues from the previous one — it INHERITS its palette, motif and "
    "materials but EVOLVES them: a slow drift, a recurring motif that transforms, architecture "
    "that opens up or tightens. Make the progression legible but never a jarring non-sequitur. "
    "Output ONLY a single JSON object — no prose, no markdown, no code fences."
)


def _signals_block(digest: dict) -> str:
    """Grounded, compact view of the day for the prompt. Prefers the rich collector's
    ``summary[]`` (curated, anti-confabulation lines), then always appends a small focus
    dict with the key dials. Stays correct for the flat (offline-test) digest too."""
    parts: list[str] = []
    summary = digest.get("summary")
    if summary:
        parts.append("grounded signals — cite ONLY these, do not invent activity:")
        parts.extend(f"  · {s}" for s in summary)
    g = digest.get("git", {}) or {}
    focus = {
        "date": digest.get("date"),
        "weekday": digest.get("weekday"),
        "part_of_day": digest.get("part_of_day"),
        "intensity": digest.get("intensity"),
        "commits": g.get("commits"),
        "music": "on" if digest.get("music_active") else "off",
    }
    if g.get("types"):
        focus["commit_types"] = g["types"]
    if g.get("scopes"):
        focus["scopes"] = g["scopes"][:6]
    if g.get("languages"):
        focus["languages"] = [l["lang"] for l in g["languages"][:5]]
    win = digest.get("windows", {})
    if isinstance(win, dict) and win.get("layout"):
        focus["workspace"] = win["layout"]
    parts.append("digest: " + json.dumps(focus))
    return "\n".join(parts)


def build_prompt(digest: dict, prev_leg: Optional[dict], catalog: dict, feedback: Optional[str] = None) -> list[dict]:
    stone = ", ".join(catalog.get("stone", {}))
    models = ", ".join(catalog.get("models", {}))
    lights = ", ".join(catalog.get("light_kinds", []))
    corr = catalog.get("geometry_kinds", {}).get("corridor", {}).get("params", {})
    rng = lambda k: f"{corr.get(k, {}).get('min')}..{corr.get(k, {}).get('max')}"  # noqa: E731

    prev_txt = json.dumps(prev_leg, indent=2) if prev_leg else "none — you are composing the first leg after the seed"

    user = f"""ALLOWED asset ids — use ONLY these, nothing else:
  stone (floor/ceiling/wall/trim): {stone}
  prop models: {models}
  geometry kind: corridor
  light kinds: {lights}

BOUNDS: corridor length {rng('length')}, col_spacing {rng('col_spacing')};
props scale 0.1..6, hug the walls (|x| >= 2) so they don't block the camera, scatter pos.z in 0..-length;
light intensity 0..400000, range 0.5..40; fog_density 0..0.05.

PREVIOUS leg (inherit its palette/motif/materials, then EVOLVE — do not copy verbatim):
{prev_txt}

TODAY'S signals — let them color the mood / motif / palette (e.g. a busy git day = a denser,
more wrought space; quiet = sparse and still; night = colder):
{_signals_block(digest)}

Compose the NEXT leg as JSON with this shape (you do NOT set entry/exit — continuity is handled):
{{
  "theme": {{ "palette": ["#..","#..","#.."], "motif": "<short>", "mood": "<short>" }},
  "geometry": [{{ "kind": "corridor", "length": <num>, "floor": "<stone>", "ceiling": "<stone>",
                  "wall": "<stone>", "trim": "<stone>", "col_spacing": <num>, "torch_color": [r,g,b] }}],
  "props":  [{{ "model": "<id>", "pos": [x,y,z], "rot_y": <num>, "scale": <num> }}],
  "lights": [{{ "kind": "key|glow", "pos": [x,y,z], "color": [r,g,b], "intensity": <num>, "range": <num> }}],
  "atmosphere": {{ "clear": [r,g,b], "fog_density": <num>, "fog_color": [r,g,b],
                   "ambient": [r,g,b], "ambient_brightness": <num>, "fog_volume_density": <num> }}
}}
Output ONLY the JSON object."""

    if feedback:
        user += f"\n\nYour previous attempt was REJECTED: {feedback}\nFix it and output ONLY valid JSON."

    return [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]


# --------------------------------------------------------------------------- #
# tolerant JSON extraction (small/thinking models wrap their output)
# --------------------------------------------------------------------------- #

def extract_json(text: str) -> Optional[dict]:
    if not text:
        return None
    # drop reasoning + code fences
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    text = text.replace("```json", "").replace("```", "")
    try:
        v = json.loads(text)
        return v if isinstance(v, dict) else None
    except Exception:
        pass
    # first balanced {...} object
    start = text.find("{")
    while start >= 0:
        depth = 0
        for i in range(start, len(text)):
            c = text[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    try:
                        v = json.loads(text[start:i + 1])
                        if isinstance(v, dict):
                            return v
                    except Exception:
                        pass
                    break
        start = text.find("{", start + 1)
    return None


# --------------------------------------------------------------------------- #
# assemble: force the mechanical/seam-safe parts around the model's creativity
# --------------------------------------------------------------------------- #

def date_seed(date_str: Optional[str]) -> int:
    """Stable 32-bit seed from the digest date (FNV-1a). Re-running a given day composes
    the same leg — best-effort for the model (via the `seed` option), exact for the
    assembled scaffolding — and gives future procedural geometry a deterministic base.
    No RNG, no clock."""
    h = 0x811c9dc5
    for b in (date_str or "0000-00-00").encode("utf-8"):
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h


def _num(v, default):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def assemble(raw: dict, prev_leg: Optional[dict], prev_exit: Optional[dict], catalog: dict, digest: dict, model: str, seed: int = 0) -> dict:
    """Wrap the model's creative output in a seam-safe leg: portals + a constant cross-section
    (so the join always validates), inheriting width/height from the previous exit aperture."""
    corr_p = catalog.get("geometry_kinds", {}).get("corridor", {}).get("params", {})
    len_lo, len_hi = corr_p.get("length", {}).get("min", 8), corr_p.get("length", {}).get("max", 120)

    # cross-section is kept constant across the journey → entry aperture always matches the
    # previous exit, so the seam can't step (width changes are a future "room"/transition kind).
    if prev_exit and isinstance(prev_exit.get("aperture"), list) and len(prev_exit["aperture"]) == 2:
        width, height = float(prev_exit["aperture"][0]), float(prev_exit["aperture"][1])
    else:
        width, height = 6.0, 5.2

    rg = next((g for g in (raw.get("geometry") or []) if isinstance(g, dict) and g.get("kind") == "corridor"), {})
    length = max(len_lo, min(len_hi, _num(rg.get("length"), 48.0)))
    default_stone = next(iter(catalog.get("stone", {})), "castle_brick_07")

    def stone(slot, fallback):
        v = rg.get(slot)
        return v if isinstance(v, str) else fallback

    prev_geo = ((prev_leg or {}).get("geometry") or [{}])[0]
    corridor = {
        "kind": "corridor",
        "length": length,
        "width": width,
        "height": height,
        "floor": stone("floor", prev_geo.get("floor", default_stone)),
        "ceiling": stone("ceiling", prev_geo.get("ceiling", default_stone)),
        "wall": stone("wall", prev_geo.get("wall", default_stone)),
        "trim": stone("trim", prev_geo.get("trim", default_stone)),
        "columns": True,
        "col_spacing": max(3.0, min(15.0, _num(rg.get("col_spacing"), 7.5))),
        "torch_color": rg.get("torch_color", [1.0, 0.55, 0.22]),
    }

    fwd = [0.0, 0.0, -1.0]
    ap = [width, height]
    leg = {
        "id": "candidate",
        "seed_from": (prev_leg or {}).get("id"),
        "seed": int(seed),
        "day": digest.get("date"),
        "theme": raw.get("theme", {}),
        "entry": {"at": [0.0, height / 2.0, 0.0], "forward": fwd, "up": [0.0, 1.0, 0.0], "aperture": ap},
        "exit": {"at": [0.0, height / 2.0, -length], "forward": fwd, "up": [0.0, 1.0, 0.0], "aperture": ap},
        "geometry": [corridor],
        "props": raw.get("props", []),
        "lights": raw.get("lights", []),
        "atmosphere": raw.get("atmosphere", {}),
        "provenance": {
            "from_signals": digest.get("summary") or [
                f"git: {digest.get('git', {}).get('commits', 0)} commits",
                f"intensity: {digest.get('intensity')}",
                f"music: {'on' if digest.get('music_active') else 'off'}",
                digest.get("part_of_day", ""),
            ],
            "model": model,
            "model_notes": (raw.get("theme", {}) or {}).get("motif", ""),
        },
    }
    return leg


# --------------------------------------------------------------------------- #
# the compose loop (model proposes → assemble → validate → retry)
# --------------------------------------------------------------------------- #

def compose(
    call_fn: Callable[[list[dict]], str],
    digest: dict,
    prev_leg: Optional[dict],
    catalog: dict,
    prev_exit: Optional[dict],
    model: str = DEFAULT_MODEL,
    retries: int = 3,
    seed: Optional[int] = None,
) -> dict:
    if seed is None:
        seed = date_seed(digest.get("date"))
    feedback = None
    last = {"ok": False, "reason": "no attempts made"}
    for attempt in range(1, retries + 1):
        try:
            content = call_fn(build_prompt(digest, prev_leg, catalog, feedback))
        except Exception as e:  # model/transport error → report, don't crash
            return {"ok": False, "reason": f"model call failed: {e}", "attempts": attempt}
        raw = extract_json(content)
        if raw is None:
            feedback = "Output was not valid JSON. Output ONLY a single JSON object, no prose."
            last = {"ok": False, "reason": "no JSON in model output", "attempts": attempt, "raw_text": content[:400]}
            continue
        candidate = assemble(raw, prev_leg, prev_exit, catalog, digest, model, seed)
        res = dreamlib.validate_leg(candidate, catalog, prev_exit)
        if not res["rejected"]:
            return {"ok": True, "candidate": res["sanitized"], "attempts": attempt, "issues": res["issues"]}
        feedback = res["reason"]
        last = {"ok": False, "reason": res["reason"], "attempts": attempt}
    return last


# --------------------------------------------------------------------------- #
# Ollama /v1 client (thin; not unit-tested — needs a server)
# --------------------------------------------------------------------------- #

def ollama_chat(messages: list[dict], model: str, max_tokens: int = 8000, temperature: float = 0.6,
                url: Optional[str] = None, timeout: int = 300, seed: Optional[int] = None,
                retries: int = 3) -> str:
    url = url or os.environ.get("NIMBUS_DREAM_URL", DEFAULT_URL)
    payload = {
        "model": model, "messages": messages, "temperature": temperature,
        "max_tokens": max_tokens, "stream": False,
    }
    if seed is not None:
        payload["seed"] = int(seed)  # best-effort reproducibility (honored by Ollama's /v1)
    body = json.dumps(payload).encode("utf-8")
    last: Exception | None = None
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = json.load(r)
            return data["choices"][0]["message"]["content"]
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError) as e:
            # Transient on a busy GPU: a model cold-load 500, a KV-cache OOM, or a slow-gen
            # timeout — the local model contends with the live RT wallpaper for VRAM. Back off
            # and retry; the nightly loop must not give up on the first hiccup.
            last = e
            if attempt < retries:
                time.sleep(5 * attempt)
    raise last


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def _newest_leg(jdir: Path) -> Optional[dict]:
    import re as _re
    best = None
    if jdir.is_dir():
        for p in jdir.iterdir():
            if _re.match(r"^leg-(\d+)\.json$", p.name):
                idx = int(p.name[4:-5])
                if best is None or idx > best[0]:
                    best = (idx, p)
    if best:
        try:
            return json.loads(best[1].read_text(encoding="utf-8"))
        except Exception:
            return None
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Compose the next dreaming-journey leg with a local model.")
    ap.add_argument("--model", default=os.environ.get("NIMBUS_DREAM_MODEL", DEFAULT_MODEL))
    ap.add_argument("--catalog", default=str(HERE / "catalog.json"))
    ap.add_argument("--journey", help="journey dir (default: $NIMBUS_FLUX_JOURNEY_DIR or ../nimbus-flux/journey)")
    ap.add_argument("--digest", help="day-digest JSON file (default: collect live)")
    ap.add_argument("--out", default=str(DEFAULT_CANDIDATE), help="where to write the candidate leg")
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--apply", action="store_true", help="also run dream.py accept --apply on success")
    args = ap.parse_args()

    catalog = dreamlib.load_catalog(args.catalog)
    jdir = Path(args.journey) if args.journey else Path(
        os.environ.get("NIMBUS_FLUX_JOURNEY_DIR", HERE.parent / "nimbus-flux" / "journey"))
    prev_leg = _newest_leg(jdir)
    prev_exit = (prev_leg or {}).get("exit")
    digest = json.loads(Path(args.digest).read_text()) if args.digest else collect_digest.collect()

    seed = date_seed(digest.get("date"))
    print(f"composing with {args.model} from digest "
          f"(git={digest.get('git', {}).get('commits')} commits, {digest.get('intensity')}, "
          f"{digest.get('part_of_day')}; seed={seed})")
    res = compose(lambda m: ollama_chat(m, args.model, seed=seed), digest, prev_leg, catalog, prev_exit,
                  model=args.model, retries=args.retries, seed=seed)

    if not res["ok"]:
        print(f"=> FAILED after {res.get('attempts', '?')} attempt(s): {res['reason']}")
        if res.get("raw_text"):
            print("   model said:", res["raw_text"])
        return 1

    Path(args.out).write_text(json.dumps(res["candidate"], indent=2) + "\n", encoding="utf-8")
    motif = (res["candidate"].get("theme", {}) or {}).get("motif", "")
    print(f"=> composed in {res['attempts']} attempt(s): {args.out}  (motif: {motif!r}; issues: {dreamlib.summarize_issues(res['issues'])})")

    if args.apply:
        print("   handing to dream.py accept --apply …")
        r = subprocess.run([sys.executable, str(HERE / "dream.py"), "--journey", str(jdir),
                            "accept", args.out, "--apply"], text=True)
        return r.returncode
    print("   dry-run: review it, then `dream.py accept` to land it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
