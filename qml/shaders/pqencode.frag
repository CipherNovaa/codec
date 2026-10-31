#version 440
// PQ-encode for UI chrome while the window is HDR-engaged: the surface is
// tagged BT.2100 PQ, so sRGB-authored QML must be re-encoded or it renders
// at wildly wrong luminance (sRGB white read as PQ = 10,000 nits). Maps SDR
// reference white to 203 nits (ITU-R BT.2408).

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
};
layout(binding = 1) uniform sampler2D source;

vec3 srgbEotf(vec3 c)
{
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

vec3 pqOetf(vec3 nits)
{
    const float m1 = 0.1593017578125, m2 = 78.84375;
    const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    vec3 y = pow(clamp(nits / 10000.0, 0.0, 1.0), vec3(m1));
    return pow((c1 + c2 * y) / (1.0 + c3 * y), vec3(m2));
}

void main()
{
    vec4 t = texture(source, qt_TexCoord0) * qt_Opacity;
    // Layer textures are premultiplied; un-premultiply before the transfer
    // math, re-premultiply after so compositing stays correct.
    vec3 c = t.a > 0.0 ? t.rgb / t.a : vec3(0.0);
    vec3 pq = pqOetf(srgbEotf(c) * 203.0);
    fragColor = vec4(pq * t.a, t.a);
}
