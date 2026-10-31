#version 440
// Neon halo for the stat wells (a `layer.effect`): gaussian-gathers the glyph
// coverage and adds it back as a soft halo tinted by the text's OWN colour — so
// the whole readout (labels + numbers) emits light like a neon sign, not just the
// brightest pixels. The crisp text stays on top; the halo fills in behind it.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  res;         // layer size in px
    float radius;      // halo blur radius in texels
    float intensity;   // halo strength
};
layout(binding = 1) uniform sampler2D source;

void main()
{
    vec4 base = texture(source, qt_TexCoord0);
    vec2 px = 1.0 / res;
    vec3 halo = vec3(0.0);
    float tot = 0.0;
    for (int y = -5; y <= 5; ++y) {
        for (int x = -5; x <= 5; ++x) {
            vec2 o = vec2(float(x), float(y));
            float w = exp(-dot(o, o) / 12.0);
            halo += texture(source, qt_TexCoord0 + o * px * radius).rgb * w;  // premultiplied colour
            tot += w;
        }
    }
    halo /= max(tot, 0.001);
    float hl = max(halo.r, max(halo.g, halo.b));
    float edge = (1.0 - base.a) * (1.0 - base.a);                 // confine the halo OUTSIDE the glyph
    vec3 col = base.rgb + halo * intensity * edge;               // (squared falloff, so bright text isn't blown out)
    float a  = base.a + hl * intensity * edge;
    fragColor = vec4(col, min(1.0, a)) * qt_Opacity;
}
