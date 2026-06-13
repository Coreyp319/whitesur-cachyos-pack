#version 440
//
// Nimbus Aurora — Liquid style, DYE pass.
// Advects the coloured dye through the velocity field, injects dye at the cursor
// (bright) and the two ambient emitters (slowly-cycling palette colour), and
// dissipates. Rendered into a recursive RGBA16F source (dyeBuf): rgb = dye.
//
layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  iResolution;
    float iTime;
    vec2  iMouse;
    vec2  iMouseVel;
    float dt;
    float dyeDiss;       // dye dissipation (~0.990)
    float splatRadius;
    vec4  uColor1;       // palette stops used for emitter dye
    vec4  uColor2;
    vec4  uColor3;
    // music + window reactivity
    float uMusicReact;
    float uBeat;
    float uWinReact;
    vec4  uActiveWin;
    vec2  uActiveVel;
    float uActiveMove;
};

layout(binding = 1) uniform sampler2D dyeTex;
layout(binding = 2) uniform sampler2D velTex;

vec3 ramp(float t) {
    t = clamp(t, 0.0, 1.0) * 2.0;
    if (t < 1.0) return mix(uColor1.rgb, uColor2.rgb, t);
    return mix(uColor2.rgb, uColor3.rgb, t - 1.0);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = 1.0 / iResolution;

    // advect dye by the velocity field
    vec2 vel = texture(velTex, uv).xy;
    vec2 back = uv - dt * vel * px;
    vec3 c = texture(dyeTex, back).rgb * dyeDiss;

    // cursor injection (bright, only where the cursor moves)
    vec2 dm = uv - iMouse;
    float g = exp(-dot(dm, dm) / (splatRadius * splatRadius));
    float speed = length(iMouseVel);
    c += vec3(0.85, 0.92, 1.0) * g * smoothstep(0.0, 2.0, speed) * 0.45;

    // ambient emitters drop palette-cycled dye
    for (int i = 0; i < 2; i++) {
        float a = iTime * (0.13 + 0.05 * float(i)) + float(i) * 2.40;
        vec2 e = vec2(0.5) + vec2(cos(a), sin(a * 1.3)) * vec2(0.26, 0.22);
        vec2 d = uv - e;
        float ge = exp(-dot(d, d) / (splatRadius * splatRadius * 1.4));
        float hue = fract(iTime * 0.05 + float(i) * 0.5);
        c += ramp(hue) * ge * 0.075;
    }

    // music beat: a colourful dye boom from the centre, hue cycling over time
    float mus = clamp(uMusicReact, 0.0, 1.0);
    float beat = smoothstep(0.30, 0.80, uBeat) * mus;
    vec2 fc = uv - vec2(0.5);
    c += ramp(fract(iTime * 0.1)) * beat * exp(-dot(fc, fc) / 0.03) * 0.22;

    // active window: a dye wake where a moving window stirs the fluid
    float wr = clamp(uWinReact, 0.0, 1.0);
    if (uActiveMove > 0.001 && uActiveWin.z > 0.0) {
        vec2 wc = uActiveWin.xy + 0.5 * uActiveWin.zw;
        vec2 dw = uv - wc;
        float spd = length(uActiveVel);
        c += ramp(0.6) * exp(-dot(dw, dw) / 0.03) * wr * uActiveMove * clamp(spd * 4.0, 0.0, 1.0) * 0.4;
    }

    fragColor = vec4(min(c, vec3(4.0)), 1.0);
}
