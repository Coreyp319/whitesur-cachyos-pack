#!/usr/bin/env bash
#
# dream-cycle.sh — ONE autonomous dreaming cycle: the unit of work the nightly timer or the
# dev-agent handoff loop runs.
#   1. Compose the next journey leg with the Layer-6 local model, grounded in TODAY'S real
#      activity (compose.py calls collect_digest internally — git/languages/session/windows).
#   2. Land it through the earned-autonomy guardrails (dream.py land): auto-applies ONLY if
#      trust has been earned, otherwise stages it for human approval.
#
# Idempotent per day: if today already has a landed OR staged leg, it no-ops — so a loop or a
# retried timer never stacks duplicate legs. Pass --force to compose anyway.
#
# Env:
#   NIMBUS_DREAM_MODEL      composer model (default hermes4-14b:latest — a small model fits
#                           alongside the live RT wallpaper on one GPU; the 27B contends for
#                           VRAM. Model-agnostic over Ollama /v1; set any tag to override.)
#   NIMBUS_FLUX_JOURNEY_DIR journey dir (default: ../nimbus-flux/journey, the dir the wallpaper reads)
#   NIMBUS_DREAM_URL        Ollama OpenAI-compatible endpoint (default localhost:11434/v1)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOURNEY="${NIMBUS_FLUX_JOURNEY_DIR:-$HERE/../nimbus-flux/journey}"
MODEL="${NIMBUS_DREAM_MODEL:-hermes4-14b:latest}"
CAND="${TMPDIR:-/tmp}/nimbus-dream-candidate.json"
today="$(date +%F)"
force=0
[ "${1:-}" = "--force" ] && force=1

# same-day dedup — has today already produced a leg (landed) or a pending one (staged)?
if [ "$force" -eq 0 ] && python3 - "$today" "$JOURNEY" <<'PY'
import json, glob, os, sys
today, jdir = sys.argv[1], sys.argv[2]
def day_of(p):
    try:
        d = json.load(open(p))
    except Exception:
        return None
    return (d.get("candidate") or d).get("day")
found = any(day_of(p) == today for p in glob.glob(os.path.join(jdir, "leg-*.json")))
st = os.path.join(jdir, "staging.json")
found = found or (os.path.exists(st) and day_of(st) == today)
sys.exit(0 if found else 1)
PY
then
    echo "dream-cycle: a leg for $today already exists (landed or staged) — nothing to do."
    exit 0
fi

echo "dream-cycle: composing the $today leg with $MODEL → $JOURNEY"
python3 "$HERE/compose.py" --model "$MODEL" --journey "$JOURNEY" --out "$CAND"

echo "dream-cycle: landing through the earned-autonomy guardrails …"
python3 "$HERE/dream.py" --journey "$JOURNEY" land "$CAND" --apply

python3 "$HERE/dream.py" --journey "$JOURNEY" trust
