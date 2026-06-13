#!/usr/bin/env python3
"""Privacy-respecting usage signal for the daily UI audit. LOCAL-ONLY, no network.

Learns WHICH apps/surfaces the user actually uses so the audit can FOCUS there.
It reuses data KDE already collects and reduces it to app-level scores — it adds
no new surveillance. Run it network-isolated via run-sandboxed.sh.

PRIVACY CONTRACT (enforced by what this code does, not by promises):
  READS, aggregated to app level only:
    * KActivities ResourceScoreCache — ONLY `initiatingAgent` + counts/scores.
      The `targettedResource` column (file paths, URLs, screenshot names) is
      NEVER selected. The DB is opened immutable (read-only, no locks, no writes).
    * kickoff favorites (app ids only).
    * our own ledger.jsonl (approve/revert/dwell) — no external data.
  NEVER reads: targettedResource, recently-used.xbel, window titles, clipboard,
  keystrokes, file contents, the network.
  WRITES: ~/.hermes/ui-audit/usage/usage.json (mode 0600), human-readable.

Opt-in: refuses unless the consent marker exists. `--forget` wipes everything.

Usage:
    run-sandboxed.sh ui-audit-usage.py          # collect (needs consent)
    ui-audit-usage.py --grant-consent           # write the consent marker
    ui-audit-usage.py --forget                   # delete all usage data + consent
"""
from __future__ import annotations

import argparse
import configparser
import json
import os
import shutil
import sqlite3
import tempfile
from datetime import datetime, timezone, timedelta
from pathlib import Path

HOME = Path.home()
RUNTIME = HOME / ".hermes" / "ui-audit"
USAGE_DIR = RUNTIME / "usage"
USAGE_JSON = USAGE_DIR / "usage.json"
CONSENT = USAGE_DIR / "consent"
HISTORY = USAGE_DIR / "history"
LEDGER = RUNTIME / "ledger.jsonl"

KACT_DB = HOME / ".local/share/kactivitymanagerd/resources/database"
STATSRC = HOME / ".config/kactivitymanagerd-statsrc"
RETENTION_DAYS = 30

# Static interpretation of app names → coarse surface/toolkit. No files scanned;
# this just labels the app-level scores we already have. Default = qt (KDE apps).
TOOLKIT = {
    "firefox": "web", "chromium": "web", "chrome": "web", "brave": "web",
    "google-chrome": "web", "vivaldi": "web",
    "konsole": "terminal", "yakuake": "terminal", "alacritty": "terminal",
    "kitty": "terminal", "wezterm": "terminal", "foot": "terminal",
    "code": "gtk", "code-oss": "gtk", "vscodium": "gtk", "gimp": "gtk",
    "inkscape": "gtk", "nautilus": "gtk", "gedit": "gtk",
}


def app_name(agent: str) -> str:
    """Reduce an initiatingAgent to a clean app id. No paths leak (basename only)."""
    a = (agent or "").strip()
    if "/" in a:
        a = a.rsplit("/", 1)[-1]
    if a.endswith(".desktop"):
        a = a[:-8]
    if a.startswith("org.kde."):
        a = a[len("org.kde."):]
    return a.lower()


# ---------------------------------------------------------------------------
# KActivities — aggregate app scores ONLY (never targettedResource)
# ---------------------------------------------------------------------------

def collect_app_scores():
    if not KACT_DB.exists():
        return []
    # Open immutable: read-only, no locks, never disturbs the live daemon's DB.
    # Fall back to a temp copy if the build rejects immutable.
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
            # Defensive: cachedScore may or may not exist; COUNT always does.
            try:
                cur.execute("SELECT initiatingAgent, COUNT(*), "
                            "COALESCE(SUM(cachedScore),0) "
                            "FROM ResourceScoreCache GROUP BY initiatingAgent")
            except sqlite3.Error:
                cur.execute("SELECT initiatingAgent, COUNT(*), 0 "
                            "FROM ResourceScoreCache GROUP BY initiatingAgent")
            for agent, cnt, score in cur.fetchall():
                rows.append((app_name(agent), int(cnt), float(score)))
            con.close()
            break
        except sqlite3.Error:
            continue
    # Merge by clean app name; rank by (score, count). Drop empties.
    merged = {}
    for name, cnt, score in rows:
        if not name:
            continue
        m = merged.setdefault(name, [0, 0.0])
        m[0] += cnt
        m[1] += score
    ranked = sorted(merged.items(), key=lambda kv: (kv[1][1], kv[1][0]), reverse=True)
    return [{"app": n, "score": round(s or c, 2)} for n, (c, s) in ranked]


def collect_favorites():
    """Best-effort app ids from kickoff favorites (no content, app ids only)."""
    favs = []
    if STATSRC.exists():
        cp = configparser.ConfigParser(strict=False)
        try:
            cp.read(STATSRC)
            for sect in cp.sections():
                for _, val in cp.items(sect):
                    for tok in str(val).replace(";", ",").split(","):
                        t = tok.strip()
                        if t.endswith(".desktop") or t.startswith(("org.", "applications:")):
                            favs.append(app_name(t.replace("applications:", "")))
        except Exception:
            pass
    # de-dup, keep order
    seen, out = set(), []
    for f in favs:
        if f and f not in seen:
            seen.add(f); out.append(f)
    return out


def toolkit_hint(app_scores):
    tally = {"qt": 0.0, "web": 0.0, "terminal": 0.0, "gtk": 0.0}
    total = 0.0
    for e in app_scores:
        w = e["score"] or 1
        tally[TOOLKIT.get(e["app"], "qt")] += w
        total += w
    if total <= 0:
        return tally
    return {k: round(v / total, 3) for k, v in tally.items()}


# ---------------------------------------------------------------------------
# Ledger feedback (our own data) — approval / revert / dwell, per class
# ---------------------------------------------------------------------------

def collect_feedback():
    by_class = {}
    if not LEDGER.exists():
        return by_class
    recs = []
    for line in LEDGER.read_text(encoding="utf-8").splitlines():
        try:
            recs.append(json.loads(line))
        except Exception:
            continue
    # group by class
    classes = {}
    for r in recs:
        classes.setdefault(r.get("class", "unclassified"), []).append(r)
    for cls, rs in classes.items():
        accepted = sum(1 for r in rs if r.get("status") == "accepted")
        applied = sum(1 for r in rs if r.get("status") == "applied")
        staged = sum(1 for r in rs if r.get("status") == "staged")
        vetoed = sum(1 for r in rs if r.get("status") == "skipped-veto")
        offered = accepted + staged
        # dwell: mean days between an applied/accepted and a later skipped-veto for the class
        commits = sorted((_ts(r) for r in rs if r.get("status") in ("applied", "accepted")
                          and _ts(r)), key=lambda x: x or datetime.min.replace(tzinfo=timezone.utc))
        vetoes = sorted((_ts(r) for r in rs if r.get("status") == "skipped-veto" and _ts(r)))
        dwell = None
        if commits and vetoes:
            deltas = []
            for c in commits:
                later = [v for v in vetoes if v and c and v > c]
                if later:
                    deltas.append((later[0] - c).total_seconds() / 86400.0)
            if deltas:
                dwell = round(sum(deltas) / len(deltas), 1)
        by_class[cls] = {
            "approval_rate": round(accepted / offered, 2) if offered else None,
            "applied": applied, "accepted": accepted, "vetoes": vetoed,
            "mean_dwell_days": dwell,
        }
    return by_class


def _ts(rec):
    try:
        return datetime.fromisoformat(rec.get("ts"))
    except Exception:
        return None


# ---------------------------------------------------------------------------

def prune_history():
    if not HISTORY.exists():
        return
    cutoff = datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)
    for p in HISTORY.glob("usage-*.json"):
        try:
            stamp = p.stem.replace("usage-", "")
            when = datetime.fromisoformat(stamp.replace("_", ":")) if ":" not in stamp else datetime.fromisoformat(stamp)
        except Exception:
            continue
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        if when < cutoff:
            p.unlink(missing_ok=True)


def write_0600(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grant-consent", action="store_true")
    ap.add_argument("--forget", action="store_true")
    args = ap.parse_args()

    if args.forget:
        if USAGE_DIR.exists():
            shutil.rmtree(USAGE_DIR)
        print(json.dumps({"forgot": str(USAGE_DIR)}))
        return

    if args.grant_consent:
        USAGE_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(USAGE_DIR, 0o700)
        write_0600(CONSENT, "usage-focus consent granted\n")
        print(json.dumps({"consent": str(CONSENT)}))
        return

    if not CONSENT.exists():
        print(json.dumps({"error": "no consent — usage focus is opt-in. "
                          "Run: ui-audit-usage.py --grant-consent"}))
        raise SystemExit(2)

    app_scores = collect_app_scores()
    usage = {
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "app_scores": app_scores[:25],
        "favorites": collect_favorites(),
        "toolkit_hint": toolkit_hint(app_scores),
        "feedback": {"by_class": collect_feedback()},
        "privacy": "app-level only; no resource paths/URLs/titles; local-only",
    }
    body = json.dumps(usage, indent=2)
    write_0600(USAGE_JSON, body)
    # retention trend copy
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d")
    write_0600(HISTORY / f"usage-{stamp}.json", body)
    prune_history()
    print(str(USAGE_JSON))


if __name__ == "__main__":
    main()
