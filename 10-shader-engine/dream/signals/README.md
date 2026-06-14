# Dreaming — day-signal collector (Layer 10, handoff problem F)

The **input half of the dreaming pipeline** (MVP step 5a). A deterministic,
**local-only, no-LLM, no-network** tool that digests *the day* into a compact
`day-digest.json`. A Layer-6 local model later reads that digest and **dresses** it
into a journey leg manifest; the bevy composer (`scene_journey.rs`) renders the leg.

This is the *skeleton* the model fleshes out — grounded so the model can't
confabulate the day (the same anti-confabulation discipline as
`6-local-ai/ui-audit/`: it may only cite signals that appear in the digest).

```
day  ──▶  collect-signals.py  ──▶  day-digest.json  ──▶  [step 5: prompt + model]  ──▶  leg-NNN.json
              ▲
   sample-signals.py (timer)  ──▶  signals-YYYY-MM-DD.ndjson   (audio/window dwell over time)
```

## What it collects (and what it deliberately doesn't)

| Signal | Source | Notes |
|--------|--------|-------|
| **git** — commits, conventional types/scopes, languages, busiest repo | `git log --since` across known repos | The strong retrospective signal: *what you built*. Subjects truncated to 90 chars; merges dropped; **no diffs/contents** read (numstat counts + paths only). |
| **clock** — time-of-day, weekday, weekend | system clock | The leg's mood seed (dawn/morning/…/night). |
| **session** — login/boot time, active span | `loginctl`, `who -b`, earliest→latest commit | When work happened → active hours. |
| **audio** — is sound playing, % of day active | live `audio.json` bridge + sampler log | Level only (is *something* playing) — **not** track titles. |
| **windows** — count, focus/busy shape | live `windows.json` bridge + sampler log | Geometry + counts only. |

**Privacy stance:** everything stays on the machine; no network calls. No file
contents, no diffs, no window titles, no keystrokes. Commit subjects (which you
wrote yourself) are the only free text, truncated and capped.

### Known gap — app identity & track titles (honest limitation)
KWin Wayland exposes no active-window class here without extra tooling, and the
`windows.json` bridge carries **geometry only** (no `resourceClass`/caption). So
"active *apps* + dwell" and "music *played* (titles)" are **not** collected yet.
To enable them later, pick one:
- install `playerctl` (music titles/history) and/or `kdotool` (active-window class), **or**
- extend the Layer-9 window bridge KWin script to also emit
  `workspace.activeWindow.resourceClass` + `caption` into `windows.json` (a
  backward-compatible field add — existing readers ignore unknown keys).

The collector is built to fold those in the moment they exist; until then it does
not fake them. git + clock + session already give a rich, grounded day.

## Usage

```bash
cd 10-shader-engine/dream/signals

# Produce a digest now (defaults: commits since local midnight, repos auto-discovered)
python3 collect-signals.py
#   → $XDG_STATE_HOME/nimbus-dream/digests/day-digest.json   (+ dated archive)
#   → grounded summary lines printed to stderr

# Scope it explicitly
python3 collect-signals.py --since "18 hours ago" --repos "$HOME/whitesur-cachyos-pack:$HOME/src/foo"
```

**Known repos** are resolved in order: `NIMBUS_DREAM_REPOS` (`:`-separated) →
`~/.config/nimbus-dream/repos.txt` (one path per line, `#` comments) →
auto-discovery of `.git` dirs under `$HOME` (depth-capped).

### Optional: the dwell sampler (audio/window shape over time)
Records one coarse tick every 2 min so the digest can report `audio_active_fraction`
and the busiest hour. Opt-in **user** units (reversible — nothing auto-installs):

```bash
mkdir -p ~/.config/systemd/user
cp nimbus-dream-sampler.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now nimbus-dream-sampler.timer   # start sampling
# stop + remove:
systemctl --user disable --now nimbus-dream-sampler.timer
rm ~/.config/systemd/user/nimbus-dream-sampler.{service,timer}
```

Logs accumulate at `$XDG_STATE_HOME/nimbus-dream/signals/signals-YYYY-MM-DD.ndjson`.

## `day-digest.json` shape (excerpt)

```jsonc
{
  "meta":    { "generated_at": "…", "host": "…", "window_since": "midnight", "repos_scanned": ["…"] },
  "time":    { "weekday": "Saturday", "is_weekend": true, "time_of_day": "morning", "hour": 9 },
  "session": { "active_since": "2026-06-14T08:50:…", "active_span_hours": 1.6, "present": true },
  "git":     { "total_commits": 12, "busiest_repo": "whitesur-cachyos-pack",
               "types": { "feat": 7, "docs": 3 }, "scopes": ["layer10","readme"],
               "languages": [ { "lang": "rust", "files": 9 } ],
               "repos": [ { "name": "…", "commits": 12, "subjects": ["…"], "…": "…" } ],
               "present": true },
  "audio":   { "present": true, "playing_now": false, "level": 0.0 },
  "windows": { "present": true, "count": 2, "layout": "single-focused (ultrawide)" },
  "sampler": { "present": false },
  "summary": [ "git: 12 commits across 1 repo — feat×7, docs×3 (scopes: layer10, readme)",
               "languages: rust, markdown, python", "active ~1.6h (since 08:50)",
               "Saturday morning (weekend)", "music: quiet", "workspace: 2 windows, single-focused (ultrawide)" ]
}
```

The **`summary`** array is the model-facing payload: the compact `from_signals`
lines a leg's `provenance.from_signals` records, and the seed the prompt builder
(step 5) hands the model to ground the night's leg in the real day.
