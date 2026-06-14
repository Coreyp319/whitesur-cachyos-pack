#!/usr/bin/env python3
"""Day-signal collector for the dreaming journey (handoff problem F) — the SINGLE,
authoritative, **importable** collector.

Gathers a compact, **LOCAL-ONLY, privacy-aware** snapshot of the day into a *day-digest*
the composer uses to seed a new leg's mood/motif/palette. Reuses the Layer-9 KWin→file
bridges (`$XDG_RUNTIME_DIR/nimbus-aurora/{windows,audio}.json`) plus `git log` (the
strongest "what did I do today" signal). Every source is best-effort — a missing one is
simply omitted, never fatal.

This module is the consolidation of the former `signals/collect-signals.py`: the rich
gatherers (conventional-commit types/scopes, language buckets, active-hours, window layout,
the dwell sampler, grounded `summary[]`) now live HERE so they can be `import`ed — a hyphen
made that file un-importable, which is exactly why the rich signals never reached the
composer. `signals/collect-signals.py` is now a thin CLI/sampler shim that re-exports these.

Two builders, on purpose:
  • ``collect()``        — the LIVE rich collector (all signals + a grounded ``summary[]``)
                           plus flat compat aliases (``date``/``intensity``/``part_of_day``/
                           ``music_active``/``windows_open``/``git.commits``) the composer
                           reads directly, so continuity with the offline tests is kept.
  • ``build_digest(...)``— the legacy *pure* flat builder, retained verbatim for the offline
                           composer tests (deterministic; no I/O).

Anti-confabulation (mirrors `6-local-ai/ui-audit/`): every figure is **measured**, and the
``summary`` lines are the grounded `from_signals` the model may cite — it must not invent
activity that isn't here.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Optional

HOME = Path.home()
STATE = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "nimbus-dream"
RUNTIME = os.environ.get("XDG_RUNTIME_DIR", str(HOME / ".cache"))
AURORA = Path(RUNTIME) / "nimbus-aurora"  # the Layer-9 KWin→file bridges live here

# Commit subjects longer than this are truncated (privacy + compactness).
SUBJECT_MAX = 90
# Cap how many subjects we keep per repo so the digest stays small for the model.
SUBJECTS_PER_REPO = 12
# audio.json `level` above this counts as "sound is playing".
AUDIO_ON = 0.02

# File extension → coarse language/medium, for "what you worked in" tallies.
LANG = {
    "rs": "rust", "py": "python", "md": "markdown", "sh": "shell", "fish": "shell",
    "qml": "qml", "js": "javascript", "ts": "typescript", "json": "json",
    "toml": "toml", "xml": "xml", "yaml": "yaml", "yml": "yaml", "svg": "svg",
    "frag": "shader", "vert": "shader", "glsl": "shader", "wgsl": "shader",
    "comp": "shader", "qsb": "shader", "c": "c", "h": "c", "cpp": "cpp",
    "css": "css", "html": "html", "desktop": "config", "conf": "config",
    "service": "systemd", "timer": "systemd", "colors": "color-scheme",
    "layers": "config", "kvconfig": "config", "gltf": "3d", "glb": "3d",
}


# --------------------------------------------------------------------------- #
# clock / intensity buckets
# --------------------------------------------------------------------------- #

def _part_of_day(hour: int) -> str:
    """Legacy 4-bucket time-of-day used by `build_digest` (kept for the offline tests)."""
    if 5 <= hour < 12:
        return "morning"
    if 12 <= hour < 17:
        return "afternoon"
    if 17 <= hour < 22:
        return "evening"
    return "night"


def time_of_day(hour):
    """Rich 6-bucket time-of-day (adds dawn/evening granularity) used by `collect`."""
    if hour < 5:   return "night"
    if hour < 8:   return "dawn"
    if hour < 12:  return "morning"
    if hour < 17:  return "afternoon"
    if hour < 21:  return "evening"
    return "night"


def _intensity(commits: int) -> str:
    if commits <= 0:
        return "quiet"
    if commits <= 5:
        return "steady"
    return "busy"


# --------------------------------------------------------------------------- #
# legacy pure builder (retained verbatim for test_compose.py — deterministic)
# --------------------------------------------------------------------------- #

def build_digest(
    dt: datetime,
    commits: int,
    subjects: list[str],
    repos: list[str],
    windows_open: int,
    music_active: bool,
) -> dict:
    """Assemble a flat day-digest from already-gathered signals (pure, no I/O)."""
    return {
        "date": dt.strftime("%Y-%m-%d"),
        "weekday": dt.strftime("%A"),
        "hour": dt.hour,
        "part_of_day": _part_of_day(dt.hour),
        "intensity": _intensity(commits),
        "git": {"commits": int(commits), "repos": list(repos), "subjects": list(subjects[:8])},
        "windows_open": int(windows_open),
        "music_active": bool(music_active),
    }


# --------------------------------------------------------------------------- #
# small helpers
# --------------------------------------------------------------------------- #

def run(cmd, timeout=15, cwd=None):
    """Run a command, return stripped stdout or None (never raises)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None


# --------------------------------------------------------------------------- #
# git — the strong retrospective signal: what got built today
# --------------------------------------------------------------------------- #

CONV = re.compile(r"^(\w+)(?:\(([^)]+)\))?(!)?:")  # conventional-commit prefix


def parse_conventional(subj):
    """(type, [scopes]) from a conventional-commit subject, else (None, [])."""
    m = CONV.match(subj)
    if not m:
        return None, []
    scopes = [s.strip() for s in m.group(2).split(",")] if m.group(2) else []
    return m.group(1).lower(), scopes


def language_for(path):
    """Coarse language/medium for a file path; unknown extension → 'other' (keeps
    the model-facing language list meaningful — no lockfile/dotfile noise)."""
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    return LANG.get(ext, "other")


def discover_repos():
    """Known repos to scan, in priority order:
       1. NIMBUS_DREAM_REPOS (':'-separated paths)
       2. ~/.config/nimbus-dream/repos.txt (one path per line, '#' comments)
       3. auto-discovery: git repos under $HOME (depth-capped), so a fresh
          install still has something to chew on.
    """
    env = os.environ.get("NIMBUS_DREAM_REPOS")
    if env:
        return [p for p in env.split(":") if p]
    cfg = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "nimbus-dream" / "repos.txt"
    if cfg.exists():
        out = []
        for line in cfg.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                out.append(os.path.expanduser(line))
        if out:
            return out
    found = run(["find", str(HOME), "-maxdepth", "4", "-type", "d", "-name", ".git"], timeout=20)
    repos = [str(Path(p).parent) for p in found.splitlines()] if found else []
    return repos[:24]  # cap: don't scan an unbounded number of repos


def collect_git(repos, since):
    block = {"window": since, "repos": [], "total_commits": 0, "busiest_repo": None,
             "types": {}, "scopes": [], "languages": [], "authors": [], "present": False}
    sep = "\x1f"  # unit separator — safe field delimiter inside %s
    scopes, authors, lang_files = set(), set(), {}
    types_total, busiest = {}, (None, -1)

    for repo in repos:
        if not (Path(repo) / ".git").exists():
            continue
        log = run(["git", "-C", repo, "log", f"--since={since}", "--no-merges",
                   f"--pretty=format:%h{sep}%cI{sep}%an{sep}%s"], timeout=20)
        if not log:
            continue
        lines = [l for l in log.splitlines() if l.strip()]
        if not lines:
            continue
        subjects, rtypes, first, last = [], {}, None, None
        for line in lines:
            parts = line.split(sep)
            if len(parts) < 4:
                continue
            _h, ciso, an, subj = parts[0], parts[1], parts[2], sep.join(parts[3:])
            authors.add(an)
            first = ciso if first is None else min(first, ciso)
            last = ciso if last is None else max(last, ciso)
            t, sc = parse_conventional(subj)
            if t:
                rtypes[t] = rtypes.get(t, 0) + 1
                types_total[t] = types_total.get(t, 0) + 1
                for s in sc:
                    scopes.add(s)
            if len(subjects) < SUBJECTS_PER_REPO:
                subjects.append(subj[:SUBJECT_MAX])
        # numstat → files touched per language (counts only, no contents)
        stat = run(["git", "-C", repo, "log", f"--since={since}", "--no-merges",
                    "--numstat", "--pretty=format:"], timeout=20)
        ins = dele = files = 0
        if stat:
            for row in stat.splitlines():
                cols = row.split("\t")
                if len(cols) != 3:
                    continue
                a, d, path = cols
                files += 1
                ins += int(a) if a.isdigit() else 0
                dele += int(d) if d.isdigit() else 0
                lang = language_for(path)
                lang_files[lang] = lang_files.get(lang, 0) + 1
        n = len(lines)
        block["repos"].append({
            "path": repo, "name": Path(repo).name, "commits": n,
            "first_commit": first, "last_commit": last,
            "types": rtypes, "subjects": subjects,
            "insertions": ins, "deletions": dele, "files_touched": files,
        })
        block["total_commits"] += n
        if n > busiest[1]:
            busiest = (Path(repo).name, n)

    block["present"] = block["total_commits"] > 0
    block["busiest_repo"] = busiest[0]
    block["types"] = dict(sorted(types_total.items(), key=lambda kv: -kv[1]))
    block["scopes"] = sorted(scopes)
    block["authors"] = sorted(authors)
    block["languages"] = [{"lang": k, "files": v}
                          for k, v in sorted(lang_files.items(), key=lambda kv: -kv[1])]
    return block


# --------------------------------------------------------------------------- #
# clock — the mood seed
# --------------------------------------------------------------------------- #

def collect_clock(now):
    return {
        "now_local": now.isoformat(timespec="seconds"),
        "weekday": now.strftime("%A"),
        "is_weekend": now.weekday() >= 5,
        "hour": now.hour,
        "time_of_day": time_of_day(now.hour),
    }


# --------------------------------------------------------------------------- #
# session — active hours
# --------------------------------------------------------------------------- #

def collect_session(now, git_block):
    login = boot = None
    sid = run(["bash", "-c", "loginctl list-sessions --no-legend | awk 'NR==1{print $1}'"])
    if sid:
        ts = run(["loginctl", "show-session", sid, "-p", "Timestamp", "--value"])
        login = ts or None
    boot = run(["bash", "-c", "who -b | awk '{print $3, $4}'"]) or None
    # active span: earliest commit today (best signal of when work began) → now
    firsts = [r["first_commit"] for r in git_block["repos"] if r.get("first_commit")]
    lasts = [r["last_commit"] for r in git_block["repos"] if r.get("last_commit")]
    active_since = min(firsts) if firsts else None
    span_h = None
    if active_since:
        try:
            start = datetime.fromisoformat(active_since)
            end = datetime.fromisoformat(max(lasts)) if lasts else now.astimezone()
            span_h = round((end - start).total_seconds() / 3600.0, 1)
        except Exception:
            span_h = None
    return {"login_at": login, "boot_at": boot,
            "active_since": active_since, "active_span_hours": span_h, "present": bool(active_since)}


# --------------------------------------------------------------------------- #
# audio + windows — live bridge snapshots (+ optional sampler dwell)
# --------------------------------------------------------------------------- #

def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return None


def collect_audio(path=AURORA / "audio.json"):
    v = read_json(path)
    if not v:
        return {"present": False, "playing_now": None, "level": None}
    level = float(v.get("level", 0.0) or 0.0)
    return {"present": True, "level": round(level, 3), "playing_now": level > AUDIO_ON}


def collect_windows(path=AURORA / "windows.json"):
    v = read_json(path)
    if not v or "wins" not in v:
        return {"present": False, "count": None, "layout": None}
    wins = v.get("wins") or []
    sw = max((w.get("x", 0) + w.get("w", 0) for w in wins), default=1.0) or 1.0
    sh = max((w.get("y", 0) + w.get("h", 0) for w in wins), default=1.0) or 1.0
    active = next((w for w in wins if w.get("active")), None)
    frac = None
    if active and sw and sh:
        frac = round((active.get("w", 0) * active.get("h", 0)) / (sw * sh), 2)
    ultrawide = (sw / sh) > 2.1 if sh else False
    if len(wins) <= 1:
        shape = "single"
    elif frac is not None and frac > 0.7:
        shape = "single-focused"
    elif len(wins) >= 4:
        shape = "busy"
    else:
        shape = "multi-window"
    layout = f"{shape} (ultrawide)" if ultrawide else shape
    return {"present": True, "count": len(wins), "screen": [round(sw), round(sh)],
            "active_area_fraction": frac, "layout": layout}


def collect_sampler(date_str, state=STATE):
    """Read today's sampler NDJSON (if the timer has been running): audio-active
    fraction + busiest hour from the accumulated shape ticks. Absent → graceful."""
    path = state / "signals" / f"signals-{date_str}.ndjson"
    if not path.exists():
        return {"present": False}
    ticks, audio_on, hours = 0, 0, {}
    try:
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            t = json.loads(line)
            ticks += 1
            if float(t.get("audio", 0.0) or 0.0) > AUDIO_ON:
                audio_on += 1
            ms = t.get("ts")
            if ms:
                h = datetime.fromtimestamp(ms / 1000.0).hour
                hours[h] = hours.get(h, 0) + 1
    except Exception:
        pass
    if ticks == 0:
        return {"present": False}
    peak = max(hours.items(), key=lambda kv: kv[1])[0] if hours else None
    return {"present": True, "ticks": ticks,
            "audio_active_fraction": round(audio_on / ticks, 2),
            "peak_hour": peak}


# --------------------------------------------------------------------------- #
# summary — the compact, grounded `from_signals` the model may cite
# --------------------------------------------------------------------------- #

def build_summary(clock, git_block, session, audio, windows, sampler):
    lines = []
    if git_block["present"]:
        nrepos = len([r for r in git_block["repos"] if r["commits"]])
        types = ", ".join(f"{t}×{n}" for t, n in list(git_block["types"].items())[:4])
        scope = f" (scopes: {', '.join(git_block['scopes'][:4])})" if git_block["scopes"] else ""
        lines.append(f"git: {git_block['total_commits']} commits across {nrepos} repo"
                     f"{'s' if nrepos != 1 else ''}"
                     f"{' — ' + types if types else ''}{scope}")
        if git_block["busiest_repo"]:
            lines.append(f"focus: {git_block['busiest_repo']}")
        langs = ", ".join(l["lang"] for l in git_block["languages"][:5])
        if langs:
            lines.append(f"languages: {langs}")
    else:
        lines.append("git: no commits in the window")
    if session.get("active_since") and session.get("active_span_hours") is not None:
        since = session["active_since"][11:16]
        lines.append(f"active ~{session['active_span_hours']}h (since {since})")
    lines.append(f"{clock['weekday']} {clock['time_of_day']}"
                 f"{' (weekend)' if clock['is_weekend'] else ''}")
    if sampler.get("present"):
        lines.append(f"music: ~{int(sampler['audio_active_fraction'] * 100)}% of the day")
    elif audio.get("playing_now"):
        lines.append("music: playing now")
    else:
        lines.append("music: quiet")
    if windows.get("present"):
        lines.append(f"workspace: {windows['count']} windows, {windows['layout']}")
    return lines


# --------------------------------------------------------------------------- #
# the LIVE rich collector
# --------------------------------------------------------------------------- #

def collect(now: Optional[datetime] = None, repos: Optional[list[str]] = None,
            since: str = "midnight") -> dict:
    """Gather every signal into a rich day-digest (live path). `now`/`repos` injectable
    for testing. Returns the rich blocks AND flat compat aliases (`date`/`intensity`/
    `part_of_day`/`music_active`/`windows_open`/`git.commits`) the composer reads."""
    now = (now or datetime.now()).astimezone()
    date_str = now.strftime("%Y-%m-%d")
    repos = repos if repos is not None else discover_repos()

    git_block = collect_git(repos, since)
    clock = collect_clock(now)
    session = collect_session(now, git_block)
    audio = collect_audio()
    windows = collect_windows()
    sampler = collect_sampler(date_str)
    summary = build_summary(clock, git_block, session, audio, windows, sampler)

    return {
        # --- flat compat aliases (what compose.py + assemble() read directly) ---
        "date": date_str,
        "weekday": clock["weekday"],
        "hour": clock["hour"],
        "part_of_day": clock["time_of_day"],
        "intensity": _intensity(git_block["total_commits"]),
        "music_active": bool(audio.get("playing_now")),
        "windows_open": windows.get("count") or 0,
        # --- rich blocks ---
        "git": {**git_block, "commits": git_block["total_commits"]},
        "time": clock,
        "session": session,
        "audio": audio,
        "windows": windows,
        "sampler": sampler,
        "summary": summary,
        "meta": {
            "generated_at": now.isoformat(timespec="seconds"),
            "host": os.uname().nodename,
            "collector": "collect_digest.py",
            "window_since": since,
            "date": date_str,
            "repos_scanned": repos,
        },
    }


if __name__ == "__main__":
    print(json.dumps(collect(), indent=2))
