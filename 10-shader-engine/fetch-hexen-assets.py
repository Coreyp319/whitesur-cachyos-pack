#!/usr/bin/env python3
"""Fetch Poly Haven CC0 assets for the Nimbus Flux "hexen" gothic dungeon scene.

Pulls stone PBR textures (diffuse / OpenGL-normal / ARM) and glTF prop models
straight from the Poly Haven CDN into ``nimbus-flux/assets/hexen/`` — no Blender
in the loop, so it never touches the shared authoring instance. Idempotent:
existing non-empty files are skipped, so re-running only fills gaps.

Every asset here is CC0 (public domain) from https://polyhaven.com — see the
Layer-10 README for the credit list. The bevy side (`scene_hexen.rs`) expects the
layout this script writes:

    assets/hexen/textures/<id>/<id>_{diff,nor_gl,arm}_2k.jpg
    assets/hexen/models/<id>/<id>_2k.gltf   (+ .bin + textures/ alongside)
"""
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.polyhaven.com/files/{}"
UA = {"User-Agent": "nimbus-flux-hexen/1.0 (Nimbus pack Layer 10; CC0 asset fetch)"}

HERE = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(HERE, "nimbus-flux", "assets", "hexen")

TEX_RES = "2k"
MODEL_RES = "2k"

# Stone surfaces. Each Poly Haven texture exposes an "arm" map (AO=R, Rough=G,
# Metal=B) which drops straight into bevy's metallic-roughness + occlusion slots.
# The "Displacement" (height) map is handled separately (do_displacement): it drives
# bevy's parallax-occlusion mapping (depth_map) for real grazing-angle relief — the
# normal map alone leaves the surface geometrically flat.
TEXTURES = ["castle_brick_07", "medieval_blocks_02", "castle_wall_slates"]
TEX_MAPS = {"Diffuse": "diff", "nor_gl": "nor_gl", "arm": "arm"}

# Gothic props placed around the dungeon corridor. The first group frames the bust at
# the far end; the second dresses the near/mid hall so the foreground isn't bare —
# crates, a chest, a wine barrel, a bucket, broken-masonry rubble and a leaning shield.
MODELS = [
    "marble_bust_01", "Barrel_01", "brass_candleholders", "Lantern_01",
    "wooden_crate_01", "treasure_chest", "wine_barrel_01", "wooden_bucket_01",
    "rock_07", "kite_shield",
]


def fetch_json(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def download(url, path):
    rel = os.path.relpath(path, DEST)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        print(f"  skip {rel}")
        return True
    os.makedirs(os.path.dirname(path), exist_ok=True)
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=180) as r, open(path, "wb") as f:
            f.write(r.read())
    except (urllib.error.URLError, OSError) as e:
        print(f"  FAIL {rel}: {e}")
        if os.path.exists(path) and os.path.getsize(path) == 0:
            os.remove(path)
        return False
    print(f"  got  {rel} ({os.path.getsize(path) // 1024} KiB)")
    return True


def do_textures():
    ok = True
    for tid in TEXTURES:
        print(f"[texture] {tid}")
        files = fetch_json(API.format(tid))
        for mapkey, suffix in TEX_MAPS.items():
            node = files.get(mapkey, {}).get(TEX_RES, {}).get("jpg")
            if not node or "url" not in node:
                print(f"  (no {mapkey} {TEX_RES} jpg)")
                ok = False
                continue
            fn = f"{tid}_{suffix}_{TEX_RES}.jpg"
            ok &= download(node["url"], os.path.join(DEST, "textures", tid, fn))
        ok &= do_displacement(tid, files)
    return ok


def do_displacement(tid, files):
    """Fetch the Poly Haven Displacement map and bake the depth_map bevy's parallax
    expects. Poly Haven ships a HEIGHT map (white = raised); bevy's parallax-occlusion
    sampler reads the texture as DEPTH (white = recessed into the surface), so a raw
    feed would invert the relief — mortar would bulge out and bricks sink in. We keep
    the raw ``_height_`` download and write an inverted ``_disp_`` for the scene to load.
    Both steps are idempotent (guard on output existence); PIL-absent degrades to using
    the raw height map so parallax still has *a* depth source."""
    node = files.get("Displacement", {}).get(TEX_RES, {}).get("jpg")
    if not node or "url" not in node:
        print(f"  (no Displacement {TEX_RES} jpg)")
        return False
    tdir = os.path.join(DEST, "textures", tid)
    raw = os.path.join(tdir, f"{tid}_height_{TEX_RES}.jpg")
    depth = os.path.join(tdir, f"{tid}_disp_{TEX_RES}.jpg")
    if not download(node["url"], raw):
        return False
    if os.path.exists(depth) and os.path.getsize(depth) > 0:
        print(f"  skip {os.path.relpath(depth, DEST)}")
        return True
    try:
        from PIL import Image, ImageOps

        ImageOps.invert(Image.open(raw).convert("RGB")).save(depth, quality=95)
        print(f"  inv  {os.path.relpath(depth, DEST)} (height→depth for bevy parallax)")
    except Exception as e:  # PIL missing/decode error: fall back to the raw height map
        import shutil

        shutil.copyfile(raw, depth)
        print(f"  WARN invert {tid} failed ({e}); using raw height as depth_map fallback")
    return True


def do_models():
    ok = True
    for mid in MODELS:
        print(f"[model] {mid}")
        files = fetch_json(API.format(mid))
        g = files.get("gltf", {})
        res = MODEL_RES if MODEL_RES in g else (sorted(g)[0] if g else None)
        if not res:
            print("  (no gltf)")
            ok = False
            continue
        entry = g[res]["gltf"]
        base = os.path.join(DEST, "models", mid)
        main_name = entry["url"].split("/")[-1]
        ok &= download(entry["url"], os.path.join(base, main_name))
        # buffers + textures, keeping the relative paths the .gltf references
        for rel, info in entry.get("include", {}).items():
            ok &= download(info["url"], os.path.join(base, rel))
    return ok


def main():
    os.makedirs(DEST, exist_ok=True)
    ok = do_textures()
    ok &= do_models()
    print("done ->", DEST)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
