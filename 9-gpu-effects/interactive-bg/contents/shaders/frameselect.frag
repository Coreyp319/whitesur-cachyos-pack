#version 440
//
// 2-D sprite-atlas cell selector for the Laserwave hero car.
//
// The atlas (`car_grid.png`) is a uCols×uRows grid of real 3-D poses rendered in
// Blender: columns sweep YAW (steer left↔right), rows sweep PITCH (nose up↕down).
// `uCol`/`uRow` are CONTINUOUS (the car's eased orientation), so we BILINEARLY
// blend the four neighbouring cells — the car turns buttery-smooth through every
// yaw/pitch combination instead of snapping frame to frame. A pure GPU op: updates
// instantly with the uniforms, no clip/reload (works in or out of an FBO capture).
//
// Qt loads textures premultiplied, so a straight mix() of the samples composites
// without dark edge fringing.
//
layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float uCol;     // continuous column 0 .. uCols-1 (yaw)
    float uRow;     // continuous row    0 .. uRows-1 (pitch)
    float uCols;    // grid columns
    float uRows;    // grid rows
    float uBlend;   // 1 = bilinear cell blend, 0 = nearest (snap)
};
layout(binding = 1) uniform sampler2D src;

// sample cell (cx,cy) at local coord t, inset ~1 texel so linear filtering never
// bleeds across a cell seam (the car is padded from each cell edge regardless).
vec4 cell(float cx, float cy, vec2 t) {
    vec2 inset = vec2(0.004, 0.006);   // ~2px, size-independent; cells are padded anyway
    t = clamp(t, inset, vec2(1.0) - inset);
    vec2 uv = (vec2(cx, cy) + t) / vec2(uCols, uRows);
    return texture(src, uv);
}

void main() {
    float c = clamp(uCol, 0.0, uCols - 1.0);
    float r = clamp(uRow, 0.0, uRows - 1.0);
    float c0 = floor(c), r0 = floor(r);
    float c1 = min(c0 + 1.0, uCols - 1.0);
    float r1 = min(r0 + 1.0, uRows - 1.0);
    float fc = (c - c0) * uBlend;
    float fr = (r - r0) * uBlend;

    vec2 t = qt_TexCoord0;
    vec4 top = mix(cell(c0, r0, t), cell(c1, r0, t), fc);
    vec4 bot = mix(cell(c0, r1, t), cell(c1, r1, t), fc);
    fragColor = mix(top, bot, fr) * qt_Opacity;
}
