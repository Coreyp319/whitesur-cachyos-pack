#version 440
//
// Soft neon contact-glow pool for the Laserwave hero car. A wide, short, elliptical
// radial falloff drawn UNDER the car — it replaces the static Blender reflector plane
// with a compositor glow that is theme-coloured and beat-reactive (uIntensity is
// pulsed from the music bridge in QML). Premultiplied output so it adds cleanly over
// the dark neon scene.
//
layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  uColorA;      // hot inner colour
    vec4  uColorB;      // cool outer colour
    float uIntensity;   // overall strength (beat-boosted in QML)
};

void main() {
    vec2  p    = qt_TexCoord0 * 2.0 - 1.0;     // -1..1 across the wide/short item
    float d    = length(p);
    float core = smoothstep(1.0, 0.0, d);      // 1 at centre -> 0 at the edge
    float glow = pow(core, 2.0);
    vec3  col  = mix(uColorB.rgb, uColorA.rgb, glow);
    float a    = glow * uIntensity;
    fragColor  = vec4(col * a, a) * qt_Opacity;   // premultiplied
}
