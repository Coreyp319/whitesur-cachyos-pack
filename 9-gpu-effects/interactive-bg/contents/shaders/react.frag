#version 440
//
// Nimbus Aurora — REACTIVE FEEDBACK buffer.
// A recursive RGBA16F field that turns the wallpaper's instantaneous reactions
// (cursor / music / window) into PERSISTENT ones: it decays, diffuses and drifts
// each frame, so excitation injected this frame lingers, spreads and rises like
// real energy. aurora.frag samples this for glow, flow-displacement and ripples;
// it is what single-pass styles could never do.
//
//   .r = excitation (cursor trails, beat bursts, window wakes) — drives glow/warp
//   .g = music ambience (level/bass throb) + beat ring — drives pulse
//   .b = ripple seed (beat), spreads via diffusion
//
layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  iResolution;
    float iTime;
    vec2  iMouse;          // 0..1, y-down
    float iMouseActive;
    float uInteractivity;
    float uWinReact;
    vec4  uActiveWin;      // x,y,w,h normalised; .z<=0 => none
    vec2  uActiveVel;
    float uActiveMove;
    float uMusicReact;
    float uBass;
    float uLevel;
    float uBeat;
    float decay;          // per-frame retention (~0.95)
    float drift;          // upward drift in texels/frame
};

layout(binding = 1) uniform sampler2D prevTex;

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = 1.0 / iResolution;

    // diffuse + drift: read the previous field slightly shifted up, 5-tap blur so
    // trails soften and rise instead of sitting still
    vec2 d = uv + vec2(0.0, drift * px.y);
    vec3 e = texture(prevTex, d).rgb * 0.5
           + texture(prevTex, d + vec2(px.x, 0.0)).rgb * 0.125
           + texture(prevTex, d - vec2(px.x, 0.0)).rgb * 0.125
           + texture(prevTex, d + vec2(0.0, px.y)).rgb * 0.125
           + texture(prevTex, d - vec2(0.0, px.y)).rgb * 0.125;
    e *= decay;

    // --- cursor trail ---
    float cg = iMouseActive * clamp(uInteractivity, 0.0, 1.0);
    vec2 dm = uv - iMouse;
    e.r += exp(-dot(dm, dm) / 0.0045) * cg * 0.55;

    // --- music: ambient throb + beat ring/burst ---
    float mus = clamp(uMusicReact, 0.0, 1.0);
    float beat = smoothstep(0.30, 0.80, uBeat) * mus;
    e.g += clamp(uLevel, 0.0, 1.0) * mus * 0.035 + clamp(uBass, 0.0, 1.0) * mus * 0.04;
    vec2 cen = uv - vec2(0.5);
    float rc = length(cen);
    // a soft ring at mid-radius on the beat (diffusion expands it outward over frames)
    e.b += beat * exp(-pow(rc - 0.18, 2.0) / 0.004) * 0.5;
    e.r += beat * exp(-dot(cen, cen) / 0.02) * 0.4;

    // --- active-window wake ---
    float wr = clamp(uWinReact, 0.0, 1.0);
    if (uActiveMove > 0.001 && uActiveWin.z > 0.0) {
        vec2 wc = uActiveWin.xy + 0.5 * uActiveWin.zw;
        vec2 dw = uv - wc;
        float spd = length(uActiveVel);
        e.r += exp(-dot(dw, dw) / 0.03) * wr * uActiveMove * clamp(spd * 3.0, 0.0, 1.0) * 0.5;
    }

    fragColor = vec4(clamp(e, 0.0, 8.0), 1.0);
}
