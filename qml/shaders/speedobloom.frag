#version 440
// VFD/LCD bloom for the stats speedo — extracts the bright lit segments and
// blooms them so the mint/amber/white phosphor emits light, like a real
// dashboard display. Real emission (gaussian gather), not a flat overlay.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2  res;    // source size in px (bloom radius anchor)
    float glow;   // bloom intensity
};
layout(binding = 1) uniform sampler2D source;

void main()
{
    vec4 base = texture(source, qt_TexCoord0);
    vec2 px = 1.0 / res;

    vec3 bloom = vec3(0.0);
    float total = 0.0;
    // gaussian gather of the bright (lit-segment) energy around this pixel
    for (int y = -4; y <= 4; ++y) {
        for (int x = -4; x <= 4; ++x) {
            vec2 o = vec2(float(x), float(y));
            vec3 s = texture(source, qt_TexCoord0 + o * px * 1.7).rgb;
            float lum = max(s.r, max(s.g, s.b));
            float bright = max(0.0, lum - 0.42);      // only the lit phosphor blooms
            float w = exp(-dot(o, o) / 9.0);
            bloom += s * bright * w;
            total += w;
        }
    }
    bloom /= max(total, 0.001);

    // keep the glow COLORED (don't wash to white): push the bloom away from grey
    // toward its own hue, so mint segments emit a mint glow
    float bl = dot(bloom, vec3(0.333));
    bloom = max(vec3(0.0), mix(vec3(bl), bloom, 1.9));

    // add the emitted light, then soft-clamp (reinhard) so the peak keeps its
    // hue instead of hard-clipping every channel to 1.0 (= white)
    vec3 col = base.rgb + bloom * glow * 2.6;
    col = col / (1.0 + max(vec3(0.0), col - 0.85));
    fragColor = vec4(min(col, vec3(1.0)), base.a) * qt_Opacity;
}
