#version 440
//
// Nimbus Aurora — cursor-reactive animated background.
// Qt 6 ShaderEffect fragment shader (Vulkan-style GLSL; compile with `qsb`).
//
// A domain-warped flowing gradient in the Big Sur / WhiteSur palette. Drifts on
// its own over time; a warm light blooms under the pointer and gently pushes the
// flow aside (the "interactive" part). Members of the uniform block below map by
// NAME to properties on the QML ShaderEffect.
//
// Window-reactive hook (v2): add `uWin[N]` rects + counts here and displace/glow
// the field around them exactly like the cursor bloom does. Left out of v1.
//
layout(location = 0) in  vec2 qt_TexCoord0;   // 0..1 across the wallpaper
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;        // used by the default vertex shader
    float qt_Opacity;       // fade applied by QtQuick
    float iTime;            // seconds, ever-increasing
    vec2  iResolution;      // wallpaper size in px
    vec2  iMouse;           // pointer, normalised 0..1 (y already flipped in QML)
    float iMouseActive;     // 1 while the pointer is over us, eased to 0 when it leaves
    float uSpeed;           // motion multiplier (config)
    float uInteractivity;   // cursor influence 0..1 (config)
    float uDark;            // 1 = dark variant, 0 = light (follows the colour scheme)
    float uIntensity;       // colour vividness; 1 = as-designed, <1 muted, >1 punchy
    int   uTheme;           // 0 Big Sur·1 Monterey·2 Graphite·3 Sunset·4 Nord·5 Laserwave·6 Vaporwave·7 Cyberpunk·8 Outrun·9 Custom
    int   uStyle;           // base look: 0 Flow·1 Hills·2 Silk curtains·3 Caustics·4 Ink in water·5 Laserwave·6 Vaporwave·7 Cyberpunk
    // custom palette (used when uTheme == 5); .rgb of each, low → high stop
    vec4  uColor0;
    vec4  uColor1;
    vec4  uColor2;
    vec4  uColor3;
    vec4  uColor4;
    // --- window reactivity (v2) -------------------------------------------
    // Up to 6 window rects (x,y,w,h) normalised 0..1 to THIS wallpaper's screen
    // (y down, matching iMouse). Individual vec4s — ShaderEffect array uniforms
    // are unreliable. The moving window also rides in uActiveWin/uActiveVel.
    vec4  uWin0;
    vec4  uWin1;
    vec4  uWin2;
    vec4  uWin3;
    vec4  uWin4;
    vec4  uWin5;
    vec4  uActiveWin;       // moving/active window rect (x,y,w,h); .z<=0 => none
    vec2  uActiveVel;       // its velocity, screen-widths per second (x,y)
    float uWinReact;        // master response 0..1 (config)
    float uActiveMove;      // 1 while a window is moving, eased to 0 (QML)
    int   uWinCount;        // number of valid uWin slots (0..6)
    // --- music reactivity -------------------------------------------------
    // Fed from the audio bridge (pw-cat → FFT → state file), eased in QML.
    float uMusicReact;      // master response 0..1 (config)
    float uBass;            // 0..1 low-band energy
    float uMid;             // 0..1 mid-band energy
    float uTreble;          // 0..1 high-band energy
    float uLevel;           // 0..1 overall loudness
    float uBeat;            // 0..1 transient pulse, decays fast (a ripple trigger)
};

// ---- value noise + fbm ----------------------------------------------------
float hash(vec2 p) {
    p = fract(p * vec2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float fbm(vec2 p) {
    float v = 0.0, a = 0.55;
    mat2 rot = mat2(0.80, 0.60, -0.60, 0.80);
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = rot * p * 2.02 + 11.3;
        a *= 0.5;
    }
    return v;
}
// cheaper 3-octave fbm for SMOOTH domain-warp displacements and feathering, where
// the top two octaves are sub-pixel after scaling and add cost but no visible
// detail. Reserve the full 5-octave fbm() for the visible field samples.
float fbm3(vec2 p) {
    float v = 0.0, a = 0.6;
    mat2 rot = mat2(0.80, 0.60, -0.60, 0.80);
    for (int i = 0; i < 3; i++) {
        v += a * vnoise(p);
        p = rot * p * 2.02 + 11.3;
        a *= 0.5;
    }
    return v;
}

// ---- window-rect helpers --------------------------------------------------
// map a normalised point (0..1, y down) into the same centred aspect-correct
// space as `p` and the cursor, so windows and the pointer share one geometry.
vec2 toP(vec2 n) { return (n * iResolution - 0.5 * iResolution) / iResolution.y; }
// signed distance to a box (centre c, half-extents h): <0 inside, >0 outside.
float sdBox(vec2 pt, vec2 c, vec2 h) {
    vec2 d = abs(pt - c) - h;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
// outward normal of that box's SDF — proper per-edge/corner normals so flow routes
// around the box SHAPE (its real w×h), not a radial point at its centre. Outside an
// edge it points straight out; near a corner it's diagonal. Falls back to radial
// when inside (where the window covers the wallpaper anyway).
vec2 boxNormal(vec2 pt, vec2 c, vec2 h) {
    vec2  d = abs(pt - c) - h;
    vec2  n = max(d, 0.0) * sign(pt - c);
    float l = length(n);
    return l > 1e-4 ? n / l : normalize(pt - c + 1e-4);
}
vec4 winAt(int i) {
    if (i == 0) return uWin0; if (i == 1) return uWin1; if (i == 2) return uWin2;
    if (i == 3) return uWin3; if (i == 4) return uWin4; return uWin5;
}

// ---- palettes (5 stops each) ---------------------------------------------
void palette(int theme, out vec3 c0, out vec3 c1, out vec3 c2, out vec3 c3, out vec3 c4) {
    if (theme == 1) {            // Monterey — teal → blue → pink
        c0 = vec3(0.04, 0.09, 0.20);
        c1 = vec3(0.07, 0.38, 0.52);
        c2 = vec3(0.20, 0.52, 0.78);
        c3 = vec3(0.62, 0.44, 0.74);
        c4 = vec3(0.96, 0.66, 0.72);
    } else if (theme == 2) {     // Graphite — WhiteSur neutral, silver on slate
        c0 = vec3(0.07, 0.08, 0.10);
        c1 = vec3(0.16, 0.18, 0.22);
        c2 = vec3(0.32, 0.35, 0.40);
        c3 = vec3(0.55, 0.58, 0.64);
        c4 = vec3(0.82, 0.85, 0.90);
    } else if (theme == 3) {     // Sunset — plum → magenta → orange → gold
        c0 = vec3(0.10, 0.05, 0.18);
        c1 = vec3(0.35, 0.10, 0.30);
        c2 = vec3(0.72, 0.22, 0.38);
        c3 = vec3(0.95, 0.45, 0.28);
        c4 = vec3(1.00, 0.80, 0.45);
    } else if (theme == 4) {     // Nord — arctic polar night → frost → snow
        c0 = vec3(0.18, 0.20, 0.25);
        c1 = vec3(0.23, 0.26, 0.32);
        c2 = vec3(0.37, 0.51, 0.67);
        c3 = vec3(0.53, 0.75, 0.82);
        c4 = vec3(0.85, 0.87, 0.91);
    } else if (theme == 5) {     // Laserwave — purple-black → electric purple → hot magenta → cyan
        c0 = vec3(0.07, 0.04, 0.12);
        c1 = vec3(0.16, 0.08, 0.30);
        c2 = vec3(0.55, 0.16, 0.70);
        c3 = vec3(0.95, 0.35, 0.74);
        c4 = vec3(0.22, 0.90, 0.92);
    } else if (theme == 6) {     // Vaporwave — dusk indigo → lavender → candy pink → pastel cyan
        c0 = vec3(0.12, 0.07, 0.22);
        c1 = vec3(0.38, 0.24, 0.56);
        c2 = vec3(0.74, 0.42, 0.95);
        c3 = vec3(1.00, 0.45, 0.80);
        c4 = vec3(0.40, 0.88, 0.98);
    } else if (theme == 7) {     // Cyberpunk — ink black → deep teal → electric cyan → magenta → acid yellow
        c0 = vec3(0.02, 0.02, 0.05);
        c1 = vec3(0.04, 0.14, 0.24);
        c2 = vec3(0.00, 0.58, 0.76);
        c3 = vec3(1.00, 0.16, 0.56);
        c4 = vec3(0.98, 0.92, 0.20);
    } else if (theme == 8) {     // Outrun — night-purple → neon magenta → sun-orange → gold (a neon sunset grid)
        c0 = vec3(0.05, 0.02, 0.16);
        c1 = vec3(0.20, 0.06, 0.40);
        c2 = vec3(0.85, 0.15, 0.55);
        c3 = vec3(1.00, 0.42, 0.30);
        c4 = vec3(1.00, 0.86, 0.30);
    } else {                     // Big Sur — indigo → blue → violet → coral
        c0 = vec3(0.05, 0.06, 0.16);
        c1 = vec3(0.11, 0.18, 0.45);
        c2 = vec3(0.27, 0.32, 0.72);
        c3 = vec3(0.56, 0.36, 0.72);
        c4 = vec3(0.98, 0.55, 0.45);
    }
}
vec3 ramp(float t, vec3 c0, vec3 c1, vec3 c2, vec3 c3, vec3 c4) {
    t = clamp(t, 0.0, 1.0) * 4.0;
    if (t < 1.0) return mix(c0, c1, t);
    if (t < 2.0) return mix(c1, c2, t - 1.0);
    if (t < 3.0) return mix(c2, c3, t - 2.0);
    return mix(c3, c4, t - 3.0);
}

// ---- base looks -----------------------------------------------------------
// The "base field": how the background colour is drawn, before any reactive
// light is layered on. Switched by uStyle. Each style takes the SHARED inputs
// (the reactive warp field warpP, the static aspect-corrected point p, time t,
// the live palette c0..c4 — already theme/scheme/custom-resolved, the dark
// blend uDark, and the music packet `mus`) and outputs a colour PLUS a 0..1
// `shade` field that says "where the aurora is bright". The shared cursor/window/
// music light (back in main) rides `shade`, so every style MUST set it sensibly
// or beat flares and the ribbon bloom won't sit on the picture.
//
// MUSIC PACKET — `mus` carries four eased, master-gated drives, each with a role
// a style picks from so the reaction fits its metaphor instead of one shared term:
//   mus.x mBass  — slow low-end surge → SCALE / REACH / drift (swell the field)
//   mus.y mMid   — band "body"        → BRIGHTNESS / DENSITY (fill it in)
//   mus.z mLevel — overall loudness   → global luminance breath (used in main)
//   mus.w mBeat  — gated transient    → a style-native PULSE (puff/flare/ripple)
// Keep music on slow amplitudes, never on fast spatial motion (that reads as
// jitter — treble is intentionally not in the packet for the same reason).
//
// HARD RULE: build colour only from c0..c4 — never hardcoded RGB. That is what
// gives every style all 6 themes, both schemes, and the custom picker for free.

// Flow style's domain-warped ribbon field, evaluated at an already-advected base
// coordinate. Split out so the flow-map advection (below) can sample it at two
// phase offsets and crossfade — the advection, not a static warp, is what makes the
// motion bend around windows.
float flowField(vec2 base, float t, out float rx) {
    vec2 q = vec2(fbm3(base + vec2(0.0, 0.12 * t)),
                  fbm3(base + vec2(5.2, 1.7 - 0.10 * t)));
    vec2 r = vec2(fbm3(base + 1.8 * q + vec2(1.7, 9.2 + 0.08 * t)),
                  fbm3(base + 1.8 * q + vec2(8.3, 2.8 - 0.07 * t)));
    rx = r.x;
    return fbm(base + 2.2 * r);   // visible field: full 5 octaves
}

// Caustics' thin ridged web at an already-advected coordinate (advection removed
// from the internals so the flow-map can drive it). beatThresh widens on a beat.
float causticField(vec2 wp, float t, float beatThresh) {
    vec2 warp = vec2(fbm3(wp * 0.8 + vec2(0.0,  0.08 * t)),
                     fbm3(wp * 0.8 + vec2(4.0, -0.07 * t))) - 0.5;
    vec2 sp   = wp * 1.7 + warp * 0.7;
    float ridge = abs(fbm(sp) * 2.0 - 1.0);   // visible web: full 5 octaves
    return pow(1.0 - smoothstep(0.0, beatThresh, ridge), 1.4);
}

// Ink density (turbulent body + filaments) at an already-advected coordinate.
float inkField(vec2 wp, float t, float mMid, float mBeat) {
    vec2 warp = vec2(fbm3(wp * 1.1 + vec2(0.0, 0.12 * t)),
                     fbm3(wp * 1.1 + vec2(3.7, 0.10 * t))) - 0.5;
    vec2 ip   = wp * 1.15 + warp * 1.2;
    float turb = pow(abs(fbm(ip * 1.7) * 2.0 - 1.0), 1.3);   // visible filaments: 5 octaves
    float body = smoothstep(0.38, 0.66, fbm(ip));
    return pow(clamp(body * (0.85 + 0.6 * turb + 0.25 * mMid)
                     + 0.20 * mBeat * body, 0.0, 1.0), 0.72);
}

// Per-pixel current that routes around every window (stones in the stream): start
// from baseV, and near each window remove the component heading INTO it so the flow
// diverts around the box edges. Time-independent -> routes the flow even when idle.
// Shared by every flow-mapped style; uses the static aspect-corrected point p for
// the (fixed) window geometry.
vec2 windowFlow(vec2 p, vec2 baseV, float t) {
    vec2  V      = baseV;
    float wreact = clamp(uWinReact, 0.0, 1.0);
    if (wreact > 0.001) {
        // FEATHER (computed ONCE — it's loop-invariant): a clean exp() halo makes the
        // deflection mirror corner-to-corner (too uniform to read as water), so we
        // modulate the routing strength with low-freq noise. Anchored to SCREEN
        // position (not the window centre): a moving window slides THROUGH this
        // slowly-drifting field, so dragging never makes the feather flicker (keying
        // it to wc made the noise race with the drag = white shimmer). fbm3 is plenty
        // for this smooth modulation. Stays > 0 so the current never leaks in.
        float feather = wreact * (0.45 + 0.85 * fbm3(p * 2.2 + vec2(0.0, 0.4 * t)));
        for (int i = 0; i < 6; i++) {
            if (i >= uWinCount) break;
            vec4 w = winAt(i);
            if (w.z <= 0.0) continue;
            vec2  wc  = toP(w.xy + 0.5 * w.zw);
            vec2  wh  = 0.5 * w.zw * iResolution / iResolution.y;
            float sd  = max(sdBox(p, wc, wh), 0.0);
            if (sd > 1.4) continue;                     // negligible influence -> skip the work
            float g   = exp(-sd * 3.5) * feather;       // routing reach around the stone
            vec2  nrm = boxNormal(p, wc, wh);           // outward from the box EDGE
            float vn  = dot(V, nrm);                    // <0 = flow heading into it
            V = mix(V, V - min(vn, 0.0) * nrm * 1.2, clamp(g, 0.0, 1.0));  // cancel inward + bow
        }
    }
    return V;
}

vec3 baseLook(int style, vec2 warpP, vec2 p, float t,
              vec3 c0, vec3 c1, vec3 c2, vec3 c3, vec3 c4,
              vec4 mus, out float shade)
{
    float mBass = mus.x, mMid = mus.y, mLevel = mus.z, mBeat = mus.w;
    // a calm vertical "sky" most styles sit on (lighter high, deeper low)
    float grad = clamp(0.5 - p.y * 0.9, 0.0, 1.0);
    vec3  sky  = mix(c1, c0, grad);

    // ---- shared FLOW: one coherent current the whole scene drifts ALONG, so
    //      every style reads as flowing-through rather than boiling in place.
    //      The rule: translate the SAMPLE POINT (advection = flow); putting time
    //      into the noise offsets instead just morphs it where it sits (= jitter).
    //      The current's pace eases up with the music's ENERGY — smoothly, never
    //      stepped on the beat (a beat-driven lurch is itself jitter). Each style
    //      scales `flow` to taste; the direction is a gentle diagonal drift.
    float flowAmt = t * (1.0 + 1.2 * mLevel + 0.8 * mBass);  // distance travelled
    vec2  flow    = vec2(0.92, 0.39) * flowAmt;

    if (style == 1) {
        // --- Hills: layered ridgelines receding into haze, with a drifting
        //     depth-of-field. Distant hills sit near the horizon, lighter and
        //     hazier (atmospheric perspective); nearer hills are lower, darker,
        //     and parallax-drift faster. A focus plane breathes between depths so
        //     layers slip in and out of focus — the in-focus band shows surface
        //     texture, the rest goes soft. Palette stops only.
        const int LAYERS = 5;
        vec3 col = sky;                                   // sky behind the hills
        shade = 0.12;                                     // dim baseline (sky)
        // bass breathes the focus plane between depths (low end = the swell)
        float focus = 0.5 + 0.45 * sin(t * 0.40) + 0.12 * mBass * sin(t * 0.8);
        for (int i = 0; i < LAYERS; i++) {
            float d  = 1.0 - float(i) / float(LAYERS - 1); // far (1) drawn first .. near (0) last
            float nr = 1.0 - d;
            // parallax: near layers ride the current faster across the frame
            float px = warpP.x * (0.9 + 1.0 * nr) + flow.x * (0.25 + 0.55 * nr);
            // bumpy silhouette: two octaves so even the FAR ridge has genuine
            // shape (a single low-freq arc reads as a flat stripe). Far gets a
            // touch more amplitude than before so the topmost ridgeline undulates.
            float ridge = ((fbm(vec2(px * 1.5 + d * 7.0,  0.0)) - 0.5) * 0.70
                         + (fbm(vec2(px * 3.7 + d * 7.0, 11.0)) - 0.5) * 0.30)
                        * mix(0.22, 0.30, nr);
            // horizons spread across the whole frame: far high, near low
            float horizon = mix(-0.26, 0.40, nr) + ridge;
            float blur = abs(d - focus);                  // depth of field
            // crisp in focus, soft off it — but distant ridges are NEVER razor-
            // sharp (atmospheric haze), so add depth-scaled softness: far stays a
            // hazy band, near can still snap crisp when in focus.
            float edge = mix(0.005, 0.07, blur) + 0.05 * d;
            float fill = smoothstep(horizon - edge, horizon + edge, warpP.y);
            // surface texture only where this layer is in focus; a beat makes the
            // in-focus hillside shimmer briefly, mid lifts its overall presence
            float tex = (vnoise(vec2(px * 5.0, warpP.y * 5.0)) - 0.5)
                      * (0.10 + 0.10 * mMid + 0.16 * mBeat)
                      * (1.0 - smoothstep(0.0, 0.45, blur));
            // tonal depth: near = dark cool stops, far = pale (no hot coral);
            // distant hills melt partway into the sky haze
            vec3 hue = ramp(0.10 + 0.52 * d, c0, c1, c2, c3, c4) * (1.0 + tex);
            hue = mix(hue, sky, 0.40 * d);
            col   = mix(col,   hue,               fill);
            shade = mix(shade, 0.30 + 0.50 * nr,  fill);  // near hills are the bright field
        }
        return col;
    }

    if (style == 2) {
        // --- Silk curtains: a few soft vertical light bands whose x-centres
        //     wander, swayed laterally by a low-freq fbm — aurora borealis hung
        //     from the top. Tinted up through c2..c4. shade = band intensity.
        // curtains = soft bright ridges of a 1-D field that DRIFTS sideways on the
        // current, so they stream through the frame and renew at the edge instead of
        // swaying in place; a slow second coord lets the folds breathe gently.
        float fx   = warpP.x * 2.6 - flow.x * 0.5;
        float n    = fbm(vec2(fx, 0.30 * t + 6.0));
        // max(0,…): fbm can exceed 1, so the inner term can go negative — and pow()
        // of a negative base is NaN, which rendered as WHITE FLASHES (most visible
        // when a drag perturbs warpP past the threshold). Clamp the base.
        float band = pow(max(0.0, 1.0 - abs(n * 2.0 - 1.0)), 3.5);  // a few vertical bands
        // curtains stream most of the height, brightest up top, soft floor
        float vfall = smoothstep(-0.7, 0.55, -warpP.y + 0.18 * fbm(vec2(warpP.x * 2.0 - flow.x * 0.3, 0.0)));
        // mid lifts band intensity; a beat sends a brief flare down the curtains
        shade = clamp(band * vfall * (1.0 + 0.22 * mMid + 0.30 * mBeat), 0.0, 1.0);
        // lower peak so curtains glow rather than blow out to flat coral
        vec3 curtain = ramp(0.30 + 0.45 * shade, c0, c1, c2, c3, c4);
        return mix(sky, curtain, clamp(shade * (0.9 + 0.10 * mBass), 0.0, 1.0));
    }

    if (style == 3) {
        // --- Caustics: slow water-light, a thin ridged web that now FLOWS AROUND
        //     windows (stones in the stream) via the shared velocity field + a
        //     two-phase flow-map, exactly like Flow. The veins glide and reconnect
        //     as they travel; near a window the current diverts around the box edges
        //     so the web bends past it. THIN web language preserved (causticField).
        vec2  V  = windowFlow(p, vec2(0.92, 0.39), t);        // diagonal current, routed
        float D  = 0.5 * (1.0 + 0.5 * mLevel + 0.4 * mBass);  // veins drift slowly
        float ph = fract(t * 0.6);
        float pA = ph, pB = fract(ph + 0.5);
        float wA = 1.0 - abs(2.0 * pA - 1.0);
        float wB = 1.0 - abs(2.0 * pB - 1.0);
        float bt = 0.16 + 0.10 * mBeat;
        float caustic = causticField(warpP - V * (pA * D), t, bt) * wA
                      + causticField(warpP - V * (pB * D), t, bt) * wB;
        shade = clamp(caustic * (1.0 + 0.20 * mMid), 0.0, 1.0);
        vec3 deep  = mix(c1, c0, clamp(0.5 - p.y * 0.7, 0.0, 1.0));
        // luminous but COOL glint (mid stops only, no full-coral): water-light veins
        vec3 glint = ramp(0.38 + 0.32 * shade, c0, c1, c2, c3, c4);
        return mix(deep, glint, shade * 0.95);
    }

    if (style == 4) {
        // --- Ink in water: turbulent pigment plumes that RISE and now also FLOW
        //     AROUND windows. The base current leans upward (ink rises); the shared
        //     velocity field routes it around the box edges, and the two-phase
        //     flow-map advects the density so plumes billow as they travel and
        //     divert past windows. Cool water c0..c1, pigment up through c2..c4.
        vec2  V  = windowFlow(p, vec2(0.25, -0.95), t);       // upward current, routed
        float D  = 0.8 * (1.0 + 0.5 * mLevel + 0.4 * mBass);
        float ph = fract(t * 0.6);
        float pA = ph, pB = fract(ph + 0.5);
        float wA = 1.0 - abs(2.0 * pA - 1.0);
        float wB = 1.0 - abs(2.0 * pB - 1.0);
        float ink = inkField(warpP - V * (pA * D), t, mMid, mBeat) * wA
                  + inkField(warpP - V * (pB * D), t, mMid, mBeat) * wB;
        shade = ink;
        vec3 water   = mix(c1, c0, clamp(0.5 - p.y * 0.7, 0.0, 1.0));
        vec3 pigment = ramp(0.34 + 0.55 * ink, c0, c1, c2, c3, c4);
        return mix(water, pigment, clamp(ink * (1.0 + 0.08 * mBass), 0.0, 1.0));
    }

    if (style == 5) {
        // --- Laserwave: a neon perspective grid rushing to a vanishing point under a
        //     banded retro sun, wrapped in synthwave ATMOSPHERE — a hot horizon haze
        //     band where sky meets grid, a twinkling starfield + nebula in the deep
        //     sky, the sun's glow mirrored down the grid, and faint CRT scanlines.
        //     Palette stops only; pairs best with Laserwave/Outrun. shade = neon energy.
        const float HOR = -0.04;                          // horizon a touch above centre
        vec2  sc   = vec2(0.0, HOR - 0.22);               // sun centre, above horizon
        float Rs   = 0.22;
        vec3  col5;
        float shd;
        if (p.y > HOR) {                                  // ---- neon floor grid ----
            float d    = (p.y - HOR) + 0.012;             // depth (small near horizon)
            float zl   = 0.16 / d + t * (1.6 + 1.2 * mBass);   // lines rush forward
            float xl   = warpP.x / d * 1.1;               // radiate from the vanishing point
            float w    = 0.085 + 0.06 * d;                // lines thicken with nearness
            float gz   = smoothstep(w, 0.0, min(fract(zl), 1.0 - fract(zl)));
            float gx   = smoothstep(w, 0.0, min(fract(xl), 1.0 - fract(xl)));
            float grid = max(gz, gx);
            float fade = smoothstep(0.0, 0.06, p.y - HOR);    // dissolve into horizon haze
            grid      *= fade;
            vec3 floorBase = mix(c1, c0, clamp((p.y - HOR) * 1.6, 0.0, 1.0));
            vec3 lineCol   = ramp(0.55 + 0.40 * grid, c0, c1, c2, c3, c4);
            col5 = mix(floorBase, lineCol, grid);
            // the sun's glow reflected straight down the grid (a luminous central aisle)
            float refl = exp(-abs(warpP.x) * 2.6) * smoothstep(0.02, 0.5, p.y - HOR);
            col5 += mix(c3, c4, 0.5) * refl * 0.18;
            shd = max(grid * (1.0 + 0.4 * mBeat), refl * 0.5);
        } else {                                          // ---- sky + banded sun ----
            float up     = smoothstep(HOR, HOR - 0.8, p.y);   // 0 at horizon → 1 at top
            vec3  skyCol = mix(c1, c0, up);
            // nebula: faint fbm cloud body in the deep sky, palette-tinted
            float neb = fbm(vec2(p.x * 1.4 + 3.0, p.y * 1.8 - t * 0.05));
            skyCol = mix(skyCol, mix(c2, c3, 0.5), neb * neb * 0.18 * up);
            // starfield (twinkling), fading in toward the top
            vec2  sg   = floor((p + 8.0) * 110.0);
            float sr   = hash(sg);
            float star = step(0.987, sr) * (0.4 + 0.6 * sin(t * 4.0 + sr * 40.0));
            skyCol += c4 * max(star, 0.0) * 0.6 * up;
            float sd     = length(p - sc);
            float sy     = clamp((p.y - (sc.y - Rs)) / (2.0 * Rs), 0.0, 1.0);  // 0 top → 1 bottom of disc
            float slit   = smoothstep(0.45, 0.55, fract(sy * 9.0));            // horizontal cuts
            float cut    = mix(1.0, slit, smoothstep(0.40, 1.0, sy));          // only in the lower half
            float disc   = smoothstep(Rs, Rs - 0.012, sd) * cut;
            float halo   = exp(-sd * 5.0);                 // soft outer glow
            vec3  sunCol = mix(c4, c3, sy);
            col5  = mix(skyCol, sunCol, disc);
            col5 += sunCol * halo * 0.40 * (1.0 + 0.4 * mBeat);               // bloom
            shd = max(disc, halo * 0.5);
        }
        // ---- shared atmosphere ----
        float hz = exp(-abs(p.y - HOR) * 8.0);             // hot horizon haze band
        col5 += mix(c3, c4, 0.4) * hz * 0.40;
        shd = max(shd, hz * 0.6);
        col5 *= 1.0 - 0.05 * (0.5 + 0.5 * sin(p.y * 380.0));   // faint CRT scanlines
        shade = clamp(shd, 0.0, 1.0);
        return col5;
    }

    if (style == 6) {
        // --- Vaporwave: the iconic perspective CHECKERBOARD floor under a big soft
        //     sun, wrapped in DREAMY ATMOSPHERE — pastel cloud bands drifting in the
        //     sky, the sun mirrored on the floor, a hazy horizon, and a soft vignette.
        //     Rounder and softer than Laserwave (no slits, no scanlines). Palette only.
        const float HOR = -0.02;
        vec2  sc   = vec2(0.0, HOR - 0.24);
        float Rs   = 0.26;
        vec3  col6;
        float shd;
        if (p.y > HOR) {                                  // ---- checkerboard floor ----
            float d   = (p.y - HOR) + 0.015;
            float zl  = 0.16 / d + t * (0.9 + 0.6 * mBass);
            float xl  = warpP.x / d * 1.1;
            float chk = mod(floor(zl) + floor(xl), 2.0);  // 0/1 tiles
            float ez  = smoothstep(0.10, 0.0, min(fract(zl), 1.0 - fract(zl)));
            float ex  = smoothstep(0.10, 0.0, min(fract(xl), 1.0 - fract(xl)));
            float seam = max(ez, ex);                     // a little glow on the tile seams
            float fade = smoothstep(0.0, 0.07, p.y - HOR);
            vec3 floorCol = mix(mix(c0, c1, 0.5), c2, chk);
            vec3 seamCol  = ramp(0.7, c0, c1, c2, c3, c4);
            floorCol = mix(floorCol, seamCol, seam * fade * 0.6);
            // the sun mirrored on the floor (a wavering glow down the centre aisle)
            float refl = exp(-abs(warpP.x) * 2.2) * smoothstep(0.0, 0.45, p.y - HOR);
            floorCol += mix(c3, c4, 0.5) * refl * 0.20;
            col6 = floorCol;
            shd  = max((0.3 + 0.4 * chk) * fade + seam * 0.4, refl * 0.6);
        } else {                                          // ---- soft sun + clouds ----
            float up     = smoothstep(HOR, HOR - 0.8, p.y);
            vec3  skyCol = mix(c1, c0, up);
            // pastel cloud bands drifting slowly across the sky
            float cl = fbm(vec2(p.x * 1.6 - t * 0.12, p.y * 3.0 + 2.0));
            skyCol = mix(skyCol, mix(c3, c4, 0.5), smoothstep(0.5, 0.92, cl) * 0.22);
            float sd     = length(p - sc);
            float sy     = clamp((p.y - (sc.y - Rs)) / (2.0 * Rs), 0.0, 1.0);
            float disc   = smoothstep(Rs, Rs - 0.06, sd); // soft edge, no slits
            float halo   = exp(-sd * 4.6);
            // pink-dominant sun (c3) with a c4 crown — keeps it from blooming to
            // flat white when the palette's highlight stop is a pale pastel.
            vec3  sunCol = mix(c3, c4, smoothstep(0.0, 0.55, 1.0 - sy));
            col6  = mix(skyCol, sunCol, disc);
            col6 += sunCol * halo * 0.22;
            shd = max(disc, halo * 0.5);
        }
        // ---- shared atmosphere ----
        float hz = exp(-abs(p.y - HOR) * 7.0);             // hazy pastel horizon band
        col6 += mix(c3, c4, 0.5) * hz * 0.25;
        shd = max(shd, hz * 0.4);
        col6 *= 1.0 - 0.18 * dot(p, p);                    // soft vignette for dreaminess
        shade = clamp(shd, 0.0, 1.0);
        return col6;
    }

    if (style == 7) {
        // --- Cyberpunk: a layered neon skyline drowning in smog. THREE building ranks
        //     recede into magenta/cyan light-pollution haze — far ranks wash toward the
        //     smog colour (atmospheric perspective), the near rank is near-black with
        //     dense lit windows. A glow band sits on the skyline; rain falls; a wet-
        //     street sheen pools at the bottom. Palette stops only. shade = neon energy.
        // ---- smoggy sky: darkest up top, glowing toward the skyline ----
        float toHor = smoothstep(-0.5, 0.16, p.y);
        vec3  col7  = mix(c0, mix(c1, c2, 0.45), toHor);
        float smog  = fbm(vec2(p.x * 1.3 + t * 0.12, p.y * 1.7 - t * 0.04));
        col7 += mix(c2, c3, 0.5) * smog * smog * 0.12 * toHor;
        col7 += mix(c3, c2, 0.4) * exp(-abs(p.y - 0.10) * 3.2) * 0.22;   // glow on the skyline
        float sh = toHor * 0.22;

        // ---- building ranks, far (0) -> near (2): drawn back-to-front ----
        for (int L = 0; L < 3; L++) {
            float fl     = float(L);
            float depth  = 1.0 - fl * 0.5;                // 1 far .. 0 near
            float scale  = 4.5 + fl * 3.5;                // near rank = more, thinner towers
            float amp    = 0.40 - fl * 0.07;              // far rank spreads tallest
            float ox     = fl * 13.7;                     // decorrelate the ranks
            float bx     = warpP.x * scale + ox;
            float ci     = floor(bx);
            float fx     = fract(bx);
            float h      = hash(vec2(ci, 3.1 + fl));
            float skyTop = 0.16 - amp;                    // highest a tower in this rank reaches
            float topY   = skyTop + (1.0 - h) * amp;      // this tower's top edge
            float present = step(0.12, h);                // a few columns are streets (no tower)
            if (present > 0.5 && p.y > topY) {
                float seam = smoothstep(0.0, 0.025, fx) * smoothstep(1.0, 0.975, fx);
                // far towers wash toward the smog/glow colour (atmospheric perspective)
                vec3 body = mix(mix(c0, c1, 0.25), mix(c1, c2, 0.5), depth);
                col7 = mix(col7, body, seam);
                sh   = mix(sh, 0.08 + 0.06 * depth, seam);
                if (L >= 1) {                             // lit windows on mid + near ranks
                    float wc  = floor(fx * 5.0);
                    float wr  = floor((p.y - topY) * 24.0);
                    float gx  = fract(fx * 5.0);
                    float gy  = fract((p.y - topY) * 24.0);
                    float lit = step(0.52, hash(vec2(wc + ci * 5.0, wr * 1.7 + fl)));
                    float win = lit * step(0.22, gx) * step(gx, 0.78)
                                    * step(0.22, gy) * step(gy, 0.78) * seam;
                    vec3 wcol = ramp(0.5 + 0.45 * hash(vec2(wc + ci, wr)), c0, c1, c2, c3, c4);
                    col7 = mix(col7, wcol, win);
                    sh   = max(sh, win);
                }
            }
        }

        // ---- rain: thin fast streaks in scattered columns (time-driven) ----
        float rcol   = floor(warpP.x * 110.0);
        float ry     = fract(p.y * 2.0 + t * (3.0 + 2.0 * hash(vec2(rcol, 4.0))) * 6.0
                             + hash(vec2(rcol, 8.0)) * 10.0);
        float rain   = smoothstep(0.0, 0.03, ry) * smoothstep(0.16, 0.03, ry)
                       * step(0.66, hash(vec2(rcol, 1.0))) * 0.4;
        col7 += mix(c3, c4, 0.4) * rain;
        sh = max(sh, rain * 0.4);

        // ---- wet-street sheen pooling at the very bottom (bass swells it) ----
        float street = smoothstep(0.36, 0.5, p.y);
        col7 += mix(c2, c3, 0.5) * street * 0.16 * (1.0 + 0.4 * mBass);
        sh = max(sh, street * 0.28);

        shade = clamp(sh, 0.0, 1.0);
        return col7;
    }

    // --- style 0 (default) Flow: domain-warped fbm ribbons that genuinely FLOW
    //     AROUND windows (stones in the stream), idle or not. The trick is that the
    //     advection — not a static coord-warp — carries the routing: a static warp
    //     leaves the temporal derivative (the apparent motion) uniform everywhere,
    //     so it only ever reads as a lens on top of a straight current.
    const float SC = 0.85;

    // 1) PER-PIXEL VELOCITY field: base diagonal current routed around every window
    //    (see windowFlow). Time-independent -> it routes the flow even when idle.
    vec2 V = windowFlow(p, vec2(0.92, 0.39), t);

    // 2) FLOW-MAP advection along V: each phase scrolls a BOUNDED distance D then
    //    resets; two phases offset by half a cycle, triangle-crossfaded, so the
    //    reset is invisible and the spatial variation in V never accumulates into
    //    scramble. This is what makes the apparent motion curve around windows.
    float D  = 1.0 * (1.0 + 0.5 * mLevel + 0.4 * mBass);  // bass reaches further
    float ph = fract(t * 0.6);
    float pA = ph, pB = fract(ph + 0.5);
    float wA = 1.0 - abs(2.0 * pA - 1.0);
    float wB = 1.0 - abs(2.0 * pB - 1.0);                 // wA + wB == 1 always
    vec2  b0 = warpP * SC;
    float rxA, rxB;
    float fA = flowField(b0 - V * (pA * D), t, rxA);
    float fB = flowField(b0 - V * (pB * D), t, rxB);
    float f  = fA * wA + fB * wB;
    float rx = rxA * wA + rxB * wB;

    // bass swells the bright field (lowers the threshold so ribbons broaden)
    shade = smoothstep(0.25 - 0.06 * mBass, 0.85, f + 0.12 * rx);
    vec3 ribbon = ramp(shade, c0, c1, c2, c3, c4);
    // mid fills in ribbon body; bass already widened where they reach
    float ribbonAmt = (0.65 + 0.08 * mBass + 0.10 * mMid) * smoothstep(0.1, 0.7, f);
    return mix(sky, ribbon, ribbonAmt);
}

void main() {
    vec2 frag = qt_TexCoord0 * iResolution;
    // aspect-correct space, centred, ~[-0.x..0.x] x [-0.5..0.5]
    vec2 p = (frag - 0.5 * iResolution) / iResolution.y;

    // ---- musical energy (computed FIRST — it drives the flow and amplifies
    //      every other reaction, so music reads as the scene's life, not a layer)
    float music  = clamp(uMusicReact, 0.0, 1.0);
    // the music packet handed to every style (see baseLook). Four eased drives,
    // each master-gated, with distinct roles: bass=scale, mid=body, level=breath,
    // beat=pulse. Treble is intentionally absent — too fast, it reads as jitter.
    // mScale dials the whole packet to ~1/5 of its former range: at full strength
    // the reaction jumped straight to chaotic. The slider still scales within this
    // gentler ceiling, so music breathes the scene rather than thrashing it.
    float mScale = music * 0.2;
    float mBass  = uBass   * mScale;
    float mMid   = uMid    * mScale;
    float mLevel = uLevel  * mScale;
    // beat is gated to STRONG transients only (weak-beat flicker removed) so the
    // pulse is a deliberate hit shared by the per-style puff AND the light flare
    float mBeat  = smoothstep(0.30, 0.80, uBeat) * mScale;
    vec4  mus    = vec4(mBass, mMid, mLevel, mBeat);
    // one shared "drive" the whole scene responds to (low+mid body — treble is
    // too fast to map to motion without it reading as jitter)
    float energy = clamp(mLevel * 0.55 + mBass * 0.45 + mMid * 0.15, 0.0, 1.0);

    // time: bass nudges the drift just slightly so the low end has a slow surge
    float t = iTime * 0.06 * max(uSpeed, 0.0) * (1.0 + 0.10 * mBass);

    // ---- cursor: a soft bloom that pulls the flow toward the pointer ---------
    vec2 mp = (iMouse * iResolution - 0.5 * iResolution) / iResolution.y;
    float md = length(p - mp);
    float curGate = iMouseActive * clamp(uInteractivity, 0.0, 1.0);
    float bloom = exp(-md * 3.2) * curGate;
    vec2 warpP = p + (mp - p) * bloom * 0.45;            // shared warp field

    // ---- windows are STONES IN THE STREAM: the current can't pass through them, so
    //      near each window we take the flow heading INTO it and route that around
    //      the sides — the field bends past the window, speeds up at its flanks, and
    //      relaxes into a calmer wake behind, exactly like water round a stone. This
    //      warps warpP, so EVERY style's field flows around windows. The edge band
    //      also feeds the light pooling below; the whole thing breathes with music. -
    vec2  fdir    = normalize(vec2(0.92, 0.39));   // base current dir (matches `flow`)
    float react   = clamp(uWinReact, 0.0, 1.0);
    float winGlow = 0.0;
    vec2  winPush = vec2(0.0);
    // Flow-mapped styles (0 Flow, 3 Caustics, 4 Ink) route the flow PROPERLY via a
    // per-pixel velocity + flow-map advection, so the static winPush warp would only
    // be a lens on top — skip computing it for them (kept for Hills/Silk). winGlow is
    // still needed by all styles for the edge light below.
    bool flowMapped = (uStyle == 0 || uStyle == 3 || uStyle == 4);
    if (react > 0.001) {
        for (int i = 0; i < 6; i++) {
            if (i >= uWinCount) break;
            vec4 w = winAt(i);
            if (w.z <= 0.0) continue;
            vec2 c = toP(w.xy + 0.5 * w.zw);
            vec2 h = 0.5 * w.zw * iResolution / iResolution.y;
            float sd = max(sdBox(p, c, h), 0.0);          // 0 inside, grows outside
            if (sd > 1.0) continue;                       // negligible influence -> skip
            float g  = exp(-sd * 5.0);                    // influence hugging the window
            winGlow += g;
            if (flowMapped) continue;                     // winPush unused for these styles
            // split the current here into its outward-normal and tangential parts.
            // Where it heads INTO the stone (fn<0) push it out (blocking the face)
            // and along the tangent (routing round the sides); at the flanks the push
            // is purely tangential (flow accelerates past); downstream it fades to
            // nothing (the wake). Smooth — no sign flips — so the field has no seams.
            vec2  nrm  = normalize(p - c + 1e-4);         // outward from the stone
            float fn   = dot(fdir, nrm);                  // <0 = flow heading into it
            vec2  ftan = fdir - fn * nrm;                 // tangential (around) part
            winPush += (ftan * 1.1 - min(fn, 0.0) * nrm * 1.6) * g;
        }
        warpP += winPush * react * 0.08 * (1.0 + 0.4 * energy) * float(!flowMapped);
    }

    // ---- a MOVING window shoves the fluid, not just trails light: near the window
    //      the flow is dragged along the motion, so the field is caught in its
    //      slipstream (the wake light below then pools into this disturbance). It's
    //      speed-gated, so a parked or slowly-settling window leaves the field be,
    //      and rides the SAME eased uActiveMove as the wake so it fades out as one.
    if (react > 0.001 && uActiveMove > 0.001 && uActiveWin.z > 0.0) {
        vec2  wc   = toP(uActiveWin.xy + 0.5 * uActiveWin.zw);
        vec2  wh   = 0.5 * uActiveWin.zw * iResolution / iResolution.y;
        float wsd  = max(sdBox(p, wc, wh), 0.0);     // 0 inside the window, grows out
        float prox = exp(-wsd * 4.5);                // disturbance hugs the window
        float spd  = length(uActiveVel);
        vec2  vd   = spd > 1e-4 ? uActiveVel / spd : vec2(0.0);
        // sample AGAINST the motion -> the field appears to drag along with the
        // window. (Flip the sign for a bow-wave-ahead read instead of a slipstream.)
        warpP -= vd * prox * uActiveMove * clamp(spd * 2.0, 0.0, 1.0) * react * 0.09;
    }

    // ---- music warps the shared field too: a gentle bass zoom only (the treble
    //      flutter that used to live here read as high-frequency jitter) -------
    warpP *= 1.0 + 0.04 * mBass;

    vec3 c0, c1, c2, c3, c4;
    palette(uTheme, c0, c1, c2, c3, c4);
    if (uTheme == 9) {   // user's custom palette overrides the preset
        c0 = uColor0.rgb; c1 = uColor1.rgb; c2 = uColor2.rgb;
        c3 = uColor3.rgb; c4 = uColor4.rgb;
    }

    // The palette above is tuned for the DARK variant. For LIGHT, lift the stops
    // toward white and desaturate so it reads as an airy daytime sky, not washed
    // out. uDark (1 dark, 0 light) blends between the two grades.
    if (uDark < 0.999) {
        // lift toward an airy daytime grade — but MUCH less than before: the old
        // factors (0.82/0.74…) lifted the dark stops almost to the bright ones,
        // collapsing the inter-stop spread so light mode read as flat milk. Lift
        // dark stops least so the gradient keeps its contrast.
        //
        // NEON THEMES (Laserwave 5, Cyberpunk 7, Outrun 8) are neon-on-black by
        // nature — the full daytime lift washes them to pale milk and kills the
        // identity, so scale their lift right down: they stay dark and saturated
        // even under a LIGHT colour scheme. Vaporwave (6) is deliberately excluded
        // — its pastel light variant IS the authentic look, so it lifts normally.
        float lift = (uTheme == 5 || uTheme == 7 || uTheme == 8) ? 0.22 : 1.0;
        c0 = mix(mix(c0, vec3(0.80, 0.85, 0.95), 0.55 * lift), c0, uDark);
        c1 = mix(mix(c1, vec3(0.78, 0.84, 0.95), 0.50 * lift), c1, uDark);
        c2 = mix(mix(c2, vec3(0.84, 0.83, 0.95), 0.42 * lift), c2, uDark);
        c3 = mix(mix(c3, vec3(0.92, 0.82, 0.92), 0.34 * lift), c3, uDark);
        c4 = mix(mix(c4, vec3(1.00, 0.86, 0.78), 0.24 * lift), c4, uDark);
    }

    // Shared reactive accents, drawn FROM the live palette so every response —
    // cursor, window, beat — reads as the same aurora light, never a foreign blob.
    vec3 accentWarm = mix(c4, vec3(1.0, 0.93, 0.82), 0.30);
    vec3 accentCool = mix(c2, c3, 0.5);

    // ---- BASE LOOK: draw the background field for the selected style. Returns
    //      the colour and a 0..1 `shade` (where the aurora is bright) that the
    //      shared reactive light below rides. Everything after here is shared.
    float shade;
    vec3 col = baseLook(uStyle, warpP, p, t, c0, c1, c2, c3, c4, mus, shade);

    // depth: in dark mode darken troughs for contrast; in light mode keep it airy
    col *= mix(0.97, 0.86, uDark) + mix(0.10, 0.26, uDark) * shade;
    // loudness gently swells the whole scene's luminance (subtle, breathing)
    col *= 1.0 + 0.10 * mLevel;

    // ---- ONE additive light field shared by every reaction ------------------
    // Accumulate all reactive light here, in the shared accent palette, then
    // screen-blend it once. Overlapping responses merge smoothly and never clip
    // to white — THIS is what makes the effects flow into one another instead of
    // stacking as separate coloured glows.
    vec3 light = vec3(0.0);

    // cursor warmth (soft bloom + a tighter core); brighter while the music's up
    light += accentWarm * (bloom * (0.30 + 0.22 * shade)
                         + exp(-md * 9.0) * curGate * 0.22) * (1.0 + 0.25 * energy);

    if (react > 0.001) {
        // aurora light leaking around every window edge, breathing with energy
        light += accentCool * winGlow * react * 0.05 * (0.85 + 0.4 * energy);

        // the dragged window trails a glowing wake — same accent family, so it
        // belongs to the scene rather than reading as a separate comet
        if (uActiveMove > 0.001 && uActiveWin.z > 0.0) {
            vec2  c  = toP(uActiveWin.xy + 0.5 * uActiveWin.zw);
            vec2  h  = 0.5 * uActiveWin.zw * iResolution / iResolution.y;
            float sd = max(sdBox(p, c, h), 0.0);
            float speed = length(uActiveVel);
            vec2  vdir  = speed > 1e-4 ? uActiveVel / speed : vec2(0.0);
            // points behind the motion (opposite the velocity) light up the most
            float behind = clamp(dot(normalize(p - c + 1e-4), -vdir), 0.0, 1.0);
            float ring = exp(-sd * 8.0) * uActiveMove;                 // rim all round
            float wake = exp(-sd * 3.2) * behind * uActiveMove
                       * clamp(speed * 1.5, 0.0, 1.0);                 // trailing tail
            light += (ring * 0.14 + wake * 0.38) * mix(accentCool, accentWarm, 0.5) * react;
        }
    }

    if (music > 0.001) {
        float cd = length(p);
        // bass: a slow warm swell breathing from the centre, riding the ribbons
        light += accentWarm * exp(-cd * 1.7) * mBass * 0.15 * (0.5 + shade);
        // beat: the same gated pulse the styles use (mBeat) gives a soft flare
        // through the aurora's own bright field, so the light flash and the
        // per-style structural puff fire together as one hit, then settle back
        light += accentWarm * mBeat * smoothstep(0.45, 0.9, shade) * 0.16;
        // (treble shimmer/flutter removed entirely — the per-pixel sparkle and the
        //  fast warp were the main source of "chaos"; treble no longer drives any
        //  motion, so the scene stays a slow breathing field)
    }

    // screen-blend the shared light so layered responses combine gracefully
    col = col + light * (1.0 - col);

    // intensity: scale saturation around luma (1 = unchanged, 0 = greyscale)
    float luma = dot(col, vec3(0.299, 0.587, 0.114));
    col = mix(vec3(luma), col, clamp(uIntensity, 0.0, 2.0));

    // dither to kill 8-bit banding on the smooth gradient
    col += (hash(frag + iTime) - 0.5) / 255.0;

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0) * qt_Opacity;
}
