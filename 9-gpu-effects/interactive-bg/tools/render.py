#!/usr/bin/env python3
"""Offline renderer for the Nimbus Aurora shader.

Adapts the Qt6 (Vulkan-dialect, std140 UBO) fragment shader to desktop GL 330
and renders chosen style/theme/scheme/time combos to PNGs via headless EGL —
so you can SEE a shader change without restarting plasmashell. Re-reads the
.frag each run, so it always reflects the current source.

Setup (one-time):
    uv venv /tmp/aurora-render --python 3.12
    /tmp/aurora-render/bin/python -m ensurepip
    /tmp/aurora-render/bin/python -m pip install moderngl numpy pillow

Use:
    # default: all 5 styles, Big Sur dark, t=12 -> /tmp/aurora_shots/*.png
    /tmp/aurora-render/bin/python render.py
    # explicit combos "style,theme,dark,t" (theme 0..9, dark 1|0):
    /tmp/aurora-render/bin/python render.py 1,0,1,8 2,3,0,14
Then montage with ImageMagick and view the PNGs. Renders with music/cursor/
window reactivity zeroed (the static base look only).
"""
import re, sys, os
import numpy as np
import moderngl
from PIL import Image

FRAG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "contents", "shaders", "aurora.frag")
OUT  = "/tmp/aurora_shots"
os.makedirs(OUT, exist_ok=True)

W, H = 1280, 720

def adapt(src: str) -> str:
    src = src.replace("#version 440", "#version 330 core")
    src = re.sub(r"layout\(location = 0\)\s+in\s+vec2\s+qt_TexCoord0;", "in vec2 qt_TexCoord0;", src)
    src = re.sub(r"layout\(location = 0\)\s+out\s+vec4\s+fragColor;", "out vec4 fragColor;", src)
    # GL 3.3 core rejects layout(binding=N) on samplers (needs 4.2); the renderer
    # binds no texture anyway, so texture(reactTex,...) reads 0 = no reactivity.
    src = re.sub(r"layout\(binding = \d+\)\s+uniform\s+sampler2D", "uniform sampler2D", src)
    # convert the std140 UBO block into individual uniforms
    m = re.search(r"layout\(std140, binding = 0\) uniform buf \{(.*?)\n\};", src, re.S)
    block = m.group(1)
    decls = []
    for line in block.splitlines():
        mm = re.match(r"\s*(mat4|vec4|vec3|vec2|float|int)\s+([A-Za-z0-9_]+)\s*;", line)
        if mm:
            decls.append(f"uniform {mm.group(1)} {mm.group(2)};")
    src = src[:m.start()] + "\n".join(decls) + src[m.end():]
    return src

VERT = """#version 330 core
in vec2 in_pos;
out vec2 qt_TexCoord0;
void main(){
    vec2 uv = in_pos * 0.5 + 0.5;
    qt_TexCoord0 = vec2(uv.x, 1.0 - uv.y);   // Qt: y=0 at top
    gl_Position = vec4(in_pos, 0.0, 1.0);
}"""

# Big-Sur custom defaults (only used if theme==9)
CUSTOM = [(0.05,0.06,0.16,1),(0.11,0.18,0.45,1),(0.27,0.32,0.72,1),(0.56,0.36,0.72,1),(0.98,0.55,0.45,1)]

def render(ctx, prog, vao, fbo, style, theme, dark, t, speed=1.0):
    fbo.use()
    ctx.clear(0,0,0,1)
    def setu(name, val):
        try: prog[name].value = val
        except KeyError: pass
    setu("iResolution", (float(W), float(H)))
    setu("iTime", float(t))
    setu("iMouse", (0.5,0.5))
    setu("iMouseActive", 0.0)
    setu("qt_Opacity", 1.0)
    setu("uSpeed", float(speed))
    setu("uInteractivity", 0.0)
    setu("uDark", float(dark))
    setu("uIntensity", 1.0)
    setu("uTheme", int(theme))
    setu("uStyle", int(style))
    for i,c in enumerate(CUSTOM): setu(f"uColor{i}", c)
    # zero all reactivity
    for n in ["uWinReact","uActiveMove","uMusicReact","uBass","uMid","uTreble","uLevel","uBeat"]:
        setu(n, 0.0)
    setu("uWinCount", 0)
    # ground-plane controls (env-driven so the Laserwave yaw/pitch/hills can be previewed)
    setu("uYaw",   float(os.environ.get("UYAW",   "0")))
    setu("uPitch", float(os.environ.get("UPITCH", "0")))
    setu("uHill",  float(os.environ.get("UHILL",  "0")))
    vao.render(moderngl.TRIANGLE_STRIP)
    data = fbo.read(components=3, dtype='f1')
    img = np.frombuffer(data, dtype=np.uint8).reshape(H, W, 3)
    img = np.flipud(img)   # GL bottom-left -> image top-left
    return Image.fromarray(img)

def main():
    ctx = moderngl.create_standalone_context()
    frag = adapt(open(FRAG).read())
    prog = ctx.program(vertex_shader=VERT, fragment_shader=frag)
    quad = ctx.buffer(np.array([-1,-1, 1,-1, -1,1, 1,1], dtype='f4').tobytes())
    vao = ctx.vertex_array(prog, [(quad, "2f", "in_pos")])
    tex = ctx.texture((W,H), 3, dtype='f1'); fbo = ctx.framebuffer(color_attachments=[tex])

    # parse CLI: list of "style,theme,dark,t"
    jobs = []
    for a in sys.argv[1:]:
        s,th,d,t = a.split(",")
        jobs.append((int(s),int(th),float(d),float(t)))
    if not jobs:
        # default: all 5 styles, Big Sur dark, t=12
        jobs = [(s,0,1.0,12.0) for s in range(5)]
    names = ["flow","hills","silk","caustics","ink","laserwave","vaporwave","cyberpunk"]
    for s,th,d,t in jobs:
        img = render(ctx, prog, vao, fbo, s, th, d, t)
        fn = f"{OUT}/s{s}_{names[s]}_th{th}_{'dark' if d else 'light'}_t{int(t)}.png"
        img.save(fn); print("wrote", fn)

if __name__ == "__main__":
    main()
