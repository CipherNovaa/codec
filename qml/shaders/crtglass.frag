#version 440
// The RetroTV's tube face. The readout renders into `source`; this pass
// puts it behind real glass: a rolling electron beam with phosphor
// persistence (the MGS codec-call band), tube-fixed scanline pitch,
// corner vignette, centre bloom, per-pixel static snow during bursts,
// and a one-shot v-hold roll while the set locks signal on power-on.
// Everything is premultiplied; dimming scales colour and alpha together
// so the case's dark seam reads through quiet glass.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 tint;     // phosphor tone (the icon's fg tint)
    float bed;     // base glass level, static-burst flick included
    float lit;     // 0 standby, 1 armed (ramped QML-side)
    float scan;    // beam phase, 0 top -> 1 bottom
    float roll;    // v-hold: 1 -> 0 once on power-on, else 0
    float snow;    // static-snow amount (bursts; whisper while lit)
    float ph;      // glass height in device px (scanline pitch anchor)
};
layout(binding = 1) uniform sampler2D source;

float hash(vec2 p)
{
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main()
{
    vec2 c = qt_TexCoord0 - 0.5;
    float r2 = dot(c, c);

    // glass curvature: a sub-pixel barrel bow, plus the deflection
    // settling up to full size while the v-hold rolls
    vec2 uv = 0.5 + c * (1.0 - 0.035 * r2) / (1.0 + roll * 0.05);

    // v-hold: the frame slips one full turn against the tube and locks;
    // the blanking seam rides the slip and vanishes with it
    float wy = uv.y + roll;
    uv.y = fract(wy);
    float seam = mix(1.0,
                     smoothstep(0.0, 0.05, uv.y) * smoothstep(1.0, 0.95, uv.y),
                     min(roll * 40.0, 1.0));

    vec4 s = texture(source, clamp(uv, 0.0, 1.0));

    // the beam: freshest phosphor AT the line, decaying above it (the
    // beam moves down, so what it painted longest ago has faded most)
    float d = fract(scan - uv.y);
    float beam = exp(-d * 9.0);
    float m = mix(1.0, 0.56 + 0.92 * beam, lit);
    float core = exp(-d * 70.0) * 0.30 * lit;

    // raster texture is fixed to the TUBE, not the frame — it must not
    // roll with a slipping v-hold
    float sl = 1.0 - 0.16 * (0.5 + 0.5 * sin(qt_TexCoord0.y * ph * 3.14159));
    float vig = 1.0 - smoothstep(0.15, 0.50, r2) * 0.42;
    float cb = exp(-r2 * 5.0) * (0.030 + 0.020 * lit);

    // static snow: 1px sparkle, re-rolled ~30Hz off the beam phase
    vec2 cell = floor(qt_TexCoord0 * vec2(ph * 1.28, ph));
    float g = hash(cell + floor(scan * 96.0) * vec2(7.13, 3.71));
    float sn = smoothstep(0.72, 0.95, g) * snow;

    // the band glows faintly on EMPTY glass too — the codec-call look —
    // and the core line rides it as the beam itself
    float bedA = clamp(bed, 0.0, 1.0) + cb + core * 0.55 + beam * lit * 0.035;
    vec3 col = min(tint.rgb * (bedA + sn) + s.rgb * m, vec3(1.0));
    float a = min(bedA + s.a * m + sn, 1.0);
    fragColor = vec4(col, a) * (sl * vig * seam) * qt_Opacity;
}
