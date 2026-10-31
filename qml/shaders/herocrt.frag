#version 440
// Hero-poster CRT pass — RetroArch-style. `source` is the poster hole. One shader,
// preset-switched: 1 crt-geom · 2 lottes · 3 aperture-grille · 4 shadow-mask · 5 slot-mask.
// Barrel curvature + tube-fixed scanlines + phosphor mask + scanline bloom + vignette.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2  res;       // poster hole size (px) — scanline / mask pitch anchor
    float preset;    // 1..5 (see above)
    float curv;      // barrel curvature amount
    float scanStr;   // scanline depth
    float maskStr;   // phosphor mask depth
    float glow;      // scanline bloom
};
layout(binding = 1) uniform sampler2D source;

void main()
{
    // barrel curvature — black outside the curved tube
    vec2 cc = qt_TexCoord0 - 0.5;
    float r2 = dot(cc, cc);
    vec2 uv = 0.5 + cc * (1.0 + curv * 0.25 * r2);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, qt_Opacity);
        return;
    }
    vec3 s = texture(source, uv).rgb;

    // scanlines (tube-fixed vertical pitch; lottes runs a fatter beam)
    float beam = 0.5 + 0.5 * cos(res.y * 0.45 * uv.y * 6.2831853);
    if (preset > 1.5 && preset < 2.5) beam = pow(beam, 1.4);
    float scan = 1.0 - scanStr * beam;

    // phosphor mask (aperture / shadow / slot)
    vec2 px = qt_TexCoord0 * res;
    vec3 m = vec3(1.0);
    if (preset > 2.5) {
        float off = (preset > 3.5) ? floor(mod(px.y / 3.0, 2.0)) * 1.5 : 0.0;
        float xx = fract((px.x + off) / 3.0);
        m = vec3(xx < 0.3333 ? 1.0 : 0.4,
                 (xx >= 0.3333 && xx < 0.6666) ? 1.0 : 0.4,
                 xx >= 0.6666 ? 1.0 : 0.4);
        if (preset > 4.5) {                 // slot: darken alternate cells
            float slot = step(0.5, fract(px.y / 4.0 + step(0.5, fract(px.x / 3.0)) * 0.5));
            m *= 0.72 + 0.28 * slot;
        }
    }
    m = mix(vec3(1.0), m, maskStr);

    float lum = dot(s, vec3(0.299, 0.587, 0.114));
    vec3 col = s * scan * m + s * glow * lum;   // bloom lifts the darks back
    float vig = 1.0 - r2 * 0.6 * curv;
    col = min(col * vig, vec3(1.0));
    fragColor = vec4(col, 1.0) * qt_Opacity;
}
