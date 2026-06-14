#!/usr/bin/env python3
"""Offline tests for the dreaming day-signal collector — no GPU, model, or network.

Mirrors `dream/test_dream.py`: `python3 test_signals.py` → exit 0 = all pass.
Covers the tricky pure logic (conventional-commit parsing, language bucketing,
time-of-day buckets, window-shape labels, summary lines) and the file-backed
readers against temp fixtures, including a throwaway git repo so the strong
`git` signal is exercised end-to-end. The point: the model-facing digest is
grounded — these lock the grounding down.
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).parent


def _load():
    """Import the hyphenated CLI module by path (not import-able as a name)."""
    spec = importlib.util.spec_from_file_location("collect_signals", HERE / "collect-signals.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cs = _load()

TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


# ---- pure helpers --------------------------------------------------------

@test
def parse_conventional():
    assert cs.parse_conventional("feat(layer10): widen knobs") == ("feat", ["layer10"])
    assert cs.parse_conventional("feat(a, b)!: breaking") == ("feat", ["a", "b"])
    assert cs.parse_conventional("docs: tidy") == ("docs", [])
    assert cs.parse_conventional("just a sentence, no prefix") == (None, [])
    # a colon mid-subject without a type prefix is not conventional
    assert cs.parse_conventional("WIP: there is no scope but a type") == ("WIP".lower(), [])


@test
def language_for():
    assert cs.language_for("src/main.rs") == "rust"
    assert cs.language_for("tools/x.py") == "python"
    assert cs.language_for("README.md") == "markdown"
    assert cs.language_for("nimbus.layers") == "config"          # pack-specific medium
    assert cs.language_for("Cargo.lock") == "other"              # noise → bucketed
    assert cs.language_for(".gitignore") == "other"
    assert cs.language_for("Makefile") == "other"                # no extension


@test
def time_of_day_buckets():
    cases = {2: "night", 6: "dawn", 9: "morning", 14: "afternoon", 19: "evening", 23: "night"}
    for hour, want in cases.items():
        assert cs.time_of_day(hour) == want, f"hour {hour} → {cs.time_of_day(hour)} != {want}"


@test
def collect_clock_weekend_morning():
    # 2026-06-13 is a Saturday at 09:30 → weekend, morning.
    c = cs.collect_clock(datetime(2026, 6, 13, 9, 30))
    assert c["weekday"] == "Saturday"
    assert c["is_weekend"] is True
    assert c["time_of_day"] == "morning"
    assert c["hour"] == 9


# ---- bridge readers (temp fixtures) --------------------------------------

@test
def collect_windows_shapes():
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "windows.json"

        # one big active window on an ultrawide → single-focused (ultrawide)
        p.write_text(json.dumps({"wins": [
            {"x": 0, "y": 0, "w": 3440, "h": 1440, "active": True},
            {"x": 100, "y": 100, "w": 800, "h": 600, "active": False},
        ]}))
        w = cs.collect_windows(p)
        assert w["present"] and w["count"] == 2
        assert w["active_area_fraction"] == 1.0
        assert w["layout"] == "single-focused (ultrawide)", w["layout"]

        # a small active window among several → multi-window
        p.write_text(json.dumps({"wins": [
            {"x": 0, "y": 0, "w": 1000, "h": 1000, "active": False},
            {"x": 200, "y": 200, "w": 400, "h": 300, "active": True},
        ]}))
        w = cs.collect_windows(p)
        assert w["layout"] == "multi-window", w["layout"]

        # absent file → graceful
        assert cs.collect_windows(Path(d) / "nope.json")["present"] is False


@test
def collect_audio_levels():
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "audio.json"
        p.write_text(json.dumps({"level": 0.5}))
        assert cs.collect_audio(p) == {"present": True, "level": 0.5, "playing_now": True}
        p.write_text(json.dumps({"level": 0.0}))
        assert cs.collect_audio(p)["playing_now"] is False
        assert cs.collect_audio(Path(d) / "nope.json")["present"] is False


@test
def collect_sampler_fraction():
    with tempfile.TemporaryDirectory() as d:
        state = Path(d)
        log = state / "signals" / "signals-2026-06-13.ndjson"
        log.parent.mkdir(parents=True)
        base = datetime(2026, 6, 13, 10, 0).timestamp() * 1000
        ticks = [
            {"ts": int(base), "audio": 0.0, "wins": 2},
            {"ts": int(base + 60000), "audio": 0.3, "wins": 2},
            {"ts": int(base + 120000), "audio": 0.4, "wins": 3},
            {"ts": int(base + 180000), "audio": 0.0, "wins": 1},
        ]
        log.write_text("\n".join(json.dumps(t) for t in ticks) + "\n")
        s = cs.collect_sampler("2026-06-13", state=state)
        assert s["present"] and s["ticks"] == 4
        assert s["audio_active_fraction"] == 0.5      # 2 of 4 above AUDIO_ON
        assert s["peak_hour"] == 10
        # absent → graceful
        assert cs.collect_sampler("2999-01-01", state=state)["present"] is False


# ---- git end-to-end (throwaway repo) -------------------------------------

@test
def collect_git_real_repo():
    with tempfile.TemporaryDirectory() as d:
        def git(*args):
            subprocess.run(["git", "-C", d, *args], check=True,
                           capture_output=True, text=True)
        git("init", "-q")
        git("config", "user.email", "t@example.com")
        git("config", "user.name", "Tester")
        git("config", "commit.gpgsign", "false")  # ignore any global signing

        (Path(d) / "foo.rs").write_text("fn main() {}\n")
        git("add", "-A")
        git("commit", "-qm", "feat(core): add main")
        (Path(d) / "bar.md").write_text("# notes\n")
        (Path(d) / "baz.py").write_text("print(1)\n")
        git("add", "-A")
        git("commit", "-qm", "docs: write up")

        block = cs.collect_git([d], "1 year ago")
        assert block["present"] and block["total_commits"] == 2, block
        assert block["types"] == {"feat": 1, "docs": 1}, block["types"]
        assert block["scopes"] == ["core"], block["scopes"]
        langs = {l["lang"] for l in block["languages"]}
        assert {"rust", "markdown", "python"} <= langs, langs
        assert block["busiest_repo"] == Path(d).name

        # a window with no commits → present False, no crash
        empty = cs.collect_git([d], "2099-01-01")
        assert empty["present"] is False and empty["total_commits"] == 0


@test
def collect_git_skips_missing_repo():
    block = cs.collect_git(["/definitely/not/a/repo"], "1 year ago")
    assert block["present"] is False and block["repos"] == []


# ---- summary (the model-facing payload) ----------------------------------

@test
def build_summary_lines():
    git_block = {
        "present": True, "total_commits": 7, "busiest_repo": "whitesur-cachyos-pack",
        "types": {"feat": 5, "docs": 2}, "scopes": ["layer10", "readme"],
        "languages": [{"lang": "rust", "files": 9}, {"lang": "python", "files": 3}],
        "repos": [{"commits": 7}],
    }
    clock = {"weekday": "Sunday", "time_of_day": "morning", "is_weekend": True}
    session = {"active_since": "2026-06-14T08:50:00-07:00", "active_span_hours": 1.6}
    lines = cs.build_summary(clock, git_block, session,
                             {"playing_now": False}, {"present": True, "count": 2,
                             "layout": "single-focused (ultrawide)"}, {"present": False})
    blob = " | ".join(lines)
    assert "7 commits" in blob and "feat×5" in blob and "layer10" in blob
    assert "languages: rust, python" in blob
    assert "Sunday morning (weekend)" in blob
    assert "music: quiet" in blob
    assert "2 windows" in blob and "1.6h" in blob


@test
def build_summary_no_git():
    lines = cs.build_summary({"weekday": "Monday", "time_of_day": "night", "is_weekend": False},
                             {"present": False, "repos": [], "types": {}, "scopes": [],
                              "languages": [], "total_commits": 0, "busiest_repo": None},
                             {"active_since": None, "active_span_hours": None},
                             {"playing_now": False}, {"present": False}, {"present": False})
    assert any("no commits" in l for l in lines)


def main():
    fails = 0
    for fn in TESTS:
        try:
            fn()
            print(f"  ok  {fn.__name__}")
        except AssertionError as e:
            fails += 1
            print(f" FAIL {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001 — report any unexpected error as a failure
            fails += 1
            print(f" ERR  {fn.__name__}: {e!r}")
    print(f"\n{len(TESTS) - fails}/{len(TESTS)} passed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
