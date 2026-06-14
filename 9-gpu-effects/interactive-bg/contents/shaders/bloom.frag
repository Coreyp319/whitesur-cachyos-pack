#version 440
//
// Nimbus Aurora — bloom composite pass.
// Samples the captured scene (aurora + composited hero) and adds a soft neon
// glow: a 32-tap golden-angle spiral of a bright-pass (everything above
// uThreshold) blurred over uRadius px, added back on top. Single pass — cheap
// enough for a wallpaper, and the dark neon scenes mean most taps contribute
// ~nothing, so the glow hugs the bright structure (grid, edges, the hero core).
//
layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  iResolution;
    float uThreshold;     // brightness above which a pixel blooms
    float uIntensity;     // how strongly the glow is added back
    float uRadius;        // glow reach in pixels
};
layout(binding = 1) uniform sampler2D src;

void main() {
    vec3  base  = texture(src, qt_TexCoord0).rgb;
    vec2  px    = uRadius / iResolution;
    vec3  bloom = vec3(0.0);
    float wsum  = 0.0;
    for (int i = 0; i < 32; i++) {
        float a   = float(i) * 2.39996323;                 // golden angle -> even spiral
        float r   = sqrt((float(i) + 0.5) / 32.0);         // denser toward the centre
        vec2  off = vec2(cos(a), sin(a)) * r;
        vec3  s   = texture(src, qt_TexCoord0 + off * px).rgb;
        float w   = 1.0 - r;
        bloom += max(s - uThreshold, 0.0) * w;
        wsum  += w;
    }
    bloom /= max(wsum, 1e-3);
    fragColor = vec4(base + bloom * uIntensity, 1.0) * qt_Opacity;
}
