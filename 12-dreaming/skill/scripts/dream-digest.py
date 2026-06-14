#!/usr/bin/env python3
"""Day-digest collector for the dreaming composer. LOCAL-ONLY, no network.

Reduces "yesterday" to a compact, grounded `digest.json` the model dresses into a
scene. Four signals, each **present-gated** so a quiet day reads as quiet instead of
being confabulated (the discipline from `6-local-ai/ui-audit/ui-audit-collect.py`):

  git   → structure   commit volume / churn / active repos  (counts only)
  music → palette/mood audio energy + MPRIS playback/genre   (no titles/artists)
  apps  → motifs       KActivities app-level scores           (no resources/paths)
  time  → light/length active hours from the login session

PRIVACY CONTRACT (enforced by what this reads, not by promises):
  git:   commit COUNTS + shortstat numbers + repo BASENAMES. Never messages, never
         diffs, never file paths.
  music: numeric FFT stats from the Layer-9 audio bridge + PlaybackStatus + genre
         tags only. Never track titles or artists.
  apps:  `initiatingAgent` app ids + counts (lifted from ui-audit-usage.py). Never
         `targettedResource` (files/URLs). DB opened read-only.
  time:  session login timestamp → active hours. No keystrokes, no window titles.
  No network. Run network-isolated in production (run-sandboxed.sh).

Usage:
    dream-digest.py [--since "24 hours ago"] [--repos FILE] [--print]
Env:
    NIMBUS_DREAM_HOME   runtime dir (default ~/.hermes/dreaming)
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
RUNTIME = Path(os.environ.get("NIMBUS_DREAM_HOME", HOME / ".hermes" / "dreaming"))
DIGEST_DIR = RUNTIME / "digest"
DIGEST = DIGEST_DIR / "digest.json"
PREV_DIGEST = DIGEST_DIR / "digest.prev.json"

RUNTIME_XDG = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
AUDIO_JSON = RUNTIME_XDG / "nimbus-aurora" / "audio.json"
KACT_DB = HOME / ".local/share/kactivitymanagerd/resources/database"
REPOS_CFG = HOME / ".config" / "nimbus" / "dream-repos.txt"

# app id → coarse toolkit (lifted from ui-audit-usage.py); default qt.
TOOLKIT = {
    "firefox": "web", "chromium": "web", "chrome": "web", "brave": "web",
    "google-chrome": "web", "vivaldi": "web",
    "konsole": "terminal", "yakuake": "terminal", "alacritty": "terminal",
    "kitty": "terminal", "wezterm": "terminal", "foot": "terminal",
    "code": "editor", "code-oss": "editor", "vscodium": "editor",
    "gimp": "creative", "inkscape": "creative", "blender": "creative", "krita": "creative",
}


def run(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else ""
    except Exception:
        return ""


def app_name(agent: str) -> str:
    a = (agent or "").strip()
    if "/" in a:
        a = a.rsplit("/", 1)[-1]
    if a.endswith(".desktop"):
        a = a[:-8]
    if a.startswith("org.kde."):
        a = a[len("org.kde."):]
    return a.lower()


# ---------------------------------------------------------------------------
# git → structure
# ---------------------------------------------------------------------------

def discover_repos():
    if REPOS_CFG.exists():
        return [Path(p.strip()).expanduser() for p in REPOS_CFG.read_text().splitlines()
                if p.strip() and not p.startswith("#")]
    repos, seen = [], set()
    parents = [HOME] + [HOME / d for d in ("src", "code", "projects", "dev", "work", "git", "repos")]
    for parent in parents:
        if not parent.is_dir():
            continue
        try:
            for child in sorted(parent.iterdir()):
                if (child / ".git").exists() and child not in seen:
                    seen.add(child)
                    repos.append(child)
        except PermissionError:
            continue
    return repos[:40]  # bounded


def collect_git(since: str):
    repos = discover_repos()
    commits = files = ins = dels = 0
    active, busiest, busiest_n = [], None, 0
    for repo in repos:
        log = run(["git", "-C", str(repo), "log", f"--since={since}",
                   "--no-merges", "--pretty=%H"])
        n = len([l for l in log.splitlines() if l.strip()])
        if n == 0:
            continue
        active.append(repo.name)
        commits += n
        if n > busiest_n:
            busiest_n, busiest = n, repo.name
        stat = run(["git", "-C", str(repo), "log", f"--since={since}",
                    "--no-merges", "--shortstat", "--pretty=tformat:"])
        for line in stat.splitlines():
            if "file" in line:
                for tok, kind in (("insertion", "ins"), ("deletion", "del"), ("changed", "file")):
                    for part in line.split(","):
                        if tok in part:
                            num = "".join(c for c in part if c.isdigit())
                            if num:
                                if kind == "ins":
                                    ins += int(num)
                                elif kind == "del":
                                    dels += int(num)
                                else:
                                    files += int(num)
    return {"present": commits > 0, "commits": commits, "files_touched": files,
            "insertions": ins, "deletions": dels, "repos_active": active,
            "busiest_repo": busiest, "repos_scanned": len(repos)}


# ---------------------------------------------------------------------------
# music → palette / mood
# ---------------------------------------------------------------------------

def mpris_players():
    out = run(["qdbus6"]) or run(["qdbus"])
    return [l.strip() for l in out.splitlines() if "org.mpris.MediaPlayer2." in l]


def mpris_prop(service, prop):
    return run(["qdbus6", service, "/org/mpris/MediaPlayer2",
                "org.freedesktop.DBus.Properties.Get",
                "org.mpris.MediaPlayer2.Player", prop]).strip()


def collect_music():
    energy = {}
    if AUDIO_JSON.exists():
        try:
            energy = json.loads(AUDIO_JSON.read_text())
        except Exception:
            energy = {}
    playing, genres = False, []
    for svc in mpris_players():
        if mpris_prop(svc, "PlaybackStatus") == "Playing":
            playing = True
        meta = mpris_prop(svc, "Metadata")  # multi-line key: value; we read genre ONLY
        for line in meta.splitlines():
            if "xesam:genre" in line:
                g = line.split(":", 1)[-1].strip().lower()
                if g and g not in genres:
                    genres.append(g)
    has_player = bool(mpris_players())
    return {"present": has_player or bool(energy),
            "playing": playing,
            "mean_energy": round(float(energy.get("level", 0.0)), 3),
            "bass": round(float(energy.get("bass", 0.0)), 3),
            "beatiness": round(float(energy.get("beat", 0.0)), 3),
            "genres": genres}


# ---------------------------------------------------------------------------
# apps → motifs  (lifted from ui-audit-usage.py: app-level scores ONLY)
# ---------------------------------------------------------------------------

def collect_apps():
    if not KACT_DB.exists():
        return {"present": False, "top": [], "toolkit_hint": {}}
    rows = []
    for uri in (f"file:{KACT_DB}?immutable=1", None):
        try:
            if uri:
                con = sqlite3.connect(uri, uri=True)
            else:
                tmp = Path(tempfile.mkdtemp()) / "kact.db"
                shutil.copy2(KACT_DB, tmp)
                con = sqlite3.connect(f"file:{tmp}?mode=ro", uri=True)
            cur = con.cursor()
            try:
                cur.execute("SELECT initiatingAgent, COUNT(*), COALESCE(SUM(cachedScore),0) "
                            "FROM ResourceScoreCache GROUP BY initiatingAgent")
            except sqlite3.Error:
                cur.execute("SELECT initiatingAgent, COUNT(*), 0 "
                            "FROM ResourceScoreCache GROUP BY initiatingAgent")
            rows = cur.fetchall()
            con.close()
            break
        except sqlite3.Error:
            continue
    merged = {}
    for agent, cnt, score in rows:
        name = app_name(agent)
        if not name:
            continue
        m = merged.setdefault(name, [0, 0.0])
        m[0] += int(cnt)
        m[1] += float(score)
    ranked = sorted(merged.items(), key=lambda kv: (kv[1][1], kv[1][0]), reverse=True)
    top = [{"app": n, "score": round(s or c, 2)} for n, (c, s) in ranked[:5]]
    hint = {}
    for e in top:
        hint[TOOLKIT.get(e["app"], "qt")] = round(hint.get(TOOLKIT.get(e["app"], "qt"), 0) + 1, 2)
    return {"present": bool(top), "top": top, "toolkit_hint": hint}


# ---------------------------------------------------------------------------
# time → light / length
# ---------------------------------------------------------------------------

def collect_time():
    sid = None
    for line in run(["loginctl", "list-sessions", "--no-legend"]).splitlines():
        parts = line.split()
        if len(parts) >= 1 and parts[0].strip():
            sid = parts[0].strip()
            # prefer a graphical/seat session if we can tell; else first
            if "seat" in line:
                break
    login_ts = None
    if sid:
        for line in run(["loginctl", "show-session", sid, "-p", "Timestamp"]).splitlines():
            if line.startswith("Timestamp="):
                raw = line.split("=", 1)[1].strip()
                for fmt in ("%a %Y-%m-%d %H:%M:%S %Z", "%a %Y-%m-%d %H:%M:%S"):
                    try:
                        login_ts = datetime.strptime(raw, fmt)
                        break
                    except ValueError:
                        continue
    now = datetime.now()
    hour = now.hour
    night_owl = hour >= 23 or hour < 5
    active_hours = None
    if login_ts is not None:
        delta = (now - login_ts.replace(tzinfo=None)).total_seconds() / 3600.0
        active_hours = round(min(max(delta, 0.0), 18.0), 1)
    return {"present": active_hours is not None,
            "active_hours": active_hours,
            "current_hour": hour, "first": login_ts.strftime("%H:%M") if login_ts else None,
            "last": now.strftime("%H:%M"), "night_owl": night_owl}


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", default="24 hours ago")
    ap.add_argument("--repos", help="override repo list file")
    ap.add_argument("--print", action="store_true", help="print digest to stdout (don't rotate)")
    args = ap.parse_args()
    if args.repos:
        global REPOS_CFG
        REPOS_CFG = Path(args.repos)

    digest = {
        "meta": {"digest_at": datetime.now(timezone.utc).isoformat(),
                 "since": args.since, "host": os.uname().nodename,
                 "collector": "dream-digest.py"},
        "git": collect_git(args.since),
        "music": collect_music(),
        "apps": collect_apps(),
        "time": collect_time(),
    }
    text = json.dumps(digest, indent=2)
    if args.print:
        print(text)
        return
    DIGEST_DIR.mkdir(parents=True, exist_ok=True)
    if DIGEST.exists():
        shutil.copy2(DIGEST, PREV_DIGEST)
    DIGEST.write_text(text + "\n", encoding="utf-8")
    present = [k for k in ("git", "music", "apps", "time") if digest[k].get("present")]
    print(json.dumps({"wrote": str(DIGEST), "present_signals": present}, indent=2))


if __name__ == "__main__":
    main()
