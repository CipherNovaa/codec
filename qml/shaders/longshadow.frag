#version 440
// Elongated cast shadow for the stats header. Samples the header glyph texture
// and, for each output texel, marches back along the light direction: if any
// glyph texel lies up-light of here, this texel is in shadow. One smooth GPU
// pass captures every glyph detail (serifs, thin strokes) exactly, with a clean
// distance fade — no stepping like a stack of offset copies.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  dir;          // per-step offset in UV space (direction the shadow rakes)
    float steps;        // how many steps to march (shadow length)
    float fade;         // tail fade amount (0 = solid, 1 = fades to nothing)
    vec4  shadowColor;  // shadow rgb (a = 1); the whole layer's subtlety is qt_Opacity
};
layout(binding = 1) uniform sampler2D source;

void main()
{
    vec2 uv = qt_TexCoord0;
    float shade = 0.0;
    int n = int(steps);
    for (int k = 1; k <= 320; ++k) {         // fixed bound (SPIR-V), broken at n; `dir` is a
        if (k > n) break;                    // 1-TEXEL step so every glyph pixel is sampled (ultra)
        vec2 s = uv - dir * float(k);
        if (s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0) continue;
        float a = texture(source, s).a;
        float w = 1.0 - (float(k) / steps) * fade;
        shade = max(shade, a * w);
    }
    // don't shade under the glyph itself — let the real text sit clean on top
    shade *= (1.0 - texture(source, uv).a);
    fragColor = shadowColor * shade * qt_Opacity;   // premultiplied
}
