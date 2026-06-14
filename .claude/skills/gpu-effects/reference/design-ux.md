# Design & UX judgment for GPU effects

How to decide *whether* an effect belongs, and *how* to tune it so it serves the
interface instead of fighting it. The rest of the skill (and `shader-materials.md`)
covers **how to build** effects; this covers **taste** — the part that separates a
desktop that feels like Big Sur from one that feels like a tech demo.

This pack chases a specific look (macOS Big Sur on KDE). That look is not "lots of
blur and glow." It is **deference**: the chrome gets out of the way of the content.
Every knob below is in service of that.

---

## 0. The prime directive — effects serve the content, not themselves

Apple's three foundational principles (Human Interface Guidelines) are the lens for
every decision here:

- **Clarity** — text is legible, icons precise, every element understandable. An
  effect that costs clarity (blur that swallows text, glow that hides an edge) is a
  regression, full stop.
- **Deference** — the UI defers to content. Materials, translucency and motion
  *support* the thing the user cares about; they never compete with it. "Interfaces
  should not obscure content."
- **Depth** — translucency, layering and motion communicate hierarchy and spatial
  relationships. Depth is the *justification* for these effects — it's why a blurred
  panel reads as "floating above" rather than "painted on."

**The restraint test (apply before adding anything).** Ask, in order:
1. What content relationship does this effect *clarify*? (If "none — it just looks
   cool," stop.)
2. Does it cost legibility, latency, or focus anywhere on screen?
3. Is it already at the platform's ceiling? (e.g. stock `BlurStrength` is maxed at
   15 — "more blur" past that isn't a number, it's a different effect or a no.)

When an effect is fighting the platform, **say so and recommend stopping** rather
than stacking workarounds. Knowing when to stop is the senior move — surface
"accept as-is" early. See the pack's standing preference for this (it is a recurring
theme: polish goals that fight the platform should be named, not brute-forced).

---

## 1. Materials & vibrancy — the Apple model

A **material** imparts translucency + blur to a background, creating visual
separation between a foreground layer and what's behind it. Apple defines a *ladder*
of materials by thickness — pick by how much separation the layer needs, not by taste:

| Material | Translucency | Use for |
|---|---|---|
| **Ultra-thin** | most see-through | transient overlays where context behind matters most (HUDs, scrubbers) |
| **Thin** | | secondary surfaces that still want strong background presence |
| **Regular** | balanced | the default — most panels, popovers, sidebars |
| **Thick** | most opaque | surfaces needing strong separation / heavy foreground content |
| **Chrome / bar** | — | toolbars, docks, menu bars (this pack's dock & panels) |

**Vibrancy** is the partner concept: foreground content *on* a material (text, icons,
fills) pulls color forward from behind the material to reinforce depth. Two hard rules
fall out of this:

- **Don't put flat opaque colors on a material** — it kills the vibrancy/depth illusion
  and reads as a sticker. Use vibrant (color-pulling, semi-transparent) foregrounds.
- **Translucency is a context cue, not decoration** — it works because it reminds the
  user what's *behind* the current surface. If nothing meaningful is behind it (an
  opaque app maximized under the panel), the material has nothing to do and you're
  paying GPU cost for nothing.

In this pack: the dock and panels are the "chrome" material — they only show their
blur when the panel opacity is Translucent/Adaptive **and** there's something
translucent or revealed behind them (see the dock-blur task in `SKILL.md`).

---

## 2. Glassmorphism without wrecking legibility

Frosted-glass surfaces are the pack's signature, and also the single most common way
to ruin a UI. NN/g's verdict: glassmorphism succeeds only with deliberate hierarchy;
overused or naïve, it "creates significant accessibility and usability challenges,"
overwhelmingly **text-contrast failures**. The non-negotiables:

- **Contrast ≥ 4.5:1** for body text over the glass (WCAG AA); **≥ 3:1** for large/bold
  text and essential UI components. The background is *dynamic* (a wallpaper, a moving
  aurora), so contrast must hold over the *worst-case* region behind the glass, not the
  average.
- **Stabilize contrast with a scrim**, not by killing translucency: a semi-opaque
  overlay (~black 20–30% / white 20–30% depending on scheme) *behind the text, on the
  glass* anchors legibility while the rest of the panel stays see-through.
- **More blur on busier backgrounds.** "More background blur is better, especially with
  intricate backgrounds." Don't try to keep the wallpaper "recognizable" through the
  glass — that's the cognitive-overload trap. Blur until the background is *texture*,
  not *content*.
- **A 1px border is mandatory** — a subtle light/dark hairline defines the glass edge
  for low-vision users and is what makes it read as a discrete surface. (This is the
  Fresnel-edge primitive in `shader-materials.md`.)
- **Panel opacity 10–40%.** Below ~10% it's invisible; above ~40% it stops being glass.
- **Use glass on a *few* key surfaces.** Fewer competing translucent layers = lower
  cognitive load and easier scanning. A desktop where everything is glass has no
  hierarchy at all.

The screen-space recipe (blur + tint + noise + edge-Fresnel + refraction) and the
per-fork knob mapping live in `shader-materials.md` §3. This section is about *how far*
to push each of those knobs.

---

## 3. Depth & hierarchy — why a layer reads as "above"

Depth is the payoff of the whole effects stack; spend it deliberately:

- **One focal point per beat.** Apple staging: dim or lightly blur (2–4px) the
  non-hero layers to 40–60%; let the focal surface sit crisp and forward.
- **Elevation is a stack, not a pile.** Each "higher" layer = more blur of what's
  behind it + a slightly stronger shadow + (often) a thinner material. If two surfaces
  have identical blur/shadow, the user can't tell which is on top — the depth illusion
  collapses.
- **Shadows imply a single light source.** Keep shadow direction/softness consistent
  across the dock, popovers, and the aurora's reactive glow, or the scene looks
  composited from parts.
- **Blur encodes distance.** Background blur isn't just prettiness — it's the strongest
  spatial cue you have on a flat screen. The aurora wallpaper sits at the *back* of the
  stack precisely so everything else can read as floating above it.

---

## 4. Motion & reactivity — timing is the whole game

The aurora's cursor/window/music reactivity and any KWin animation live or die on
timing. Linear motion and wrong durations are what make an effect feel cheap. These
tables are the reference (sourced from the LottieFiles motion-design skill, which
consolidates Material 3 + Apple HIG + Disney):

### Duration by element

| Element | Duration |
|---|---|
| Tooltip / micro-feedback | 80–120 ms |
| Button / toggle | 120–180 ms |
| Icon transition | 150–250 ms |
| Card / popover enter-exit | 200–350 ms |
| Modal / dialog | 300–400 ms |
| Page / view transition | 400–600 ms |
| Dramatic reveal | 600–1200 ms |
| **Ambient (the aurora, idle glow)** | **2000–20000 ms** |

### Interactive feedback — these are *latency ceilings*, not targets

| Interaction | Max latency |
|---|---|
| Hover response | < 100 ms |
| Press/tap | < 150 ms |
| Drag start | < 50 ms |
| Release / settle | 200–300 ms |

Reactivity that lags past these reads as broken, not smooth. The aurora's reactive
feedback buffer (`react.frag`) decays over seconds (ambient timescale) but its *onset*
must hit the cursor within the drag-start ceiling — persistence is ambient, response
is immediate.

### Easing — never linear for spatial motion

| Situation | Easing | Cubic-bezier |
|---|---|---|
| Something entering | ease-**out** | MD3 emphasized `(0.05, 0.7, 0.1, 1)` |
| Something leaving | ease-**in** | MD3 accelerate `(0.3, 0, 1, 1)` |
| Moving on-screen | ease-in-out | MD3 standard `(0.2, 0, 0, 1)` |
| iOS-native feel | — | Apple HIG `(0.25, 0.1, 0.25, 1)` |
| Interactive (drag/snap) | spring | stiffness 250–350, damping 18–24 |
| **Looping / ambient (aurora)** | **sine ease-in-out** | seamless, no seam at the loop |
| Rotation, progress bars, timers | **linear** (the *only* place linear is correct) |

### Three rules that fix 80% of bad motion

1. **Asymmetry:** exits run at **65–75%** of the entrance duration. Things should leave
   faster than they arrive.
2. **Two properties is the sweet spot.** Animate position+opacity, or scale+opacity —
   not six things at once.
3. **The 100th-viewing test.** Desktop effects are seen thousands of times. Anything
   that's delightful once and annoying by the 100th viewing must be *subtle and fast*,
   or off. Ambient motion especially: slow, continuous, low-amplitude.

(Premium/elegant personality — which Big Sur is — means **zero overshoot/bounce** and
*longer, calmer* durations: ~350/500/800 ms for quick/standard/slow. Bounce and
elastic easing read as "playful," which is the wrong personality for this pack.)

---

## 5. Color & contrast for a light/dark, themed desktop

- **Honor the scheme.** The aurora is light/dark-aware (polls `kdeglobals`); any new
  effect's tint, glow and scrim must flip with it. A glow tuned for dark mode will glare
  in light mode.
- **Accent is a spice.** The pack threads one accent (focus rings, scrollbar grab,
  reactive glow). Reuse *that* accent; don't introduce new hues per effect or the
  desktop loses coherence.
- **Contrast is measured against the worst case.** On a moving/animated background the
  effective contrast changes frame to frame — validate against the brightest and darkest
  regions the content can drift under, not a screenshot.

---

## 6. Accessibility & user agency — and it's already the pack's ethos

Effects must degrade gracefully for users who can't or don't want them. This dovetails
with the pack's core principle (everything reversible, every layer optional):

- **Respect "reduce transparency."** OSes expose a reduced-transparency preference
  (`prefers-reduced-transparency` on the web; KDE/Plasma has its own). Some users find
  heavy translucency fatiguing or unreadable. Provide an opaque fallback — and the
  pack's layered/revertible design *is* the user-agency story: glass is opt-in per
  layer.
- **Respect "reduce motion."** Vestibular disorders make large/continuous motion
  genuinely harmful. The ambient aurora and any reveal animation should have a calm or
  static fallback. Offer the off switch; don't assume everyone wants the motion.
- **Provide controls, don't hardcode.** NN/g's explicit recommendation for
  glassmorphism: let users "reduce transparency or increase contrast," up to disabling
  the effect entirely. The aurora's config UI (`config.qml`) and the per-layer
  install/revert pairs are where this lives.
- **Never gate function on an effect.** A control must be findable and operable with
  blur, glow and motion all off.

---

## 7. Effect-change design review (run before deploying any aesthetic change)

Before you `reconfigureEffect` or bounce the wallpaper for a *lasting* change:

- [ ] **Purpose** — names a content/hierarchy relationship it clarifies (not "looks cool").
- [ ] **Legibility** — text over any affected surface still clears 4.5:1 (3:1 large) over
      the worst-case background; 1px edge present.
- [ ] **Depth reads correctly** — the layer that should feel "on top" has more
      blur-behind + stronger shadow than its neighbor.
- [ ] **Motion** — duration from the table, ease-out/in by direction, never linear for
      spatial moves, exit faster than entrance, survives the 100th-viewing test.
- [ ] **Scheme** — flips correctly light↔dark; reuses the one accent.
- [ ] **Latency** — interactive feedback under its ceiling (hover <100 ms, drag <50 ms).
- [ ] **Agency** — a sane fallback exists for reduced-transparency / reduced-motion, and
      function never depends on the effect.
- [ ] **Ceiling** — not asking a maxed knob (e.g. `BlurStrength` 15) to "go further."
- [ ] **Restraint** — if it's fighting the platform, the honest recommendation is
      *stop*, and that's been surfaced.

---

## Sources

- [Apple HIG — Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
  (materials ladder, vibrancy, "don't obscure content," don't use non-vibrant colors on materials)
- [Apple HIG — design principles](https://developer.apple.com/design/human-interface-guidelines) (clarity / deference / depth)
- [NN/g — Glassmorphism: Definition and Best Practices](https://www.nngroup.com/articles/glassmorphism/)
- [Axess Lab — Glassmorphism meets accessibility](https://axesslab.com/glassmorphism-meets-accessibility-can-frosted-glass-be-inclusive/)
- [WebAIM — Contrast and Color Accessibility (WCAG)](https://webaim.org/articles/contrast/)
- [LottieFiles motion-design-skill](https://github.com/lottiefiles/motion-design-skill) — timing/easing tables, Disney-12-for-UI, decision framework (consolidates Material 3 + Apple HIG)
- [Material Design 3 — Easing and duration](https://m3.material.io/styles/motion/easing-and-duration)
- [web.dev — Accessibility: animation and motion](https://web.dev/learn/accessibility/motion) (prefers-reduced-motion)
- [CSS prefers-reduced-transparency](https://www.hallme.com/blog/enhancing-accessibility-with-css-prefers-reduced-transparency/)
