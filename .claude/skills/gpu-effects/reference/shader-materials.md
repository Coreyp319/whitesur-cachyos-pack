# Shader materials reference — how shaders fake "glass / frosted / metal / …"

Reference for authoring **material looks** with the GPU effects in this pack. Read
this when the user wants a surface to *look like a material* — frosted glass, clear
glass, brushed metal, acrylic, mica, matte plastic — rather than just "more blur."

> **The one idea that makes the rest make sense.** A KWin effect and a Plasma
> `ShaderEffect` wallpaper are **screen-space 2-D post-processing**. There is **no 3-D
> geometry, no surface normal, no light position, no camera**. Every classic material
> shader you'll find online (Unity/Godot/Three.js) starts from a *mesh normal* and a
> *light vector*. **You have neither.** So here a "material" is not a BRDF — it is a
> **recipe of 2-D operations applied to the framebuffer behind the surface**: sample
> the backdrop, blur it, displace it, tint it, grade it, grain it. Normals and light
> are *faked* from screen-space gradients, edge distance, and noise. Once you accept
> that, the whole catalogue below is just "which primitives, in which order, with what
> constants." See [Translating 3-D material tutorials](#translating-3-d-tutorials).

The two delivery paths in this skill (see `SKILL.md`):

| Path | Where the shader runs | What you get | Use for |
|---|---|---|---|
| **Blur-fork knobs** (Glass / Better Blur) | inside KWin's blur effect, behind every translucent window | a *fixed* recipe you tune by config keys | dock/panel/menu "frosted glass" — 90% of requests |
| **Custom GLSL** (`kwin_effect_shaders` screen pass, or a QtQuick `ShaderEffect` like `interactive-bg/`) | your own fragment shader | anything you can write | bespoke looks, wallpapers, one-off filters |

---

## 1. The material primitives (every look composes from these)

These are the only building blocks. A material is a *combination and ordering* of them.

### a. Backdrop sample — the raw ingredient
The compositor hands you the pixels **behind** the surface (KWin's blur effect binds
the background as a texture; a wallpaper just *is* the backdrop). Everything starts
from `texture(backdrop, uv)`. A custom screen-pass shader gets the whole framebuffer;
a wallpaper generates its own field (the aurora) and treats *that* as the backdrop.

### b. Blur — "roughness" of the surface
Blur is what reads as *translucent material thickness / micro-roughness*. The more you
blur the backdrop, the frostier/thicker the glass. **KWin uses dual-Kawase blur**, not
Gaussian: it down-samples then up-samples through a small mip pyramid, sampling with a
fixed tiny tap pattern at each level. Cost is ~constant per pixel regardless of radius
(it leans on the GPU's bilinear texture units), so "infinite" blur is cheap — visually
≈ a Gaussian of radius 4–500 px across its strength range. This is why `BlurStrength`
0–15 can go very soft at no real cost. (For a hand-rolled GLSL blur you usually do a
separable Gaussian or a 13-tap Kawase; a naïve NxN box blur is the thing to avoid.)

### c. Tint — the material's body colour
A colour multiplied/blended over the blurred backdrop. Clear glass: faint, high-alpha.
Frosted white glass: milky white at ~0.1–0.25. WhiteSur graphite: cool neutral. Tint is
*the* knob that says "this surface has a colour," distinct from whatever's behind it.

### d. Noise / grain — micro-structure
A per-pixel random value. Two distinct jobs, don't conflate them:
- **Grain** (static, screen-space): a faint noise *added* to the final colour breaks the
  "too clean" CG look and **kills 8-bit banding** on smooth gradients. Acrylic, vibrancy,
  and our aurora all do this. Amount is tiny: `±0.5/255` to `±2/255`.
- **Frost** (displacement): noise used to *perturb the sampling coordinate* before the
  backdrop read — see (e). This is what makes "frosted" frosted vs. merely "blurred."

### e. Refraction / displacement — light bending through the body
Offset the backdrop UV before sampling: `texture(backdrop, uv + offset)`. The *source*
of `offset` is what differs:
- **Frosted glass:** `offset = noise_gradient * frostAmount` — irregular, grainy bend.
- **Smooth/clear glass:** `offset` from a smooth faux-normal (an SDF edge normal or a
  low-frequency noise) — a clean lens warp, strongest near edges.
- **Rippled/patterned glass:** `offset` from a procedural pattern (sine, voronoi).
This is the screen-space stand-in for the `refract()` function — you have no real normal
to feed `refract()`, so you *author* the offset field directly.

### f. Fresnel / edge term — the bright rim
Real Fresnel: surfaces get more mirror-like at grazing angles; rim lights up. The
formula is **Schlick**: `F = F0 + (1 - F0) * pow(1 - dot(N, V), 5)`. In screen space you
have no `N` or `V`, so you substitute a **screen-space edge term**: how close the pixel
is to the surface's silhouette/rounded-rect edge. `edge = pow(1 - distToEdge, k)` gives
the same bright-rim read. This is exactly what the Glass fork calls **"edge lighting
(brighter edges)."** It's the single cheapest trick that sells "this is a pane of glass"
rather than "this is a blurry rectangle."

### g. Tone grading — the optical response (saturation / brightness / contrast)
Three cheap pixel ops that define a *lot* of a material's character:
```glsl
col = mix(vec3(dot(col, vec3(0.2126,0.7152,0.0722))), col, saturation); // 0 grey … >1 vivid
col = (col - 0.5) * contrast + 0.5;                                      // tonal spread
col *= brightness;                                                      // lift / sink
```
- **Frosted/diffuse glass:** slightly *raise* brightness, *lower* saturation+contrast →
  milky, soft.
- **Vibrant "Apple" material:** *raise* saturation and lift mid-tones → backdrop colours
  glow through (this is literally what macOS "vibrancy" is — a saturation+luminosity
  boost on the blurred backdrop, not a new colour).
- **Brushed metal / dark glass:** *raise* contrast, push brightness down.

The Glass / Better Blur forks expose exactly **brightness, contrast, saturation, tint,
noise, glow, edge-lighting, refraction** — i.e. primitives (b)(c)(d)(e)(f)(g) wired into
a fixed recipe. You don't write GLSL for those; you turn these knobs.

### h. Specular / highlight — the hard glint (metal, gloss)
A bright spot or streak *added* on top. With no light vector, you fake it: a gradient
hotspot, a moving sheen, or (for **brushed/anisotropic metal**) a highlight **stretched
along one axis** because the micro-grooves run that way. Anisotropy = blur the highlight
in the groove direction only. This is the one material family that genuinely wants a
"light," so you invent a fixed faux-light direction and a hotspot position.

### i. Dither — the finisher
Always end smooth-gradient shaders with a tiny ordered/blue-noise dither (see grain
above). Banding is the #1 thing that makes a soft material look cheap. Our `aurora.frag`
does `col += (hash(frag + iTime) - 0.5)/255.0;` as its last line — copy that pattern.

---

## 2. Material recipes (primitive → order → constants)

Each row is "apply these primitives, in this order." `→` means "then."

| Material | Recipe | Feel |
|---|---|---|
| **Frosted glass** (dock, menus) | backdrop → **noise-displace** (e, grainy) → **blur** (b, medium) → milky **tint** (c, white ~0.15) → lower **sat/contrast** (g) → faint **edge light** (f) → **grain** (d) | soft, opaque-ish, diffuse |
| **Clear / smooth glass** | backdrop → **smooth displace** (e, edge-normal, strong at rim) → **light blur** (b) → very faint **tint** (c) → **chromatic split at edges** → strong **edge light / Fresnel** (f) | thin, see-through, lensy rim |
| **Acrylic** (Fluent) | backdrop → **Gaussian/Kawase blur** (b) → **luminosity blend** (g, exclusion-ish) → **tint colour** (c) → **noise** (d) | the canonical "win11" panel |
| **Vibrancy** (macOS) | backdrop → **blur** (b) → **saturation+brightness boost** (g) → subtle **tint** (c) → **grain** (d) | colour from behind *glows* through |
| **Mica** (subtle, opaque) | desktop-wallpaper only → **heavy blur** (b) → strong **tint toward window colour** (c) → tiny **noise** (d); *no live backdrop* | flat, themed, cheap |
| **Brushed metal** | base grey → **anisotropic highlight** (h, streaked along grain) → **directional noise** (d, grooves) → **contrast up** (g) → optional faux-reflection of backdrop | cold, directional sheen |
| **Matte plastic** | flat tint (c) → **broad soft highlight** (h, low power) → **fine grain** (d); little/no blur or displace | solid, non-reflective |
| **Rippled / patterned glass** | backdrop → **patterned displace** (e, sine/voronoi) → **blur** (b) → **tint** (c) → **edge light** (f) | textured privacy glass |

**Reading the table:** "frosted" and "clear" glass differ almost entirely in **(e)** —
*grainy* vs *smooth* displacement — and in how much **edge light (f)** you push. That's
the whole difference between bathroom-window glass and a phone screen.

---

## 3. Per-material GLSL (screen-space / compositor dialect)

Adapted for **sampling a backdrop texture**, not a 3-D mesh. These are the custom-GLSL
path (kwin-effect-shaders pass or a `ShaderEffect`). `backdrop` = the texture behind the
surface; `uv` = 0..1 across it; `px` = `1.0/resolution` (one texel).

### Frosted glass — noise displacement + soft blur + milky tint
```glsl
// 1. perturb the read with value noise -> the "frost"
vec2  warp   = (vec2(vnoise(uv*180.0), vnoise(uv*180.0+7.0)) - 0.5) * frost * px * 6.0;
// 2. cheap N-tap blur around the warped point (separable Gaussian is better; this reads clearly)
vec3  acc = vec3(0.0); float wsum = 0.0;
for (int i = -3; i <= 3; i++)
for (int j = -3; j <= 3; j++) {
    float w = exp(-float(i*i + j*j) * 0.18);
    acc += texture(backdrop, uv + warp + vec2(i,j)*px*blurPx).rgb * w;
    wsum += w;
}
vec3 col = acc / wsum;
// 3. milky body + diffuse grade
col = mix(col, vec3(1.0), 0.14);                                   // white tint
col = mix(vec3(dot(col, vec3(0.2126,0.7152,0.0722))), col, 0.85);  // slightly desaturate
col *= 1.03;                                                       // lift
// 4. finish: grain to break banding
col += (hash(uv*resolution + iTime) - 0.5) / 255.0;
```
`vnoise`/`hash`/`fbm` — reuse the ones already in `interactive-bg/contents/shaders/aurora.frag`.

### Clear glass — Fresnel rim (screen-space) + edge refraction + chromatic edge
No real normal/view: derive a **faux normal from a rounded-rect SDF** so the rim and the
lens-bend both peak at the edge.
```glsl
// signed distance to a rounded rect filling the surface; n = its gradient (the faux normal)
float d   = roundedBoxSDF(uv - 0.5, vec2(0.5), cornerRadius);
vec2  n   = normalize(vec2(dFdx(d), dFdy(d)) + 1e-5);
float edge = smoothstep(0.0, edgeWidth, -d);          // 1 inside, →0 at the rim
// refraction: bend the backdrop outward near the rim, by IOR strength
vec2  refr = n * (1.0 - edge) * ior * px * 20.0;
// chromatic dispersion: split channels by a hair (per-"wavelength" offset)
float r = texture(backdrop, uv + refr*1.00).r;
float g = texture(backdrop, uv + refr*1.06).g;
float b = texture(backdrop, uv + refr*1.12).b;
vec3  col = vec3(r,g,b);
// Schlick Fresnel rim, faked from the edge term (grazing = near the silhouette)
float F = pow(1.0 - edge, 5.0);                       // 0 in the body, →1 at the rim
col += F * fresnelTint * 0.6;                         // bright glassy rim
```
`refract()` exists in GLSL but needs a real incident + normal in the same space; in a
post-process you don't have a meaningful incident vector, so authoring the offset field
(as above) is the honest, controllable approach.

### Acrylic / vibrancy — the UI-material recipe (matches Fluent & macOS)
Documented layer order is **backdrop → blur → luminosity/exclusion blend → tint → noise**
(Fluent), and macOS's `NSVisualEffectView` is literally a `CABackdropLayer` with Gaussian
blur + saturation + brightness filters. Reproduced:
```glsl
vec3 col = blurredBackdrop;                                   // (already Kawase-blurred)
// vibrancy = push saturation & lift mids so backdrop colour glows through
col = mix(vec3(dot(col, vec3(0.2126,0.7152,0.0722))), col, 1.35); // sat > 1
col = (col - 0.5) * 1.05 + 0.5;                                   // gentle contrast
// tint (personalisation / theme colour), then grain
col = mix(col, tintColor.rgb, tintColor.a);                       // e.g. a=0.15
col += (hash(uv*resolution) - 0.5) * 2.0/255.0;                   // acrylic grain
```
"Reduce transparency" accessibility path: replace the whole thing with an opaque fill —
mirror that if you ship a custom one.

### Brushed metal — anisotropic streaked highlight (the one with a faux light)
The defining trait: the highlight is **stretched along the grain** because micro-grooves
run one way. No mesh, so invent a grain direction and a hotspot.
```glsl
vec2  grain = vec2(1.0, 0.0);                       // grooves run horizontally
// directional noise: high frequency across the grain, smeared along it
float scratch = vnoise(vec2(uv.x*4.0, uv.y*400.0)); // long thin streaks
vec3  base    = mix(vec3(0.45), vec3(0.62), scratch);
// anisotropic sheen: a bright band that is wide along grain, tight across it
vec2  toHot   = uv - hotspot;
float aniso   = exp(-pow(dot(toHot, vec2(grain.y, grain.x)) , 2.0) * 220.0); // tight across
      aniso  *= exp(-pow(dot(toHot, grain), 2.0) * 3.0);                     // wide along
vec3  col     = base + aniso * vec3(1.0) * 0.6;
col = (col - 0.5) * 1.25 + 0.5;                     // metal wants contrast
```
For *reflective* metal, additionally sample the backdrop along the grain normal and add it
in — a cheap screen-space "reflection."

### Matte plastic — flat, no lens
```glsl
vec3 col = tintColor.rgb;
col += pow(max(0.0, 1.0 - length(uv - hotspot)*1.5), 3.0) * 0.12; // broad soft gloss
col += (hash(uv*resolution) - 0.5) * 1.5/255.0;                   // fine grain
```

---

## 4. Mapping recipes onto the blur forks (no GLSL)

For dock/panel/menu glass the user almost never needs custom GLSL — the Glass / Better
Blur fork **is** the frosted/acrylic recipe, exposed as config. Feature → primitive:

| Fork feature | Primitive | "Material" effect of turning it up |
|---|---|---|
| `BlurStrength` | (b) blur | thicker / frostier body |
| brightness | (g) | milkier (up) / smokier (down) glass |
| contrast | (g) | crisper (up) / flatter, foggier (down) |
| saturation | (g) | vibrancy (up) / neutral frosted (down) |
| tint | (c) | the glass's body colour |
| noise | (d) | grain — frosted texture, anti-banding |
| glow / **edge lighting** | (f) Fresnel rim | the bright glassy rim that *sells* "pane" |
| refraction | (e) | lensy bend at edges → clear-glass feel |
| rounded corners | (the SDF the edge/refraction key off) | physical pane shape |

So: **frosted white dock** = strong blur + up brightness + down saturation + a little
noise + light edge-lighting. **Clear glass panel** = light blur + refraction on + strong
edge-lighting + near-zero tint. **Vibrant macOS dock** = medium blur + saturation up.

> **Do not hardcode the key names** in advice or scripts. They drift across fork versions
> (see `SKILL.md`). Set the option once in *System Settings → Desktop Effects → (gear)*,
> then read the real key back with `kreadconfig6 --file kwinrc --group Effect-glass --key
> <Key>` (or dump the group with the `awk` snippet in `SKILL.md`), and apply with
> `reconfigureEffect glass` — **never** `/KWin reconfigure` on a fork.

---

## 5. Translating 3-D material tutorials {#translating-3-d-tutorials}

Most material shaders online assume a mesh. Here's the dictionary to port them to this
screen-space context — when you hit one of these inputs, substitute the right column:

| 3-D shader input | You don't have it. Substitute → |
|---|---|
| surface normal `N` | gradient of a screen-space SDF (`roundedBoxSDF`), or `normalize(dFdx,dFdy)` of a noise/height field |
| view vector `V`, `dot(N,V)` | **edge term**: distance to the surface's silhouette / rounded-rect rim |
| light vector `L`, `dot(N,L)` | a **fixed invented direction** + a hotspot UV (only metals/gloss need this) |
| `refract(I, N, ior)` | author the UV **offset field** directly (noise for frost, SDF-normal for clear) |
| environment / cubemap reflection | sample the **backdrop** along the faux-normal (screen-space reflection) |
| Fresnel `pow(1-dot(N,V),5)` | `pow(1 - edge, 5)` — same rim, edge-driven |
| mesh roughness | **blur radius** + amount of noise displacement |
| metallic | high contrast + low/no tint + a hard anisotropic highlight |

**Rule of thumb:** if a tutorial's first line is "get the world-space normal," stop — you're
going to *fake* that normal from screen geometry, and everything downstream still works.

---

## 6. Quality & performance notes

- **Banding is the enemy.** Smooth blurred gradients band hard on 8-bit. Always finish
  with dither/grain (§1i). This is non-negotiable for any glass/acrylic look.
- **Blur cost:** prefer Kawase/dual-Kawase or a *separable* Gaussian (two 1-D passes) over
  a naïve 2-D NxN loop. The NxN loops in §3 are written for *clarity*; for a shipping
  effect, separate them or lean on the fork's built-in Kawase.
- **Sample count vs frost:** frosted glass needs *both* displacement and blur; you can use
  fewer blur taps if the noise displacement is doing work. Don't stack a 49-tap blur on
  top of heavy displacement — wasteful.
- **Chromatic aberration is an edge effect.** Apply it scaled by the edge term, not
  globally, or text behind the glass turns into rainbows.
- **GLSL version:** custom kwin-effect-shaders need **GLSL 1.40+** (desktop) or **ES 3.0+**.
  The QtQuick `ShaderEffect` path (aurora) is Vulkan-dialect `#version 440`, compiled with
  `qsb` (`qt6-shadertools`, `/usr/lib/qt6/bin/qsb`) — see `interactive-bg/README.md`.
- **Reuse the noise.** `interactive-bg/contents/shaders/aurora.frag` already has correct
  `hash` / `vnoise` / `fbm`. Copy them rather than reinventing — they're tuned to not band.

---

## 7. Sources

Material theory & techniques:
- [Schlick's approximation (Fresnel)](https://en.wikipedia.org/wiki/Schlick%27s_approximation) · [LearnOpenGL — PBR theory](https://learnopengl.com/pbr/theory) · [3D Game Shaders for Beginners — Fresnel](https://lettier.github.io/3d-game-shaders-for-beginners/fresnel-factor.html)
- [Refraction, dispersion & light effects (Maxime Heckel)](https://blog.maximeheckel.com/posts/refraction-dispersion-and-other-shader-light-effects/) — screen-space refract + per-channel IOR dispersion + Fresnel
- [Codrops — real-time multiside refraction](https://tympanus.net/codrops/2019/10/29/real-time-multiside-refraction-in-three-steps/) · [Geeks3D — chromatic aberration GLSL](https://www.geeks3d.com/20101008/shader-library-chromatic-aberration-demo-glsl/)
- [Geeks3D — frosted glass post-process GLSL](https://www.geeks3d.com/20101228/shader-library-frosted-glass-post-processing-shader-glsl/) — noise-driven displacement recipe
- [andydbc/unity-frosted-glass](https://github.com/andydbc/unity-frosted-glass) · [Godot frosted glass](https://godotshaders.com/shader/frosted-glass/)
- [Wikibooks — GLSL Brushed Metal (anisotropic)](https://en.wikibooks.org/wiki/GLSL_Programming/Unity/Brushed_Metal) · [Anisotropic specular (Shadertoy)](https://www.shadertoy.com/view/ltdXRN)

Blur algorithm (what KWin uses):
- [Dual Kawase blur, explained (frost.kiwi)](https://blog.frost.kiwi/dual-kawase/) · [KWin D9848 — adopting dual-Kawase](https://phabricator.kde.org/D9848) · [picom dual-Kawase PR](https://github.com/yshui/picom/pull/382)

UI-material design languages (the recipes):
- [Microsoft Fluent — Acrylic material](https://learn.microsoft.com/en-us/windows/apps/design/style/acrylic) (background → blur → exclusion/luminosity blend → tint → noise)
- [DIY web Acrylic (Microsoft Design)](https://medium.com/microsoft-design/diy-a-web-version-the-fluent-design-systems-acrylic-material-fe2eac2a40bb)
- [Reverse-engineering NSVisualEffectView (Oskar Groth)](https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview) — CABackdropLayer: Gaussian blur + saturation + brightness; opaque fill on Reduce Transparency
- [Apple — NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)

The blur fork this machine runs (material knobs exposed as config):
- [kwin-effects-glass (maintained fork)](https://github.com/4v3ngR/kwin-effects-glass) — brightness/contrast/saturation, tint, glow, **edge lighting**, refraction, rounded corners, force-blur, per-surface noise
