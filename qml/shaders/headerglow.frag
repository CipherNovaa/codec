#version 440
// Neon glow for the stats header: gaussian-gathers the glyph coverage from the
// text texture and emits it as a soft coloured halo (glowColor). Rendered BEHIND
// the crisp text so the letters read as an emitting neon sign, not flat ink.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  px;          // texel size (1 / texture size)
    float radius;      // blur radius in texels
    float intensity;   // glow strength
    vec4  glowColor;   // neon colour (a = 1)
};
layout(binding = 1) uniform sampler2D source;

void main()
{
    float a = 0.0;
    float total = 0.0;
    for (int y = -6; y <= 6; ++y) {
        for (int x = -6; x <= 6; ++x) {
            vec2 o = vec2(float(x), float(y));
            float w = exp(-dot(o, o) / 18.0);
            a += texture(source, qt_TexCoord0 + o * px * radius).a * w;
            total += w;
        }
    }
    a /= max(total, 0.001);
    // soft-knee so the halo blooms without a hard edge
    a = a * intensity;
    fragColor = glowColor * a * qt_Opacity;   // premultiplied coloured halo
}
