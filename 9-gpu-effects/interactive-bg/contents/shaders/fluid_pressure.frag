#version 440
//
// Nimbus Aurora — Liquid style, PRESSURE pass.
// One Jacobi iteration of the pressure Poisson solve, warm-started from the
// previous frame's pressure (rendered into a recursive RGBA16F source). Over many
// frames this converges, keeping the velocity field ~divergence-free cheaply.
//
layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  iResolution;
};

layout(binding = 1) uniform sampler2D velTex;
layout(binding = 2) uniform sampler2D prsTex;

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = 1.0 / iResolution;

    // divergence of the velocity field
    float l = texture(velTex, uv - vec2(px.x, 0.0)).x;
    float r = texture(velTex, uv + vec2(px.x, 0.0)).x;
    float b = texture(velTex, uv - vec2(0.0, px.y)).y;
    float t = texture(velTex, uv + vec2(0.0, px.y)).y;
    float div = 0.5 * ((r - l) + (t - b));

    // Jacobi step
    float pL = texture(prsTex, uv - vec2(px.x, 0.0)).x;
    float pR = texture(prsTex, uv + vec2(px.x, 0.0)).x;
    float pB = texture(prsTex, uv - vec2(0.0, px.y)).x;
    float pT = texture(prsTex, uv + vec2(0.0, px.y)).x;
    float p = (pL + pR + pB + pT - div) * 0.25;

    fragColor = vec4(p, 0.0, 0.0, 1.0);
}
