#!/usr/bin/env python3
"""Guardrail for the nightly "dreaming" composer. The local model proposes
semantic *knobs*; THIS disposes — turning them into a validated `leg-NNN.json`
appended to the journey, with the same trust boundary as `6-local-ai/ui-audit/`:

  * GROUNDED   — the model emits only high-level knobs (mood / palette_direction /
                 motif / density / length_bias / light_bias / seed / seed_from)
                 plus prop picks BY CATALOG ID. There is no free-form geometry
                 field to hallucinate into. Unknown ids / out-of-enum values are
                 dropped, never written. The composer maps knobs -> concrete
                 LegManifest fields deterministically (seeded), so the same knobs
                 always yield the same leg.
  * CLAMPED    — every numeric the model influences is clamped to a safe range
                 (length, col_spacing, illuminance, fog, colour channels, prop
                 count/placement). Out-of-bounds clamps, it doesn't reject.
  * CHAINED    — the new leg's `seed_from` MUST equal the current last live leg's
                 id, and the entry aperture must match that leg's exit aperture,
                 or it's rejected (the runtime portal-handoff contract, enforced
                 in Python BEFORE writing so the engine's seam warning never fires).
  * EARNED     — nothing auto-applies to the live journey until you've approved
                 one leg (`--approve <leg_id>` records `accepted`, graduating the
                 pipeline to auto). Until then every leg STAGES. Low confidence
                 also stages. Autonomy is earned, not preset.
  * REVERSIBLE — the whole journey/ dir is backed up ONCE per run; `--revert
                 <run_id>` restores it and `--drop-last N` deletes the last N legs.
  * ROBUST     — tolerant knob parsing (extracts JSON from prose-wrapped model
                 output); a malformed manifest is surfaced + ledgered, never
                 silently written. (The engine ALSO skips bad legs at load — this
                 is defence-in-depth on top of that.)

Modes:
    --apply               write/stage (default: dry-run, writes nothing)
    --approve <leg_id>    promote a staged leg to live + mark the pipeline earned
    --revert <run_id>     restore the journey/ dir a run backed up
    --drop-last N         delete the last N live legs (and ledger it)

Usage:
    dream-apply.py --knobs KNOBS.json --journey-dir .../nimbus-flux/journey [--apply]
    dream-apply.py --approve leg-007
    dream-apply.py --revert 20260614-031500
    dream-apply.py --drop-last 1

Env:
    NIMBUS_DREAM_HOME   runtime state dir (default ~/.hermes/dreaming) — set in tests
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
RUNTIME = Path(os.environ.get("NIMBUS_DREAM_HOME", HOME / ".hermes" / "dreaming"))
LEDGER = RUNTIME / "ledger.jsonl"
STAGING = RUNTIME / "staging"
BACKUPS = RUNTIME / "backups"
REPORT = RUNTIME / "report.md"

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CATALOG = SCRIPT_DIR.parent.parent / "catalog.json"

CONFIDENCE_FLOOR = 0.6
MAX_PROPS = 8

# Clamp ranges — the safety envelope the model's knobs map into. (min, max).
# Mirrors the spirit of ui-audit's validate_value + hexen-tune's KNOBS table.
CLAMP = {
    "length":             (32.0, 64.0),
    "col_spacing":        (4.0, 10.0),
    "moon_illuminance":   (400.0, 1400.0),
    "ambient_brightness": (25.0, 80.0),
    "fog_density":        (0.003, 0.02),
    "fog_volume_density": (0.01, 0.06),
    "scale":              (0.3, 3.0),
}

# Fixed corridor cross-section / chaining frame (all legs share the aperture so
# they join; the previous leg's exit aperture wins if it differs from default).
DEFAULT_APERTURE = [6.0, 5.2]
EYE_Y = 2.6

# mood -> (fog multiplier, ambient/exposure feel). Multiplies the base fog so
# "tense"/"melancholy" feel denser, "wondrous"/"triumphant" lighter.
MOOD_FOG = {"calm": 1.0, "tense": 1.25, "triumphant": 0.8,
            "melancholy": 1.3, "wondrous": 0.85, "austere": 1.05}

BASE_TORCH = [1.0, 0.55, 0.22]


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def now_iso():
    return datetime.now(timezone.utc).isoformat()


def run_id_now():
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def clamp(x, lo, hi):
    return lo if x < lo else hi if x > hi else x


def lerp(a, b, t):
    return a + (b - a) * clamp(t, 0.0, 1.0)


def clamp01(x):
    return clamp(float(x), 0.0, 1.0)


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# tolerant knob parsing (small models wrap JSON in prose)
# ---------------------------------------------------------------------------

def parse_knobs(path: Path):
    """Return (knobs_dict, parse_error)."""
    text = path.read_text(encoding="utf-8")
    try:
        return _coerce(json.loads(text)), None
    except Exception:
        pass
    m = re.search(r"(\{.*\})", text, re.DOTALL)
    if m:
        try:
            return _coerce(json.loads(m.group(1))), None
        except Exception as e:
            return None, f"could not parse extracted JSON block: {e}"
    return None, "no JSON object found in knobs file"


def _coerce(data):
    if isinstance(data, dict) and "knobs" in data and isinstance(data["knobs"], dict):
        return data["knobs"]
    return data if isinstance(data, dict) else None


# ---------------------------------------------------------------------------
# ledger
# ---------------------------------------------------------------------------

def load_ledger():
    recs = []
    if LEDGER.exists():
        for line in LEDGER.read_text(encoding="utf-8").splitlines():
            try:
                recs.append(json.loads(line))
            except Exception:
                continue
    return recs


def append_ledger(rec):
    RUNTIME.mkdir(parents=True, exist_ok=True)
    with LEDGER.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")


def is_earned(recs) -> bool:
    """The pipeline is earned once any leg has been `accepted` (approved) once."""
    return any(r.get("status") == "accepted" for r in recs)


# ---------------------------------------------------------------------------
# journey directory: discover the chaining target + the next leg id
# ---------------------------------------------------------------------------

LEG_RE = re.compile(r"^leg-(\d+)\.json$")


def list_legs(journey_dir: Path):
    """Sorted [(index, path)] of leg-NNN.json in the live journey dir."""
    out = []
    if journey_dir.exists():
        for p in journey_dir.iterdir():
            m = LEG_RE.match(p.name)
            if m:
                out.append((int(m.group(1)), p))
    return sorted(out)


def last_leg(journey_dir: Path):
    legs = list_legs(journey_dir)
    if not legs:
        return None
    idx, path = legs[-1]
    try:
        data = load_json(path)
    except Exception:
        data = {}
    return {"index": idx, "id": data.get("id", f"leg-{idx:03d}"),
            "exit_aperture": (data.get("exit", {}) or {}).get("aperture", DEFAULT_APERTURE)}


def next_leg_id(journey_dir: Path):
    legs = list_legs(journey_dir)
    n = (legs[-1][0] + 1) if legs else 0
    return n, f"leg-{n:03d}"


# ---------------------------------------------------------------------------
# backup + revert (snapshot the whole journey dir once per run)
# ---------------------------------------------------------------------------

def backup_journey(journey_dir: Path, run_id: str) -> str:
    d = BACKUPS / run_id / "journey"
    d.mkdir(parents=True, exist_ok=True)
    for _, p in list_legs(journey_dir):
        shutil.copy2(p, d / p.name)
    (BACKUPS / run_id / "manifest.json").write_text(
        json.dumps({"journey_dir": str(journey_dir), "ts": now_iso()}, indent=2))
    return str(d)


def do_revert(run_id: str) -> dict:
    man_p = BACKUPS / run_id / "manifest.json"
    snap = BACKUPS / run_id / "journey"
    if not man_p.exists():
        return {"error": f"no backup for run {run_id}"}
    journey_dir = Path(load_json(man_p)["journey_dir"])
    for _, p in list_legs(journey_dir):  # clear current legs
        p.unlink()
    restored = []
    for p in sorted(snap.iterdir()):
        if LEG_RE.match(p.name):
            shutil.copy2(p, journey_dir / p.name)
            restored.append(p.name)
    append_ledger({"run_id": f"revert-of-{run_id}", "ts": now_iso(),
                   "status": "reverted", "restored": restored})
    return {"reverted_run": run_id, "restored": restored}


def do_drop_last(journey_dir: Path, n: int) -> dict:
    legs = list_legs(journey_dir)
    dropped = []
    for _, p in legs[-n:] if n > 0 else []:
        dropped.append(p.name)
        p.unlink()
    append_ledger({"run_id": f"drop-{run_id_now()}", "ts": now_iso(),
                   "status": "reverted", "dropped": dropped,
                   "journey_dir": str(journey_dir)})
    return {"dropped": dropped}


# ---------------------------------------------------------------------------
# knobs -> manifest (deterministic, seeded, clamped)
# ---------------------------------------------------------------------------

def drift_torch(palette_direction: str, rng) -> list:
    r, g, b = BASE_TORCH
    d = 0.06
    if palette_direction == "warmer":
        r, b = r, b - d
    elif palette_direction == "cooler":
        r, b = r - d, b + d
    elif palette_direction == "richer":
        g = g - d * 0.5
    elif palette_direction == "desaturated":
        g, b = g + d * 0.4, b + d
    # 'hold' (and all): a tiny seeded jitter so legs are "related but progressing"
    jit = lambda v: clamp(v + rng.uniform(-0.02, 0.02), 0.0, 1.0)
    return [round(jit(r), 3), round(jit(g), 3), round(jit(b), 3)]


def place_props(picks, catalog, length, width, rng):
    """Deterministically place validated prop picks within the corridor bbox.
    Returns (props_list, dropped_ids)."""
    props, dropped = [], []
    half_x = width / 2.0 - 0.7
    for i, pick in enumerate(picks[:MAX_PROPS]):
        pid = pick.get("id") if isinstance(pick, dict) else pick
        meta = catalog["props"].get(pid)
        if meta is None:
            dropped.append(pid)
            continue
        hint = (pick.get("hint") if isinstance(pick, dict) else "mid") or "mid"
        side = -1.0 if (i % 2 == 0) else 1.0
        x = clamp(side * half_x, -(width / 2 - 0.4), (width / 2 - 0.4))
        zr = {"near": (0.12, 0.34), "mid": (0.34, 0.66), "far": (0.66, 0.9)}.get(hint, (0.34, 0.66))
        z = -round(length * rng.uniform(*zr), 2)
        scale = clamp(meta.get("scale_default", 1.0), *CLAMP["scale"])
        props.append({"model": pid, "pos": [round(x, 2), meta.get("y_base", 0.0), z],
                      "rot_y": round(rng.uniform(0.0, 6.28), 2), "scale": scale})
    return props, dropped


def compose_leg(knobs, catalog, leg_id, seed_from, aperture):
    """Pure: (validated knobs) -> (LegManifest dict, list of clamp/drop notes)."""
    notes = []
    seed = int(knobs.get("seed", 0))
    rng = random.Random(seed)

    width, height = aperture[0], aperture[1]
    length = clamp(lerp(*CLAMP["length"], clamp01(knobs.get("length_bias", 0.5))), *CLAMP["length"])
    col_spacing = clamp(lerp(CLAMP["col_spacing"][1], CLAMP["col_spacing"][0],
                             clamp01(knobs.get("density", 0.5))), *CLAMP["col_spacing"])
    light_bias = clamp01(knobs.get("light_bias", 0.5))
    moon = clamp(lerp(*CLAMP["moon_illuminance"], light_bias), *CLAMP["moon_illuminance"])
    amb_b = clamp(lerp(*CLAMP["ambient_brightness"], light_bias), *CLAMP["ambient_brightness"])

    mood = knobs.get("mood", "calm")
    fog_mult = MOOD_FOG.get(mood, 1.0)
    fog_density = clamp(0.007 * fog_mult, *CLAMP["fog_density"])
    fog_vol = clamp(0.028 * fog_mult, *CLAMP["fog_volume_density"])

    motif = knobs.get("motif", "gothic_nave")
    tex = catalog["motifs"].get(motif) or catalog["motifs"]["gothic_nave"]
    torch = drift_torch(knobs.get("palette_direction", "hold"), rng)

    props, dropped = place_props(knobs.get("props", []), catalog, length, width, rng)
    if dropped:
        notes.append(f"dropped {len(dropped)} unknown prop id(s): {dropped}")

    leg = {
        "id": leg_id,
        "seed_from": seed_from,
        "day": knobs.get("day") or datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "theme": {"palette": knobs.get("palette", []), "motif": motif, "mood": mood},
        "entry": {"at": [0.0, EYE_Y, 0.0], "forward": [0.0, 0.0, -1.0],
                  "up": [0.0, 1.0, 0.0], "aperture": aperture},
        "exit": {"at": [0.0, EYE_Y, -length], "forward": [0.0, 0.0, -1.0],
                 "up": [0.0, 1.0, 0.0], "aperture": aperture},
        "geometry": [{
            "kind": "corridor", "length": round(length, 2), "width": width, "height": height,
            "floor": tex["floor"], "ceiling": tex["ceiling"], "wall": tex["wall"], "trim": tex["trim"],
            "columns": True, "col_spacing": round(col_spacing, 2), "torch_color": torch,
        }],
        "props": props,
        "lights": [],
        "atmosphere": {
            "fog_density": round(fog_density, 4),
            "ambient_brightness": round(amb_b, 1),
            "moon_illuminance": round(moon, 1),
            "fog_volume_density": round(fog_vol, 4),
        },
        "provenance": {
            "from_signals": knobs.get("from_signals", []),
            "model": knobs.get("_model", "unknown"),
            "model_notes": knobs.get("rationale", ""),
            "knobs": {k: knobs.get(k) for k in
                      ("mood", "palette_direction", "motif", "density", "length_bias",
                       "light_bias", "seed", "confidence")},
        },
    }
    return leg, notes


# ---------------------------------------------------------------------------
# validation of the raw knobs (schema + enum) before composing
# ---------------------------------------------------------------------------

def validate_knobs(knobs, catalog):
    """Return error string, or '' if structurally usable. Enum violations on
    mood/motif/palette_direction are errors (the model must pick allowed values)."""
    if not isinstance(knobs, dict):
        return "knobs is not a JSON object"
    if "seed_from" not in knobs or not knobs.get("seed_from"):
        return "missing required field: seed_from"
    moods = catalog["enums"]["mood"]
    pals = catalog["enums"]["palette_direction"]
    if knobs.get("mood", "calm") not in moods:
        return f"mood {knobs.get('mood')!r} not in {moods}"
    if knobs.get("palette_direction", "hold") not in pals + ["hold"]:
        return f"palette_direction {knobs.get('palette_direction')!r} invalid"
    if knobs.get("motif", "gothic_nave") not in catalog["motifs"]:
        return f"motif {knobs.get('motif')!r} not in catalog motifs"
    for f in ("density", "length_bias", "light_bias"):
        v = knobs.get(f, 0.5)
        if not isinstance(v, (int, float)):
            return f"{f} must be a number"
    return ""


# ---------------------------------------------------------------------------
# main pipeline
# ---------------------------------------------------------------------------

def process(knobs, catalog, journey_dir, digest_path, model, dry, conf_floor):
    run_id = run_id_now()
    recs = load_ledger()
    result = {"run_id": run_id, "leg_id": None, "status": None, "notes": [], "message": ""}

    def finish(status, msg, leg_id=None, **extra):
        result.update(status=status, message=msg, leg_id=leg_id)
        rec = {"run_id": run_id, "ts": now_iso(), "leg_id": leg_id, "status": status,
               "message": msg, "notes": result["notes"],
               "digest_sha": _digest_sha(digest_path), "model": model, **extra}
        if not dry:
            append_ledger(rec)
        return result

    # schema + enum
    err = validate_knobs(knobs, catalog)
    if err:
        return finish("rejected-malformed", err)

    # chaining target
    target = last_leg(journey_dir)
    if target is None:
        return finish("rejected-no-seed",
                      f"no existing leg in {journey_dir} to chain from (need leg-000 seed)")
    if str(knobs.get("seed_from")) != str(target["id"]):
        return finish("rejected-drift",
                      f"seed_from={knobs.get('seed_from')!r} != current last leg {target['id']!r}")

    aperture = target["exit_aperture"]
    _, leg_id = next_leg_id(journey_dir)
    knobs["_model"] = model
    leg, notes = compose_leg(knobs, catalog, leg_id, target["id"], aperture)
    result["notes"] = notes

    # earned-autonomy + confidence -> stage vs auto
    conf = knobs.get("confidence")
    earned = is_earned(recs)
    low_conf = (conf is None) or (float(conf) < conf_floor)
    auto_ok = earned and not low_conf and not dry

    payload = json.dumps(leg, indent=2) + "\n"
    if not auto_ok:
        why = []
        if not earned:
            why.append("pipeline not yet earned — approve one leg to graduate to auto")
        if low_conf:
            why.append(f"confidence {conf} < {conf_floor}")
        if dry:
            return finish("dry-stage", f"would STAGE {leg_id} ({'; '.join(why)})", leg_id)
        STAGING.mkdir(parents=True, exist_ok=True)
        (STAGING / f"{leg_id}.json").write_text(payload, encoding="utf-8")
        return finish("staged", f"staged {leg_id} ({'; '.join(why)})", leg_id,
                      staged_path=str(STAGING / f"{leg_id}.json"))

    # auto path: backup the journey, then write the leg live
    bkp = backup_journey(journey_dir, run_id)
    (journey_dir / f"{leg_id}.json").write_text(payload, encoding="utf-8")
    return finish("applied", f"APPLIED {leg_id} -> live journey", leg_id, backup=bkp)


def _digest_sha(digest_path):
    if digest_path and Path(digest_path).exists():
        return hashlib.sha256(Path(digest_path).read_bytes()).hexdigest()[:12]
    return None


def do_approve(leg_id, journey_dir) -> dict:
    src = STAGING / f"{leg_id}.json"
    if not src.exists():
        return {"error": f"no staged leg {leg_id}"}
    run_id = run_id_now()
    backup_journey(journey_dir, run_id)
    dst = journey_dir / f"{leg_id}.json"
    shutil.copy2(src, dst)
    src.unlink()
    append_ledger({"run_id": run_id, "ts": now_iso(), "leg_id": leg_id,
                   "status": "accepted", "message": f"approved {leg_id} -> live",
                   "backup": str(BACKUPS / run_id / 'journey')})
    return {"approved": leg_id, "note": "pipeline is now EARNED — eligible for auto next run"}


def build_report(result):
    L = [f"# Dreaming — {result['run_id']}", "",
         f"- status: **{result['status']}**",
         f"- leg: `{result.get('leg_id')}`",
         f"- {result.get('message','')}"]
    if result["notes"]:
        L += ["", "## Notes"] + [f"- {n}" for n in result["notes"]]
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--knobs")
    ap.add_argument("--journey-dir")
    ap.add_argument("--catalog", default=str(DEFAULT_CATALOG))
    ap.add_argument("--digest")
    ap.add_argument("--model", default="unknown")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--confidence-floor", type=float, default=CONFIDENCE_FLOOR)
    ap.add_argument("--approve", metavar="LEG_ID")
    ap.add_argument("--revert", metavar="RUN_ID")
    ap.add_argument("--drop-last", type=int, metavar="N")
    args = ap.parse_args()

    if args.revert:
        print(json.dumps(do_revert(args.revert), indent=2)); return
    if args.drop_last is not None:
        if not args.journey_dir:
            ap.error("--drop-last needs --journey-dir")
        print(json.dumps(do_drop_last(Path(args.journey_dir), args.drop_last), indent=2)); return
    if args.approve:
        if not args.journey_dir:
            ap.error("--approve needs --journey-dir")
        print(json.dumps(do_approve(args.approve, Path(args.journey_dir)), indent=2)); return

    if not args.knobs or not args.journey_dir:
        ap.error("--knobs and --journey-dir are required")
    catalog = load_json(Path(args.catalog))
    knobs, perr = parse_knobs(Path(args.knobs))
    if perr:
        print(json.dumps({"status": "rejected-malformed", "message": perr})); return

    dry = not args.apply
    result = process(knobs, catalog, Path(args.journey_dir), args.digest,
                     args.model, dry, args.confidence_floor)
    if not dry:
        RUNTIME.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(build_report(result), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
