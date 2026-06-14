#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.2", "pillow>=10"]
# ///
"""hermes-forge — drive the local Hermes model to author Blender hero assets over MCP.

Option-B harness (see DESIGN.md): connects to the `blender` MCP server as a client,
runs an Ollama tool-calling loop with Hermes, executes the model's tool calls inside a
live Blender, ENFORCES verify-by-file (the model can't see the viewport, so the harness
checks the written artifact itself), and TIME-SHARES the GPU (unloads Hermes during
renders so EEVEE gets the VRAM).

Authoring tooling only — not part of the installable skin; never wired into nimbus.layers.

Usage:
  NIMBUS_BLENDER_PORT=9879 ./hermes-forge.py \
      --task "Create an emissive cube 'HeroCore' at origin, aim a camera at it, render 256x256 to hero_core.png"
  ./hermes-forge.py --selftest            # just connect to the lane + list Blender tools, then exit

Prereqs (see doctor.sh): ollama up on :11434 with the model pulled; a Blender lane up
(`blender-mcp.sh up`); uv present (fetches `mcp` + runs `uvx blender-mcp`).
"""
from __future__ import annotations
import argparse
import asyncio
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

OLLAMA_URL = "http://localhost:11434/api/chat"
PROMPT_FILE = Path(__file__).resolve().parent / "forge-prompt.md"
RENDER_HINTS = ("render", "export_scene", ".png", ".glb", ".gltf", "filepath", "write_")


def log(msg: str) -> None:
    print(f"[hermes-forge] {msg}", flush=True)


def ollama_chat(model, messages, tools, num_ctx, keep_alive="5m", timeout=900):
    body = {
        "model": model, "messages": messages, "tools": tools, "stream": False,
        "keep_alive": keep_alive, "options": {"num_ctx": num_ctx, "temperature": 0.3},
    }
    req = urllib.request.Request(
        OLLAMA_URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)["message"]


def ollama_unload(model: str) -> None:
    """Evict the model from VRAM so an EEVEE render isn't fighting it for memory."""
    try:
        subprocess.run(["ollama", "stop", model], check=False, timeout=30,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def is_render_call(name: str, args_json: str) -> bool:
    blob = (name + " " + args_json).lower()
    return any(h in blob for h in RENDER_HINTS)


def snapshot(outdir: Path) -> dict:
    return {p: p.stat().st_size for p in outdir.rglob("*") if p.is_file()}


def changed_files(before: dict, after: dict) -> list:
    return [p for p, sz in after.items() if sz > 0 and before.get(p) != sz]


def image_content_report(path: Path) -> str:
    """Reject blank renders: a non-zero PNG can still be a flat/white/transparent frame.
    Returns ' content OK ...' or ' WARNING: ...' so the model gets actionable feedback."""
    try:
        from PIL import Image, ImageStat
    except Exception:
        return ""  # PIL unavailable — fall back to size-only verify
    try:
        im = Image.open(path).convert("RGBA")
    except Exception as e:
        return f" (content-check skipped: {e})"
    rgb_std = max(ImageStat.Stat(im).stddev[:3])
    a_lo, a_hi = im.getchannel("A").getextrema()
    if a_hi == 0:
        return " WARNING: render is fully TRANSPARENT — no subject in frame. Aim the camera at the object and re-render."
    if rgb_std < 3.0:
        return (" WARNING: render appears BLANK/uniform (subject offscreen, world flat, or exposure blown to white). "
                "Frame the camera on the object, use a dark/transparent world, keep emission moderate, then re-render.")
    return f" content OK (rgb_stddev={rgb_std:.0f})"


def tool_text(result) -> str:
    parts = [getattr(c, "text", "") for c in (getattr(result, "content", None) or [])]
    txt = "\n".join(p for p in parts if p).strip()
    if getattr(result, "isError", False):
        txt = "ERROR: " + txt
    return txt or "(no output)"


async def run(args) -> int:
    outdir = Path(os.path.expanduser(args.outdir)).resolve()
    outdir.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, "BLENDER_HOST": args.host, "BLENDER_PORT": str(args.port)}
    server = StdioServerParameters(command="uvx", args=["blender-mcp"], env=env)

    log(f"connecting to blender-mcp -> {args.host}:{args.port}")
    async with stdio_client(server) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            mcp_tools = (await session.list_tools()).tools
            log(f"{len(mcp_tools)} Blender tools: " + ", ".join(t.name for t in mcp_tools))
            if args.selftest:
                log("selftest OK — MCP connectivity + tool listing works.")
                return 0

            tools = [{"type": "function", "function": {
                "name": t.name,
                "description": (t.description or "")[:1024],
                "parameters": t.inputSchema or {"type": "object", "properties": {}},
            }} for t in mcp_tools]
            tool_names = {t.name for t in mcp_tools}

            system = PROMPT_FILE.read_text() if PROMPT_FILE.exists() else \
                "You are an autonomous Blender automation agent. Use the tools to act."
            system += (
                f"\n\n## Your run context\n"
                f"- Output directory (write files ONLY here): {outdir}\n"
                f"- Blender lane: {args.host}:{args.port}\n"
                f"- When you have built AND verified a written file, STOP calling tools and "
                f"reply with a one-line summary.")
            messages = [{"role": "system", "content": system},
                        {"role": "user", "content": args.task}]

            for step in range(1, args.max_steps + 1):
                msg = ollama_chat(args.model, messages, tools, args.num_ctx)
                calls = msg.get("tool_calls") or []
                content = (msg.get("content") or "").strip()
                messages.append({"role": "assistant", "content": content, "tool_calls": calls})
                if content:
                    log(f"step {step} · Hermes: {content[:200]}")
                if not calls:
                    if content:
                        log(f"done after {step} step(s).")
                        print("\n=== FINAL ===\n" + content)
                        return 0
                    # Empty turn (reasoning model may emit a thinking-only message) — nudge, don't quit.
                    thinking = (msg.get("thinking") or "").strip()
                    if thinking:
                        log(f"step {step} · (thinking only) {thinking[:160]}")
                    log(f"step {step} · empty turn — nudging to act")
                    messages.append({"role": "user", "content":
                        "You returned no tool call and no answer. Either call a tool to make progress now, "
                        "or — only if the asset is built AND the harness verified a non-blank file — reply "
                        "with a one-line final summary."})
                    continue

                for call in calls:
                    fn = call.get("function", {})
                    name = fn.get("name", "")
                    raw_args = fn.get("arguments", {})
                    if isinstance(raw_args, str):
                        try:
                            raw_args = json.loads(raw_args)
                        except Exception:
                            raw_args = {}
                    args_json = json.dumps(raw_args)
                    log(f"step {step} · tool: {name} {args_json[:160]}")

                    if name not in tool_names:
                        messages.append({"role": "tool", "tool_name": name,
                                         "content": f"ERROR: unknown tool '{name}'. Available: {sorted(tool_names)}"})
                        continue

                    render = is_render_call(name, args_json)
                    before = snapshot(outdir) if render else {}
                    if render and args.gpu_yield:
                        log("  ↯ render-ish call — unloading Hermes to free VRAM for EEVEE")
                        ollama_unload(args.model)
                    try:
                        result_text = tool_text(await session.call_tool(name, raw_args))
                    except Exception as e:
                        result_text = f"ERROR calling {name}: {e}"

                    if render:
                        new_paths = changed_files(before, snapshot(outdir))
                        if not new_paths:
                            result_text += (
                                f"\n[harness verify] WARNING: no new non-empty file in {outdir}. "
                                "The render/export did NOT write to disk. Fix: filepath must be an "
                                "absolute path inside the output dir, and os.makedirs(dir, exist_ok=True) first.")
                            log("  ! verify: nothing written")
                        else:
                            parts, blank = [], False
                            for p in new_paths:
                                entry = f"{p.name} ({p.stat().st_size} bytes)"
                                if p.suffix.lower() == ".png":
                                    rep = image_content_report(p)
                                    entry += rep
                                    blank = blank or ("WARNING" in rep)
                                parts.append(entry)
                            summary = "; ".join(parts)
                            result_text += "\n[harness verify] output: " + summary
                            if blank:
                                log("  ! verify: file written but BLANK — " + summary)
                            else:
                                log("  ✓ verified: " + summary)
                    messages.append({"role": "tool", "tool_name": name, "content": result_text})

            log(f"hit max-steps ({args.max_steps}) without a final answer.")
            return 2


def main() -> int:
    ap = argparse.ArgumentParser(description="Drive local Hermes to author Blender assets over MCP.")
    ap.add_argument("--task", help="What to build (required unless --selftest).")
    ap.add_argument("--model", default="hermes4-14b")
    ap.add_argument("--host", default=os.environ.get("BLENDER_HOST", "localhost"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("NIMBUS_BLENDER_PORT", "9876")))
    ap.add_argument("--outdir", default="~/hermes-forge")
    ap.add_argument("--max-steps", type=int, default=16)
    ap.add_argument("--num-ctx", type=int, default=16384)
    ap.add_argument("--no-gpu-yield", dest="gpu_yield", action="store_false",
                    help="Keep Hermes resident during renders (only if VRAM fits model + EEVEE).")
    ap.add_argument("--selftest", action="store_true", help="Connect + list Blender tools, then exit.")
    args = ap.parse_args()
    if not args.task and not args.selftest:
        ap.error("--task is required (or use --selftest)")
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
