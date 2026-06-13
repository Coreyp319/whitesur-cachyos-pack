#version 440
//
// Nimbus Aurora — Liquid style, DISPLAY pass.
// Reads the simulated dye (+ velocity) buffers and styles them as glowing ink
// over a deep Big Sur backdrop, light/dark aware, themed with the SAME palette
// table as aurora.frag so the Liquid look matches the rest of the pack.
//
layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  iResolution;
    float uDark;       // 1 dark, 0 light
    float uIntensity;  // colour vividness
    int   uTheme;      // matches aurora's theme ids; 9 = custom (uColor*)
    vec4  uColor0;
    vec4  uColor1;
    vec4  uColor2;
    vec4  uColor3;
    vec4  uColor4;
};

layout(binding = 1) uniform sampler2D dyeTex;
layout(binding = 2) uniform sampler2D velTex;

// ---- palettes (identical to aurora.frag) ---------------------------------
void palette(int theme, out vec3 c0, out vec3 c1, out vec3 c2, out vec3 c3, out vec3 c4) {
    if (theme == 1) {            // Monterey
        c0 = vec3(0.04, 0.09, 0.20); c1 = vec3(0.07, 0.38, 0.52);
        c2 = vec3(0.20, 0.52, 0.78); c3 = vec3(0.62, 0.44, 0.74); c4 = vec3(0.96, 0.66, 0.72);
    } else if (theme == 2) {     // Graphite
        c0 = vec3(0.07, 0.08, 0.10); c1 = vec3(0.16, 0.18, 0.22);
        c2 = vec3(0.32, 0.35, 0.40); c3 = vec3(0.55, 0.58, 0.64); c4 = vec3(0.82, 0.85, 0.90);
    } else if (theme == 3) {     // Sunset
        c0 = vec3(0.10, 0.05, 0.18); c1 = vec3(0.35, 0.10, 0.30);
        c2 = vec3(0.72, 0.22, 0.38); c3 = vec3(0.95, 0.45, 0.28); c4 = vec3(1.00, 0.80, 0.45);
    } else if (theme == 4) {     // Nord
        c0 = vec3(0.18, 0.20, 0.25); c1 = vec3(0.23, 0.26, 0.32);
        c2 = vec3(0.37, 0.51, 0.67); c3 = vec3(0.53, 0.75, 0.82); c4 = vec3(0.85, 0.87, 0.91);
    } else if (theme == 5) {     // Laserwave
        c0 = vec3(0.07, 0.04, 0.12); c1 = vec3(0.16, 0.08, 0.30);
        c2 = vec3(0.55, 0.16, 0.70); c3 = vec3(0.95, 0.35, 0.74); c4 = vec3(0.22, 0.90, 0.92);
    } else if (theme == 6) {     // Vaporwave
        c0 = vec3(0.12, 0.07, 0.22); c1 = vec3(0.38, 0.24, 0.56);
        c2 = vec3(0.74, 0.42, 0.95); c3 = vec3(1.00, 0.45, 0.80); c4 = vec3(0.40, 0.88, 0.98);
    } else if (theme == 7) {     // Cyberpunk
        c0 = vec3(0.02, 0.02, 0.05); c1 = vec3(0.04, 0.14, 0.24);
        c2 = vec3(0.00, 0.58, 0.76); c3 = vec3(1.00, 0.16, 0.56); c4 = vec3(0.98, 0.92, 0.20);
    } else if (theme == 8) {     // Outrun
        c0 = vec3(0.05, 0.02, 0.16); c1 = vec3(0.20, 0.06, 0.40);
        c2 = vec3(0.85, 0.15, 0.55); c3 = vec3(1.00, 0.42, 0.30); c4 = vec3(1.00, 0.86, 0.30);
    } else {                     // Big Sur (0 / default)
        c0 = vec3(0.05, 0.06, 0.16); c1 = vec3(0.11, 0.18, 0.45);
        c2 = vec3(0.27, 0.32, 0.72); c3 = vec3(0.56, 0.36, 0.72); c4 = vec3(0.98, 0.55, 0.45);
    }
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec3 c0, c1, c2, c3, c4;
    if (uTheme == 9) {
        c0 = uColor0.rgb; c1 = uColor1.rgb; c2 = uColor2.rgb; c3 = uColor3.rgb; c4 = uColor4.rgb;
    } else {
        palette(uTheme, c0, c1, c2, c3, c4);
    }

    vec3 dye = texture(dyeTex, uv).rgb;

    // backdrop: deep stop in dark, brighter wash in light
    vec3 bg = mix(c1 * 1.5 + 0.2, c0, uDark);

    // ink: dye glows over the backdrop, Reinhard-tonemapped so bright cores bloom
    vec3 ink = dye / (1.0 + dye);
    vec3 col = (bg + ink * (0.9 + 0.6 * uDark)) * uIntensity;

    fragColor = vec4(col, 1.0);
}
