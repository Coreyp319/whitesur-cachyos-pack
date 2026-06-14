#!/usr/bin/env bash
# hermes-forge doctor — verify the prerequisites for the Hermes Blender forge.
# Usage: ./doctor.sh [model]            (default model: hermes4-14b)
#        NIMBUS_BLENDER_PORT=9879 ./doctor.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MODEL="${1:-hermes4-14b}"
PORT="${NIMBUS_BLENDER_PORT:-9876}"
LAUNCHER="$ROOT/.claude/skills/gpu-effects/blender-mcp.sh"

ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad(){  printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }
FAIL=0

echo ":: hermes-forge doctor   (model=$MODEL, lane=$PORT)"

# 1. Ollama API
if curl -sf http://localhost:11434/api/version >/dev/null 2>&1; then
  ok "ollama API up ($(curl -s http://localhost:11434/api/version))"
else
  bad "ollama API not responding on :11434 (start Layer 6: systemctl status ollama)"
fi

# 2. Model pulled
if ollama list 2>/dev/null | grep -q "^${MODEL}"; then
  ok "model '$MODEL' pulled"
else
  bad "model '$MODEL' not pulled — build it via 6-local-ai/install.sh"
fi

# 3. uv (runs blender-mcp + fetches the harness's mcp dep)
if command -v uv >/dev/null 2>&1; then ok "uv present ($(uv --version 2>/dev/null))"
else bad "uv not found (needed for 'uvx blender-mcp' and 'uv run hermes-forge.py')"; fi

# 4. flatpak Blender
if flatpak info org.blender.Blender >/dev/null 2>&1; then ok "flatpak org.blender.Blender installed"
else warn "flatpak org.blender.Blender not found — the forge lane needs it"; fi

# 5. Tool-calling actually works (the load-bearing capability)
printf '  · probing Hermes tool-calling…\n'
TC="$(curl -s http://localhost:11434/api/chat -H 'Content-Type: application/json' -d "$(cat <<JSON
{"model":"$MODEL","stream":false,"keep_alive":0,"options":{"num_ctx":8192,"temperature":0.2},
 "messages":[{"role":"user","content":"Add a cube named HeroCore to the scene using the tool; do not just describe it."}],
 "tools":[{"type":"function","function":{"name":"add_primitive","description":"Add a primitive mesh to the scene.",
   "parameters":{"type":"object","properties":{"shape":{"type":"string"},"name":{"type":"string"}},"required":["shape","name"]}}}]}
JSON
)" 2>/dev/null)"
if printf '%s' "$TC" | grep -q '"tool_calls"'; then
  ok "tool-calling works (structured tool_calls returned)"
else
  bad "no structured tool_calls returned — model/template issue (see DESIGN.md gap #2)"
fi

# 6. Lane status + how to drive it
if command -v ss >/dev/null 2>&1 && ss -Hltn "sport = :$PORT" 2>/dev/null | grep -q .; then
  ok "lane $PORT is UP"
  echo "       selftest:  NIMBUS_BLENDER_PORT=$PORT uv run $HERE/hermes-forge.py --selftest"
else
  warn "lane $PORT is down"
  echo "       start it:  NIMBUS_BLENDER_PORT=$PORT $LAUNCHER up"
fi

echo
if [ "$FAIL" = 0 ]; then echo ":: doctor: all required checks passed"; else echo ":: doctor: FAILURES above — fix before running the forge"; exit 1; fi
