#!/usr/bin/env python3
"""Guardrail enforcer for the daily UI audit. The LLM proposes; THIS disposes.

v2 redesign — the trust boundary now reaches past writes:

  * STATE-BOUND  — ops are validated against the collector's state.json (passed
                   with --state, now mandatory and actually read). An op's
                   current_asserted MUST equal the snapshot value (or null iff
                   the key was absent), AND the live value must still match the
                   snapshot (else the world moved since collection -> reject).
                   A key the collector never read can't be touched. This makes
                   grounding mechanical, not advisory.
  * EARNED AUTO  — the allowlist marks a key auto-CAPABLE, but nothing
                   auto-applies until you've approved that key at least once
                   (`--approve <pending_id>` records `accepted`, which both
                   applies it and graduates the key to auto). Until then,
                   auto-capable keys are STAGED like everything else. Autonomy
                   is earned, not preset. A low-confidence op also stages.
  * RESPECTS YOU — dedup keys on (file,group,key). A `wontfix` is final. And if
                   you manually reverted a prior change (live != last committed
                   value) and the agent proposes that same value again, it's
                   skipped as a soft veto — no JSONL ritual required.
  * REVERSIBLE   — each touched file is backed up ONCE per run (true pre-run
                   state) with a manifest; `--revert <run_id>` restores them.
  * HONEST       — auto writes trigger the right reload where one exists (kwin
                   reconfigure); kdeglobals changes are labelled "effective next
                   session" rather than claimed as live.
  * DETERMINISTIC REPORT — emits report.md from the structured results + the
                   state diff. The agent relays THIS, not its own prose, so the
                   human-read artifact is grounded too.
  * ROBUST INPUT — tolerant ops parsing (extracts JSON from prose-wrapped model
                   output) and per-op field validation; malformed ops are
                   surfaced, not silently dropped.

Modes:
    --apply             write/stage (default: dry-run, writes nothing)
    --approve <id>      apply a staged pending op and mark its key earned
    --revert <run_id>   restore every file a run backed up

Usage:
    ui-audit-apply.py --ops OPS.json --state STATE.json [--apply]
    ui-audit-apply.py --approve <pending_id>
    ui-audit-apply.py --revert <run_id>
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
RUNTIME = HOME / ".hermes" / "ui-audit"
LEDGER = RUNTIME / "ledger.jsonl"
PENDING = RUNTIME / "pending"
BACKUPS = RUNTIME / "backups"
STATE = RUNTIME / "state" / "state.json"
PREV_STATE = RUNTIME / "state" / "state.prev.json"
REPORT = RUNTIME / "report.md"
USAGE = RUNTIME / "usage" / "usage.json"  # optional, advisory ranking signal

CONFIDENCE_FLOOR = 0.6  # auto-apply needs at least this; missing confidence stages

# (file, group, key) -> max tier. "auto" = auto-CAPABLE (still must be earned).
# Anything absent is DENIED.
ALLOWLIST = {
    ("kdeglobals", "General", "AnimationDurationFactor"): "auto",
    ("kdeglobals", "KDE", "AnimationDurationFactor"): "auto",
    ("kdeglobals", "KDE", "contrast"): "auto",
    ("kdeglobals", "General", "Font"): "propose",
    ("kdeglobals", "General", "menuFont"): "propose",
    ("kdeglobals", "General", "toolBarFont"): "propose",
    ("kdeglobals", "General", "smallestReadableFont"): "propose",
    ("kdeglobals", "WM", "activeFont"): "propose",
    ("kwinrc", "Plugins", "blurEnabled"): "propose",
    ("kwinrc", "Plugins", "contrastEnabled"): "propose",
}
DENY_REASON = {
    "ColorScheme": "load-bearing — stabilised; changing it risks the duplicate-key / toggle regressions",
    "LookAndFeelPackage": "load-bearing — its defaults re-assert colours on login",
    "widgetStyle": "load-bearing — Kvantum integration depends on it",
    "theme": "load-bearing — Kvantum/decoration theme is scheme-coupled",
}


def validate_value(key: str, value: str) -> str:
    if key == "AnimationDurationFactor":
        try:
            f = float(value)
        except ValueError:
            return "must be a number"
        return "" if 0.0 <= f <= 5.0 else "out of range 0..5"
    if key == "contrast":
        try:
            n = int(value)
        except ValueError:
            return "must be an integer"
        return "" if 0 <= n <= 10 else "out of range 0..10"
    if key in {"blurEnabled", "contrastEnabled"}:
        return "" if value.lower() in {"true", "false"} else "must be true/false"
    if key.endswith("Font") or key == "Font":
        return "" if value.count(",") >= 9 else "not a valid Plasma font string"
    return ""


# ---------------------------------------------------------------------------
# config IO
# ---------------------------------------------------------------------------

def kread(file, group, key):
    r = subprocess.run(["kreadconfig6", "--file", file, "--group", group, "--key", key],
                       capture_output=True, text=True, timeout=10)
    v = r.stdout.rstrip("\n")
    return v if v != "" else None


def kwrite(file, group, key, value) -> bool:
    r = subprocess.run(["kwriteconfig6", "--file", file, "--group", group,
                        "--key", key, value], capture_output=True, text=True, timeout=10)
    return r.returncode == 0


def config_path(file) -> Path:
    return Path(file) if file.startswith("/") else HOME / ".config" / file


def reload_for(file) -> str:
    """Trigger a live reload where one exists; return an honest effect label."""
    if file == "kwinrc":
        subprocess.run(["qdbus6", "org.kde.KWin", "/KWin", "reconfigure"],
                       capture_output=True, timeout=10)
        return "live (kwin reconfigured)"
    return "written — effective next session/relogin (no safe live reload)"


# ---------------------------------------------------------------------------
# state binding
# ---------------------------------------------------------------------------

def load_state(path: Path):
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def snapshot_entry(state, file, group, key):
    """Return (value, present, in_snapshot) for a key from state.raw."""
    if not state:
        return (None, False, False)
    e = state.get("raw", {}).get(f"{file}:{group}:{key}")
    if e is None:
        return (None, False, False)
    return (e.get("value"), bool(e.get("present")), True)


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


def _key_recs(recs, tup):
    return [r for r in recs if (r.get("file"), r.get("group"), r.get("key")) == tup]


def latest_status(recs, tup):
    kr = _key_recs(recs, tup)
    return kr[-1].get("status") if kr else None


def is_earned(recs, tup) -> bool:
    """A key is earned once the user has `accepted` it at least once."""
    return any(r.get("status") == "accepted" for r in _key_recs(recs, tup))


def last_committed_after(recs, tup):
    """`after` of the most recent applied/accepted record for this key."""
    for r in reversed(_key_recs(recs, tup)):
        if r.get("status") in {"applied", "accepted"}:
            return r.get("after")
    return None


def is_wontfixed(recs, tup) -> bool:
    return latest_status(recs, tup) == "wontfix"


# ---------------------------------------------------------------------------
# pending store
# ---------------------------------------------------------------------------

def stage_pending(op, summary) -> str:
    PENDING.mkdir(parents=True, exist_ok=True)
    pid = uuid.uuid4().hex[:8]
    rec = {"id": pid, "created_at": datetime.now(timezone.utc).isoformat(),
           "status": "pending", "summary": summary, "op": op}
    (PENDING / f"{pid}.json").write_text(json.dumps(rec, indent=2), encoding="utf-8")
    return pid


def get_pending(pid):
    p = PENDING / f"{pid}.json"
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


# ---------------------------------------------------------------------------
# backups (once per file per run) + revert
# ---------------------------------------------------------------------------

def backup_once(file, run_id, done: set) -> str:
    if file in done:
        return str(BACKUPS / run_id / file.replace("/", "_"))
    src = config_path(file)
    d = BACKUPS / run_id
    d.mkdir(parents=True, exist_ok=True)
    dst = d / file.replace("/", "_")
    if src.exists():
        shutil.copy2(src, dst)
    done.add(file)
    # maintain a manifest mapping backup filename -> real path
    man = d / "manifest.json"
    m = json.loads(man.read_text()) if man.exists() else {}
    m[file.replace("/", "_")] = str(src)
    man.write_text(json.dumps(m, indent=2))
    return str(dst)


def do_revert(run_id) -> dict:
    d = BACKUPS / run_id
    man = d / "manifest.json"
    if not man.exists():
        return {"error": f"no backup manifest for run {run_id}"}
    m = json.loads(man.read_text())
    restored = []
    for fname, realpath in m.items():
        bkp = d / fname
        if bkp.exists():
            shutil.copy2(bkp, Path(realpath))
            restored.append(realpath)
            append_ledger({"run_id": f"revert-of-{run_id}",
                           "ts": datetime.now(timezone.utc).isoformat(),
                           "status": "reverted", "file": realpath})
    return {"reverted_run": run_id, "restored": restored}


# ---------------------------------------------------------------------------
# tolerant ops parsing
# ---------------------------------------------------------------------------

def parse_ops(path: Path):
    """Return (ops, parse_error). Tolerates prose-wrapped JSON from small models."""
    text = path.read_text(encoding="utf-8")
    for attempt in (text,):
        try:
            data = json.loads(attempt)
            return _coerce_ops(data), None
        except Exception:
            pass
    # extract the first {...} or [...] block
    m = re.search(r"(\{.*\}|\[.*\])", text, re.DOTALL)
    if m:
        try:
            return _coerce_ops(json.loads(m.group(1))), None
        except Exception as e:
            return [], f"could not parse extracted JSON block: {e}"
    return [], "no JSON object/array found in ops file"


def _coerce_ops(data):
    if isinstance(data, dict):
        data = data.get("ops", [])
    return data if isinstance(data, list) else []


REQUIRED = ("file", "group", "key", "proposed")


# ---------------------------------------------------------------------------
# deterministic report
# ---------------------------------------------------------------------------

def state_diff(state, prev):
    """Keys whose snapshot value changed since the previous run."""
    if not state or not prev:
        return None
    out = []
    praw = prev.get("raw", {})
    for k, e in state.get("raw", {}).items():
        pe = praw.get(k)
        if pe is not None and pe.get("value") != e.get("value"):
            out.append((k, pe.get("value"), e.get("value")))
    return out


def load_usage(path: Path):
    """Optional usage signal. Absent/unreadable → None (no weighting; graceful)."""
    try:
        return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None
    except Exception:
        return None


def usage_weight(rec, usage):
    """ADVISORY ranking weight in [~0.3, ~1.5]. Only reorders the report — never
    changes guardrail decisions (allowlist/assertion/earned-auto are upstream)."""
    if not usage:
        return 1.0
    w = 1.0
    fb = (usage.get("feedback", {}).get("by_class", {}) or {}).get(rec.get("class"))
    if fb:
        ar = fb.get("approval_rate")
        if ar is not None:
            w *= 0.6 + 0.8 * ar          # ar 0→0.6, 1→1.4: surface what you accept
        if fb.get("vetoes"):
            w *= 0.6                      # you reverted this class before → lower
    key = rec.get("key", "")
    tk = usage.get("toolkit_hint", {}) or {}
    if key.endswith("Font") or key == "Font" or key == "contrast":
        w *= 0.7 + (tk.get("qt", 0) + tk.get("gtk", 0))   # text matters more if Qt/GTK-heavy
    return w


def build_report(run_id, mode, results, state, prev, usage=None):
    L = [f"# Daily UI audit — {run_id} ({mode})", ""]
    diff = state_diff(state, prev)
    L.append("## Changed since last run")
    if diff is None:
        L.append("- (no previous snapshot to compare)")
    elif not diff:
        L.append("- nothing changed")
    else:
        for k, a, b in diff:
            L.append(f"- `{k}`: `{a}` → `{b}`  — intended?")
    applied = [r for r in results if r["status"] in ("applied", "dry-auto")]
    staged = [r for r in results if r["status"] in ("staged", "dry-propose")]
    L += ["", "## Applied this run"]
    if not applied:
        L.append("- nothing auto-applied")
    for r in applied:
        verb = "would auto-apply" if r["status"] == "dry-auto" else "applied"
        L.append(f"- {verb} `{r['key']}` `{r['before']}`→`{r['after']}` "
                 f"({r.get('effect','')}) — {r.get('rationale','')}")
    # Always rank by confidence; usage (when present) MULTIPLIES the weight
    # (usage_weight returns 1.0 when usage is None → pure confidence order).
    # Usage is advisory: the SET of staged items is identical with/without it —
    # only the order and the "one thing" pick change.
    staged = sorted(staged, key=lambda r: (r.get("confidence") or 0.5) * usage_weight(r, usage),
                    reverse=True)
    L += ["", "## Awaiting your approval (staged)"]
    if not staged:
        L.append("- nothing staged")
    for r in staged:
        pid = r.get("pending_id", "")
        L.append(f"- `{r['key']}` `{r['before']}`→`{r['after']}` — {r.get('rationale','')}"
                 + (f"  [approve: --approve {pid}]" if pid else ""))
    rejected = [r for r in results if r["status"].startswith(("rejected", "skipped"))]
    if rejected:
        L += ["", "## Skipped / rejected"]
        for r in rejected:
            L.append(f"- {r['status']} `{r.get('key')}`: {r['message']}")
    if usage:
        top = ", ".join(e["app"] for e in (usage.get("app_scores") or [])[:3]) or "—"
        L += ["", "## Focus", f"- ranked toward your most-used apps: {top}"]
        vetoed = [c for c, f in (usage.get("feedback", {}).get("by_class", {}) or {}).items()
                  if f.get("vetoes")]
        if vetoed:
            L.append(f"- down-ranked (you reverted these before): {', '.join(vetoed)}")
    one = staged[0] if staged else None
    L += ["", "## One thing worth doing"]
    L.append(f"- {one['key']}: {one.get('rationale','')}" if one else "- nothing actionable today")
    return "\n".join(L) + "\n"


# ---------------------------------------------------------------------------

def process_ops(ops, state, prev, dry, max_auto, conf_floor):
    recs_hist = load_ledger()
    run_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    results = []
    auto_done = 0
    backed = set()

    def record(op, status, msg, **extra):
        rec = {"run_id": run_id, "ts": datetime.now(timezone.utc).isoformat(),
               "file": op.get("file"), "group": op.get("group"), "key": op.get("key"),
               "class": op.get("class", "unclassified"),
               "before": op.get("current_asserted"), "after": str(op.get("proposed", "")),
               "status": status, "rationale": op.get("rationale", ""),
               "confidence": op.get("confidence"), "message": msg, **extra}
        if not dry and status not in ("dry-auto", "dry-propose"):
            append_ledger(rec)
        results.append(rec)

    for op in ops:
        missing = [f for f in REQUIRED if op.get(f) in (None, "")]
        if missing:
            record(op, "rejected-malformed", f"missing fields: {missing}")
            continue
        file, group, key = op["file"], op["group"], op["key"]
        proposed = str(op["proposed"])
        asserted = op.get("current_asserted")
        conf = op.get("confidence")
        tup = (file, group, key)

        tier = ALLOWLIST.get(tup)
        if tier is None:
            record(op, "rejected-denied",
                   f"DENY {file}:{group}:{key} — {DENY_REASON.get(key, 'not on the allowlist')}")
            continue
        if is_wontfixed(recs_hist, tup):
            record(op, "skipped-ledger", "skip — marked wontfix"); continue

        live = kread(file, group, key)
        if (live or "") == proposed:
            record(op, "skipped-noop", "skip — already at the proposed value"); continue

        # soft veto: user manually reverted a prior change; don't re-impose it
        lca = last_committed_after(recs_hist, tup)
        if lca is not None and (live or "") != str(lca) and proposed == str(lca):
            record(op, "skipped-veto",
                   "skip — you changed this back manually; not re-imposing"); continue

        # state binding (mandatory, bound to the snapshot)
        sv, present, in_snap = snapshot_entry(state, file, group, key)
        if not in_snap:
            record(op, "rejected-unsnapshotted",
                   "REJECT — key not in state.json (collector never read it)"); continue
        if present:
            if asserted is None or str(asserted) != str(sv):
                record(op, "rejected-assertion",
                       f"REJECT — current_asserted={asserted!r} != snapshot {sv!r}"); continue
            if (live or "") != str(sv):
                record(op, "rejected-drift",
                       f"REJECT — live={live!r} != snapshot {sv!r}; re-run the collector"); continue
        else:
            if asserted not in (None, ""):
                record(op, "rejected-assertion",
                       f"REJECT — key absent in snapshot but current_asserted={asserted!r}"); continue
            if live is not None:
                record(op, "rejected-drift",
                       f"REJECT — snapshot had key absent but live={live!r}; re-run collector"); continue

        bad = validate_value(key, proposed)
        if bad:
            record(op, "rejected-sanity", f"REJECT — proposed {proposed!r}: {bad}"); continue

        earned = is_earned(recs_hist, tup)
        low_conf = (conf is None) or (conf < conf_floor)
        auto_ok = (tier == "auto") and earned and not low_conf

        if not auto_ok:
            why = []
            if tier == "auto" and not earned:
                why.append("auto-capable but not yet earned — approve once to graduate")
            if tier == "auto" and low_conf:
                why.append(f"confidence {conf} < {conf_floor}")
            if dry:
                record(op, "dry-propose", f"would STAGE: {key} {live!r}->{proposed!r}"
                       + (f" ({'; '.join(why)})" if why else ""))
            else:
                pid = stage_pending(op, f"{file}:{group}:{key} {live!r}->{proposed!r}")
                record(op, "staged", f"staged pending/{pid}"
                       + (f" ({'; '.join(why)})" if why else ""), pending_id=pid)
            continue

        # auto path
        if auto_done >= max_auto:
            record(op, "skipped-cap", f"skip — auto cap ({max_auto}) reached"); continue
        if dry:
            record(op, "dry-auto", f"would APPLY: {key} {live!r}->{proposed!r}",
                   effect="(dry-run)"); auto_done += 1; continue
        bkp = backup_once(file, run_id, backed)
        if not kwrite(file, group, key, proposed):
            record(op, "error", "kwriteconfig6 failed", backup=bkp); continue
        now = kread(file, group, key)
        if (now or "") != proposed:
            if bkp and Path(bkp).exists():
                shutil.copy2(bkp, config_path(file))
            record(op, "error", f"verify failed (got {now!r}); backup restored", backup=bkp); continue
        effect = reload_for(file)
        auto_done += 1
        record(op, "applied", f"APPLIED {key} {asserted!r}->{proposed!r}",
               backup=bkp, effect=effect)

    return run_id, results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ops")
    ap.add_argument("--state", default=str(STATE))
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--max-auto", type=int, default=6)
    ap.add_argument("--confidence-floor", type=float, default=CONFIDENCE_FLOOR)
    ap.add_argument("--approve", metavar="PENDING_ID")
    ap.add_argument("--revert", metavar="RUN_ID")
    ap.add_argument("--usage", default=str(USAGE),
                    help="optional usage.json for advisory ranking (absent = no weighting)")
    args = ap.parse_args()

    # --- revert mode ---
    if args.revert:
        print(json.dumps(do_revert(args.revert), indent=2)); return

    # --- approve mode: apply a staged op + mark its key earned ---
    if args.approve:
        rec = get_pending(args.approve)
        if not rec:
            print(json.dumps({"error": f"no pending op {args.approve}"})); return
        op = rec["op"]
        file, group, key = op["file"], op["group"], op["key"]
        proposed = str(op["proposed"])
        run_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        bkp = backup_once(file, run_id, set())
        ok = kwrite(file, group, key, proposed)
        now = kread(file, group, key)
        if not ok or (now or "") != proposed:
            if bkp and Path(bkp).exists():
                shutil.copy2(bkp, config_path(file))
            print(json.dumps({"error": "approve: write/verify failed; restored"})); return
        append_ledger({"run_id": run_id, "ts": datetime.now(timezone.utc).isoformat(),
                       "file": file, "group": group, "key": key,
                       "class": op.get("class", "unclassified"),
                       "before": op.get("current_asserted"), "after": proposed,
                       "status": "accepted", "effect": reload_for(file),
                       "rationale": op.get("rationale", ""), "pending_id": args.approve})
        (PENDING / f"{args.approve}.json").unlink(missing_ok=True)
        print(json.dumps({"approved": args.approve, "applied": f"{key}={proposed}",
                          "note": "key is now EARNED — eligible for auto next run"}, indent=2))
        return

    # --- normal audit-apply ---
    if not args.ops:
        ap.error("--ops is required (unless --approve/--revert)")
    state = load_state(Path(args.state))
    if state is None:
        print(json.dumps({"error": f"state.json not found at {args.state}; run the collector first"}))
        return
    prev = load_state(PREV_STATE)
    ops, perr = parse_ops(Path(args.ops))
    if perr:
        print(json.dumps({"error": f"ops parse failed: {perr}"})); return

    dry = not args.apply
    run_id, results = process_ops(ops, state, prev, dry, args.max_auto, args.confidence_floor)

    usage = load_usage(Path(args.usage))
    report = build_report(run_id, "dry-run" if dry else "apply", results, state, prev, usage)
    if not dry:
        RUNTIME.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(report, encoding="utf-8")

    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print(json.dumps({"run_id": run_id, "mode": "dry-run" if dry else "apply",
                      "counts": counts, "ops_seen": len(ops)}, indent=2))
    print("\n" + report)


if __name__ == "__main__":
    main()
