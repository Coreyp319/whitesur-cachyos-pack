#version 440
//
// Nimbus Aurora — Liquid style, VELOCITY pass.
// Qt 6 ShaderEffect fragment shader (compile with qsb). Updates the velocity
// field of an Eulerian fluid: semi-Lagrangian self-advection + dissipation,
// amortized pressure projection (subtract last frame's pressure gradient), and
// force injection from the cursor + two slow ambient emitters.
//
// Rendered into a recursive RGBA16F ShaderEffectSource (velBuf): xy = velocity in
// texels/step. Sampling is bilinear (free, via the sampler) so advection is smooth.
//
layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  iResolution;   // sim size in texels
    float iTime;
    vec2  iMouse;        // 0..1, y-down
    vec2  iMouseVel;     // texels/step
    float dt;
    float velDiss;       // velocity dissipation (~0.997)
    float forceScale;
    float splatRadius;   // in uv units (0..1)
    // music + window reactivity
    float uMusicReact;
    float uBass;
    float uBeat;
    float uWinReact;
    vec4  uActiveWin;    // x,y,w,h normalised; .z<=0 => none
    vec2  uActiveVel;
    float uActiveMove;
};

layout(binding = 1) uniform sampler2D velTex;
layout(binding = 2) uniform sampler2D prsTex;

// ---- value noise -> curl, for a gentle divergence-free ambient current ----
float h21(vec2 p) { p = fract(p * vec2(123.34, 345.45)); p += dot(p, p + 34.345); return fract(p.x * p.y); }
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(h21(i), h21(i + vec2(1, 0)), u.x),
               mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { s += a * vnoise(p); p *= 2.0; a *= 0.5; }
    return s;
}
vec2 curlNoise(vec2 p) {
    float e = 0.01;
    float dx = fbm(p + vec2(e, 0.0)) - fbm(p - vec2(e, 0.0));
    float dy = fbm(p + vec2(0.0, e)) - fbm(p - vec2(0.0, e));
    return vec2(dy, -dx) / (2.0 * e);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = 1.0 / iResolution;

    // self-advection: backtrace along the current velocity
    vec2 vel = texture(velTex, uv).xy;
    vec2 back = uv - dt * vel * px;
    vec2 v = texture(velTex, back).xy * velDiss;

    // amortized projection: subtract the pressure gradient
    float pL = texture(prsTex, uv - vec2(px.x, 0.0)).x;
    float pR = texture(prsTex, uv + vec2(px.x, 0.0)).x;
    float pB = texture(prsTex, uv - vec2(0.0, px.y)).x;
    float pT = texture(prsTex, uv + vec2(0.0, px.y)).x;
    v -= 0.5 * vec2(pR - pL, pT - pB);

    // cursor force, along travel, gaussian footprint, gated by speed
    vec2 dm = uv - iMouse;
    float g = exp(-dot(dm, dm) / (splatRadius * splatRadius));
    float speed = length(iMouseVel);
    v += iMouseVel * forceScale * g * smoothstep(0.0, 2.0, speed);

    // two slow orbiting emitters: gentle curl so it lives with no input
    for (int i = 0; i < 2; i++) {
        float a = iTime * (0.13 + 0.05 * float(i)) + float(i) * 2.40;
        vec2 e = vec2(0.5) + vec2(cos(a), sin(a * 1.3)) * vec2(0.26, 0.22);
        vec2 d = uv - e;
        float ge = exp(-dot(d, d) / (splatRadius * splatRadius * 1.7));
        v += vec2(-d.y, d.x) * forceScale * 3.0 * ge;
    }

    // gentle large-scale ambient current: stretches dye into flowing ribbons so
    // the wallpaper reads as moving liquid even with no cursor or emitters nearby.
    // Bass swells the current so the whole field surges with the low end.
    float mus = clamp(uMusicReact, 0.0, 1.0);
    vec2 amb = curlNoise(uv * 2.2 + vec2(iTime * 0.04, iTime * 0.03));
    v += amb * forceScale * 0.45 * (1.0 + clamp(uBass, 0.0, 1.0) * 0.7 * mus);

    // music beat: a radial "boom" shoving the fluid outward from centre
    float beat = smoothstep(0.30, 0.80, uBeat) * mus;
    vec2 fc = uv - vec2(0.5);
    float rc = length(fc) + 1e-4;
    v += (fc / rc) * beat * 13.0 * exp(-rc * rc / 0.16);

    // active window: drag the fluid along the window's travel near it
    float wr = clamp(uWinReact, 0.0, 1.0);
    if (uActiveMove > 0.001 && uActiveWin.z > 0.0) {
        vec2 wc = uActiveWin.xy + 0.5 * uActiveWin.zw;
        vec2 dw = uv - wc;
        float gw = exp(-dot(dw, dw) / 0.04);
        float spd = length(uActiveVel);
        vec2 vd = spd > 1e-4 ? uActiveVel / spd : vec2(0.0);
        v += vd * gw * wr * uActiveMove * clamp(spd * 5.0, 0.0, 1.0) * 30.0;
    }

    // soft walls: damp velocity toward the very edge
    vec2 edge = smoothstep(0.0, 0.02, uv) * smoothstep(0.0, 0.02, 1.0 - uv);
    v *= edge.x * edge.y;

    fragColor = vec4(v, 0.0, 1.0);
}
