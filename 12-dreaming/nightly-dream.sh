#!/usr/bin/env bash
# nightly-dream.sh — run the dreaming pipeline once: day-digest -> compose knobs
# (local model) -> guardrailed apply (stage or, once earned, append a live leg).
#
# DRY BY DEFAULT (composes + would-stage, writes no live leg). Pass --apply to let
# the guardrail stage/append for real. GPU-yields by unloading the model after
# compose so it isn't fighting the wallpaper for VRAM.
#
#   nightly-dream.sh [--apply] [--model NAME] [--since "24 hours ago"]
#
# Env: NIMBUS_DREAM_HOME (state dir), NIMBUS_DREAM_MODEL (default model),
#      NIMBUS_FLUX_JOURNEY_DIR (live legs dir).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$DIR/skill/scripts"
MODEL="${NIMBUS_DREAM_MODEL:-gemma4-64k}"
JOURNEY="${NIMBUS_FLUX_JOURNEY_DIR:-$DIR/../10-shader-engine/nimbus-flux/journey}"
DREAM_HOME="${NIMBUS_DREAM_HOME:-$HOME/.hermes/dreaming}"
SINCE="24 hours ago"
APPLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY="--apply"; shift ;;
    --model) MODEL="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

export NIMBUS_DREAM_HOME="$DREAM_HOME"
DIGEST="$DREAM_HOME/digest/digest.json"
KNOBS="$DREAM_HOME/knobs/knobs.json"

echo ":: dreaming — model=$MODEL journey=$JOURNEY ${APPLY:-(dry-run)}"

echo ":: 1/4 day-digest (since: $SINCE)"
python3 "$S/dream-digest.py" --since "$SINCE"

echo ":: 2/4 compose knobs (local model)"
python3 "$S/dream-compose.py" --digest "$DIGEST" --journey-dir "$JOURNEY" --model "$MODEL" --out "$KNOBS"

echo ":: 3/4 GPU-yield (unload $MODEL)"
ollama stop "$MODEL" >/dev/null 2>&1 || true

echo ":: 4/4 guardrail apply"
python3 "$S/dream-apply.py" --knobs "$KNOBS" --journey-dir "$JOURNEY" \
  --digest "$DIGEST" --model "$MODEL" $APPLY
