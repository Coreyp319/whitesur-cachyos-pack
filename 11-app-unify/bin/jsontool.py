#!/usr/bin/env python3
"""Surgically merge / restore keys in a JSON config file, snapshotting priors.

Used by Layer 11 to set a couple of keys in browser/Electron JSON configs
(Chromium `Preferences`, VS Code `settings.json`) WITHOUT clobbering everything
else the app stores there, and to put it all back exactly on revert.

  jsontool.py apply   [--flat] TARGET SNAPSHOT CHANGES_JSON
  jsontool.py restore [--flat] TARGET SNAPSHOT

--flat : each change key is one literal top-level key. VS Code settings.json is
         a FLAT map whose keys contain dots ("window.titleBarStyle"), so the dot
         must NOT be read as nesting. Without --flat (the default), a dotted key
         is a nested path: "browser.custom_chrome_frame" -> obj["browser"]["custom_chrome_frame"]
         (Chromium Preferences).

apply records, per key it touches, whether the key already existed and its prior
value into SNAPSHOT — but only the FIRST time (it won't overwrite a saved prior
with our own injected value), so re-running apply is idempotent. restore reads
SNAPSHOT, puts every key back (or deletes keys that were absent before), writes
TARGET, then removes SNAPSHOT.

Exits non-zero WITHOUT touching TARGET if TARGET exists but isn't strict JSON
(e.g. a settings.json with // comments) — the caller warns and skips, never
corrupting a file it can't safely parse.
"""
import json
import os
import sys


def _parts(key, flat):
    return [key] if flat else key.split(".")


def _get(obj, parts):
    """Return (present, value) for the nested path `parts` in `obj`."""
    cur = obj
    for p in parts:
        if not isinstance(cur, dict) or p not in cur:
            return False, None
        cur = cur[p]
    return True, cur


def _set(obj, parts, value):
    cur = obj
    for p in parts[:-1]:
        nxt = cur.get(p)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[p] = nxt
        cur = nxt
    cur[parts[-1]] = value


def _del(obj, parts):
    # Descend to the leaf's parent, remembering the chain so we can prune any
    # intermediate dict that apply() created and that we're now emptying again
    # (e.g. apply added extensions.theme.system_theme to a profile with no
    # `theme` key — restore must leave no empty `theme: {}` behind).
    chain = []
    cur = obj
    full_path = True
    for p in parts[:-1]:
        if isinstance(cur, dict) and isinstance(cur.get(p), dict):
            chain.append((cur, p))
            cur = cur[p]
        else:
            full_path = False
            break
    if isinstance(cur, dict):
        cur.pop(parts[-1], None)
    if not full_path:
        return
    for parent, key in reversed(chain):  # bottom-up: drop now-empty ancestors
        child = parent.get(key)
        if isinstance(child, dict) and not child:
            del parent[key]
        else:
            break


def _load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _atomic_write(path, obj, flat):
    tmp = path + ".nimbus-tmp"
    # Indented for human-edited files (VS Code); compact for machine files
    # (Chromium re-minifies on next launch anyway).
    if flat:
        text = json.dumps(obj, indent=4, ensure_ascii=False)
    else:
        text = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    if os.path.exists(path):
        os.chmod(tmp, os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)


def cmd_apply(flat, target, snapshot, changes_json):
    if not os.path.exists(target):
        return 0  # nothing to merge into
    obj = _load(target)
    snap = _load(snapshot) if os.path.exists(snapshot) else {}
    changes = json.loads(changes_json)
    for key, newval in changes.items():
        if key not in snap:  # first-seen prior only -> idempotent re-apply
            present, prior = _get(obj, _parts(key, flat))
            snap[key] = {"had": True, "value": prior} if present else {"had": False}
        _set(obj, _parts(key, flat), newval)
    os.makedirs(os.path.dirname(snapshot), exist_ok=True)
    _atomic_write(snapshot, snap, flat=True)
    _atomic_write(target, obj, flat)
    return 0


def cmd_restore(flat, target, snapshot):
    if not os.path.exists(snapshot):
        return 0
    snap = _load(snapshot)
    if os.path.exists(target):
        obj = _load(target)
        for key, rec in snap.items():
            if rec.get("had"):
                _set(obj, _parts(key, flat), rec.get("value"))
            else:
                _del(obj, _parts(key, flat))
        _atomic_write(target, obj, flat)
    os.remove(snapshot)
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    mode = argv[1]
    rest = argv[2:]
    flat = False
    if rest and rest[0] == "--flat":
        flat = True
        rest = rest[1:]
    try:
        if mode == "apply" and len(rest) == 3:
            return cmd_apply(flat, rest[0], rest[1], rest[2])
        if mode == "restore" and len(rest) == 2:
            return cmd_restore(flat, rest[0], rest[1])
    except (json.JSONDecodeError, OSError) as exc:
        sys.stderr.write("jsontool: %s\n" % exc)
        return 1
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
