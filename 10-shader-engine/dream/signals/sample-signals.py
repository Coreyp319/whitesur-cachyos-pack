#!/usr/bin/env python3
"""One sampling tick for the dreaming day-signal accumulator (Layer 10, problem F).

The collector (`collect-signals.py`) digests the day at dream-time, but a few
signals only exist *over time* — was sound playing, how busy the workspace was.
This appends one compact NDJSON line of **shape** to the per-day log the collector
reads back for `audio_active_fraction` + the busiest hour. Run by
`nimbus-dream-sampler.timer` every ~2 min (opt-in; see README).

LOCAL-ONLY, no network. **No window titles / app names** — KWin Wayland exposes
none here without playerctl/kdotool or a window-bridge extension (README), so we
record only counts + geometry from the existing Layer-9 bridges. Don't over-collect.
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

HOME = Path.home()
STATE = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "nimbus-dream"
AURORA = Path(os.environ.get("XDG_RUNTIME_DIR", str(HOME / ".cache"))) / "nimbus-aurora"


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return None


def main():
    audio = read_json(AURORA / "audio.json") or {}
    wins_doc = read_json(AURORA / "windows.json") or {}
    wins = wins_doc.get("wins") or []
    sw = max((w.get("x", 0) + w.get("w", 0) for w in wins), default=1.0) or 1.0
    sh = max((w.get("y", 0) + w.get("h", 0) for w in wins), default=1.0) or 1.0
    active = next((w for w in wins if w.get("active")), None)
    frac = round((active["w"] * active["h"]) / (sw * sh), 3) if active and sw and sh else None

    tick = {
        "ts": int(time.time() * 1000),
        "audio": round(float(audio.get("level", 0.0) or 0.0), 3),
        "wins": len(wins),
        "active_area": frac,
    }

    day = time.strftime("%Y-%m-%d")
    log = STATE / "signals" / f"signals-{day}.ndjson"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a", encoding="utf-8") as f:
        f.write(json.dumps(tick) + "\n")


if __name__ == "__main__":
    main()
