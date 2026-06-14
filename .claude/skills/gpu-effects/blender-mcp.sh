#!/usr/bin/env bash
# blender-mcp — forge launcher for the Blender MCP authoring pipeline (Layers 9 & 10).
#
# AUTHORING TOOLING ONLY. This is part of the *forge* that produces the committed
# hero assets (hero_core.{png,glb}); it is NOT part of the installable skin and is
# deliberately never wired into install.sh / nimbus.layers.
#
# One "lane" = one flatpak Blender instance bound to one port, selected by
# $NIMBUS_BLENDER_PORT (default 9876 = the canonical lane). Parallel agents pick
# distinct lanes (9877, 9878, ...) — each gets its own Blender + its own port; the
# repo .mcp.json routes the `blender` MCP server to ${NIMBUS_BLENDER_PORT:-9876}.
#
# Usage:
#   ./blender-mcp.sh status          # is this lane up?
#   ./blender-mcp.sh up              # idempotently start Blender on this lane
#   ./blender-mcp.sh down            # stop the Blender instance on this lane
#   NIMBUS_BLENDER_PORT=9877 ./blender-mcp.sh up    # a sibling agent's lane
#
# See reference/blender-pipeline.md §0 for the operating reality (timer-callback
# bridge, EEVEE-only flatpak 5.1, verify-by-file, golden rules).
set -euo pipefail

PORT="${NIMBUS_BLENDER_PORT:-9876}"
FLATPAK_APP="org.blender.Blender"
ADDON_MODULE="blender_mcp_addon"

die()  { printf 'blender-mcp: %s\n' "$*" >&2; exit 1; }
note() { printf 'blender-mcp: %s\n' "$*"; }

# 0 if something is LISTENing on $PORT. Prefer ss (no connection opened); fall back
# to a bash /dev/tcp probe where ss is unavailable.
port_listening() {
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn "sport = :$PORT" 2>/dev/null | grep -q .
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && exec 3>&- 3<&-
  fi
}

# Prints the pid holding $PORT (best effort; needs ss). Never fails the pipeline.
port_pid() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -Hltnp "sport = :$PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true
}

cmd_up() {
  if port_listening; then
    note "lane $PORT already up (pid $(port_pid)) — nothing to do"
    return 0
  fi
  command -v flatpak >/dev/null 2>&1 || die "flatpak not found (is org.blender.Blender installed?)"
  note "starting Blender on lane $PORT ..."
  # Mirrors reference/blender-pipeline.md §0, with the port set before the addon's
  # StartServer operator fires (it reads scene.blendermcp_port at start time).
  setsid -f flatpak run "$FLATPAK_APP" --python-expr \
    "import bpy; bpy.ops.preferences.addon_enable(module='$ADDON_MODULE'); bpy.context.scene.blendermcp_port=$PORT; bpy.app.timers.register(lambda: bpy.ops.blendermcp.start_server() and None, first_interval=1.5)" \
    >/dev/null 2>&1
  # Addon starts ~1.5s after launch; allow for a cold flatpak start.
  for _ in $(seq 1 40); do
    if port_listening; then note "lane $PORT up (pid $(port_pid))"; return 0; fi
    sleep 0.5
  done
  die "lane $PORT did not come up within 20s — try 'flatpak run $FLATPAK_APP' by hand to see the error"
}

cmd_down() {
  if ! port_listening; then note "lane $PORT already down"; return 0; fi
  local pid; pid="$(port_pid)"
  [ -n "$pid" ] || die "lane $PORT is up but its pid is not visible (ss -p needs to see your own process)"
  note "stopping lane $PORT (pid $pid) ..."
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    if ! port_listening; then note "lane $PORT down"; return 0; fi
    sleep 0.5
  done
  note "lane $PORT still up after SIGTERM — sending SIGKILL"
  kill -9 "$pid" 2>/dev/null || true
  if port_listening; then die "could not free lane $PORT"; fi
  note "lane $PORT down"
}

cmd_status() {
  if port_listening; then
    note "lane $PORT: UP (pid $(port_pid))"
  else
    note "lane $PORT: down"
  fi
}

case "${1:-status}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  -h|--help|help) note "usage: NIMBUS_BLENDER_PORT=<port> $0 {up|down|status}" ;;
  *) die "usage: NIMBUS_BLENDER_PORT=<port> $0 {up|down|status}" ;;
esac
