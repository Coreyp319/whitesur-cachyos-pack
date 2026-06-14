#!/usr/bin/env python3
"""Dreaming composer: day-digest + catalog → semantic *knobs* via a local model.

The model does INTERPRETATION only (turn "14 commits, late night, ambient music"
into mood/palette/motif/density/light). The grounding-critical fields are injected
by THIS harness, not trusted to the model:
  * `seed_from`  = the current last live leg id (so chaining validates; re-checked
                   by dream-apply at write time — catches a concurrent append).
  * `seed`       = derived deterministically from the date (replayable per night).

Discipline (from `local-ai-layer` + the research pass):
  * Ollama **/api/chat** (NOT /v1 — /v1 ignores runtime num_ctx) with the
    **`format`=JSON-schema** structured-output (enum-constrained to catalog ids).
  * Allowlist + enums also embedded **in the prompt** (belt-and-suspenders).
  * Generous tokens — Hermes-4 returns empty content on a tight budget (reasoning
    tokens); empty content triggers a retry.
  * Validate + repair loop. Output is still authoritatively validated by
    dream-apply.py — this only needs to be plausibly valid.
  * **Model name configurable** (--model / $NIMBUS_DREAM_MODEL), never hardcoded.

Usage:
    dream-compose.py --digest DIGEST.json --journey-dir .../journey [--model NAME]
                     [--out knobs.json] [--print] [--retries 2]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
RUNTIME = Path(os.environ.get("NIMBUS_DREAM_HOME", HOME / ".hermes" / "dreaming"))
KNOBS_OUT = RUNTIME / "knobs" / "knobs.json"
OLLAMA_URL = "http://localhost:11434/api/chat"
DEFAULT_MODEL = os.environ.get("NIMBUS_DREAM_MODEL", "gemma4-64k")

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CATALOG = SCRIPT_DIR.parent.parent / "catalog.json"

LEG_RE = re.compile(r"^leg-(\d+)\.json$")


def fnv1a(s: str) -> int:
    h = 0x811C9DC5
    for b in s.encode():
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h


def last_leg_id(journey_dir: Path) -> str | None:
    legs = []
    if journey_dir.exists():
        for p in journey_dir.iterdir():
            m = LEG_RE.match(p.name)
            if m:
                legs.append((int(m.group(1)), p))
    if not legs:
        return None
    _, p = sorted(legs)[-1]
    try:
        return json.loads(p.read_text()).get("id")
    except Exception:
        return None


def knob_schema(catalog):
    motifs = list(catalog["motifs"].keys())
    return {
        "type": "object",
        "properties": {
            "mood": {"type": "string", "enum": catalog["enums"]["mood"]},
            "palette_direction": {"type": "string", "enum": catalog["enums"]["palette_direction"]},
            "motif": {"type": "string", "enum": motifs},
            "density": {"type": "number"},
            "length_bias": {"type": "number"},
            "light_bias": {"type": "number"},
            "props": {"type": "array", "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "enum": list(catalog["props"].keys())},
                    "hint": {"type": "string", "enum": ["near", "mid", "far"]},
                },
                "required": ["id"]}},
            "rationale": {"type": "string"},
            "confidence": {"type": "number"},
        },
        "required": ["mood", "palette_direction", "motif", "density",
                     "length_bias", "light_bias", "props", "rationale", "confidence"],
    }


def system_prompt(catalog):
    motifs = ", ".join(catalog["motifs"].keys())
    props = ", ".join(catalog["props"].keys())
    return f"""You are the "dreaming" composer for a live 3-D wallpaper. Each night you reflect on
the user's day and shape the next leg of an endless symbolic stone corridor by emitting high-level
KNOBS (not geometry). A procedural engine turns your knobs into the actual scene.

Map the day's signals to the mood of the space:
  - git commits / churn  -> length_bias (busy day = longer hall) and density (more work = more columns/props)
  - music energy & genre  -> palette_direction and mood (loud/bassy = warmer/richer; quiet = cooler/desaturated)
  - apps used             -> motif (terminal/editor-heavy = austere/industrial; creative = ornate; files = gothic)
  - active hours / night  -> light_bias (late night = dimmer/cooler; long day = brighter)

All numeric knobs are 0..1. Choose mood, palette_direction, and motif ONLY from these allowed values:
  mood: {", ".join(catalog["enums"]["mood"])}
  palette_direction: {", ".join(catalog["enums"]["palette_direction"])}
  motif: {motifs}
Pick 2-5 props, each id ONLY from this catalog (no other ids exist):
  {props}
Set confidence 0..1 (how well the day maps to a clear scene; a quiet/empty day = low confidence).
Write one short rationale sentence. Output ONLY the JSON object matching the schema — no prose."""


def ollama_knobs(model, sys_p, user_p, schema, timeout=300):
    body = {
        "model": model,
        "messages": [{"role": "system", "content": sys_p},
                     {"role": "user", "content": user_p}],
        "stream": False,
        "format": schema,
        "keep_alive": "5m",
        "options": {"temperature": 0.6, "num_ctx": 8192},
    }
    req = urllib.request.Request(OLLAMA_URL, data=json.dumps(body).encode(),
                                headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)["message"]["content"]


def validate(knobs, catalog):
    if not isinstance(knobs, dict):
        return "not a JSON object"
    if knobs.get("mood") not in catalog["enums"]["mood"]:
        return f"mood {knobs.get('mood')!r} not allowed"
    if knobs.get("palette_direction") not in catalog["enums"]["palette_direction"]:
        return f"palette_direction {knobs.get('palette_direction')!r} not allowed"
    if knobs.get("motif") not in catalog["motifs"]:
        return f"motif {knobs.get('motif')!r} not allowed"
    for p in knobs.get("props", []):
        pid = p.get("id") if isinstance(p, dict) else p
        if pid not in catalog["props"]:
            return f"prop id {pid!r} not in catalog"
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--digest", required=True)
    ap.add_argument("--journey-dir", required=True)
    ap.add_argument("--catalog", default=str(DEFAULT_CATALOG))
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--out", default=str(KNOBS_OUT))
    ap.add_argument("--retries", type=int, default=2)
    ap.add_argument("--print", action="store_true")
    args = ap.parse_args()

    catalog = json.loads(Path(args.catalog).read_text())
    digest = json.loads(Path(args.digest).read_text())
    seed_from = last_leg_id(Path(args.journey_dir))
    if not seed_from:
        print(json.dumps({"error": f"no last leg in {args.journey_dir} to chain from"})); return

    schema = knob_schema(catalog)
    sys_p = system_prompt(catalog)
    day = (digest.get("meta", {}) or {}).get("digest_at", "")[:10] or \
        datetime.now(timezone.utc).strftime("%Y-%m-%d")
    user_p = (f"Day-digest (every block is present-gated; present:false means 'no signal'):\n"
              f"{json.dumps(digest, indent=2)}\n\nCompose the knobs for tonight's leg.")

    last_err = None
    for attempt in range(args.retries + 1):
        try:
            raw = ollama_knobs(args.model, sys_p, user_p
                               + (f"\n\n(Previous attempt was invalid: {last_err}. Fix it.)" if last_err else ""),
                               schema)
        except Exception as e:
            last_err = f"ollama call failed: {e}"
            continue
        if not raw or not raw.strip():
            last_err = "empty content (raise token budget)"
            continue
        try:
            knobs = json.loads(raw)
        except Exception:
            m = re.search(r"\{.*\}", raw, re.DOTALL)
            knobs = json.loads(m.group(0)) if m else None
        err = validate(knobs, catalog) if knobs is not None else "unparseable"
        if err:
            last_err = err
            continue
        # inject the grounding-critical fields (harness-owned, not model-owned)
        knobs["seed_from"] = seed_from
        knobs["seed"] = fnv1a(day)
        knobs["day"] = day
        knobs["_model"] = args.model
        knobs["from_signals"] = [k for k in ("git", "music", "apps", "time")
                                 if (digest.get(k, {}) or {}).get("present")]
        text = json.dumps(knobs, indent=2)
        if args.print:
            print(text)
        else:
            Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            Path(args.out).write_text(text + "\n", encoding="utf-8")
            print(json.dumps({"wrote": args.out, "model": args.model,
                              "seed_from": seed_from, "mood": knobs["mood"],
                              "motif": knobs["motif"]}, indent=2))
        return
    print(json.dumps({"error": "compose failed after retries", "last_error": last_err})); return


if __name__ == "__main__":
    main()
