#!/usr/bin/env python3
"""Thin CLI / sampler shim — the day-signal collector logic now lives in the importable
``dream/collect_digest.py``.

Why: a hyphen made THIS file un-importable, so the rich signals it gathered never reached
the composer (``compose.py`` could only ``import collect_digest``, the thin one). Consolidated
2026-06-14: the gatherers moved up to ``collect_digest.py`` (one source of truth), and this
file remains as (a) the CLI that writes ``$XDG_STATE_HOME/nimbus-dream/digests/day-digest.json``
for the systemd sampler/inspection, and (b) a re-export surface so ``test_signals.py`` (which
loads this module *by path*) keeps testing the same functions.

Usage:
    collect-signals.py [--since midnight] [--repos a:b:c] [--out PATH]
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

# the logic lives one dir up, in the importable module
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import collect_digest as _cd  # noqa: E402

# --- re-export the gatherers (test_signals.py imports this module by path) ---
parse_conventional = _cd.parse_conventional
language_for = _cd.language_for
time_of_day = _cd.time_of_day
collect_clock = _cd.collect_clock
collect_session = _cd.collect_session
collect_git = _cd.collect_git
collect_audio = _cd.collect_audio
collect_windows = _cd.collect_windows
collect_sampler = _cd.collect_sampler
build_summary = _cd.build_summary
discover_repos = _cd.discover_repos
read_json = _cd.read_json
run = _cd.run

STATE = _cd.STATE
DEFAULT_OUT = STATE / "digests" / "day-digest.json"


def main():
    ap = argparse.ArgumentParser(description="Collect the day's signals into day-digest.json")
    ap.add_argument("--since", default="midnight",
                    help="git window start (git approxdate; default 'midnight' = today)")
    ap.add_argument("--repos", default=None, help="':'-separated repo override")
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    args = ap.parse_args()

    repos = [p for p in args.repos.split(":") if p] if args.repos else None
    digest = _cd.collect(since=args.since, repos=repos)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        shutil.copy2(out, out.parent / "day-digest.prev.json")
    tmp = out.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(digest, indent=2), encoding="utf-8")
    os.replace(tmp, out)
    # dated archive so the journey ledger can correlate a leg back to its day
    shutil.copy2(out, out.parent / f"day-digest-{digest['meta']['date']}.json")

    print(str(out))
    print("\n".join("  · " + s for s in digest.get("summary", [])), flush=True, file=sys.stderr)


if __name__ == "__main__":
    main()
