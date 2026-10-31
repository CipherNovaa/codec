// The 3D tube face — ANALOG STATIC, the AV-channel nostalgia look,
// fully procedural. The set is ON or it is OFF: no roving glow bands,
// no bloom — the lit snow field against the dark hardware IS the glow.
// Crisp two-octave grain re-rolled ~90Hz with hot sparkle pops, tube
// scanline pitch, mild vignette, the one-shot v-hold roll on power-on
// (green channel-OSD appears only once the frame locks), and burst
// sparkle when the signal hiccups. Dark glass body does the specular;
// the image is pure EMISSIVE on the squashed sphere's cap.
VARYING vec3 lpos;

float hash(vec2 p)
{
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void MAIN()
{
    BASE_COLOR = vec4(0.013, 0.015, 0.018, 1.0);
    METALNESS = 0.0;

    vec2 uv = vec2(lpos.x / 94.0 + 0.5, 0.5 - lpos.y / 94.0);

    // the image is a ROUNDED RECTANGLE on the curved cap — a tube face,
    // not a porthole: SDF mask in image space, back hemisphere dead
    vec2 rq = abs(uv - vec2(0.5)) - vec2(0.44, 0.37);
    float rr = length(max(rq, vec2(0.0))) + min(max(rq.x, rq.y), 0.0);
    float cap = (1.0 - smoothstep(0.015, 0.05, rr)) * step(0.0, lpos.z);

    // NO sheen at all — every past "overglow" complaint traced back to
    // light on or around this glass that carried no information. The
    // tube is matte-dark; the static alone is the signal.
    ROUGHNESS = 0.85;
    SPECULAR_AMOUNT = 0.0;

    // v-hold: frame slips one turn and locks, blanking seam riding it
    float wy = uv.y + roll;
    vec2 suv = vec2(uv.x, fract(wy));
    float seam = mix(1.0,
                     smoothstep(0.0, 0.05, suv.y) * smoothstep(1.0, 0.95, suv.y),
                     min(roll * 40.0, 1.0));

    // SNOW is the whole show — no bands, no bloom: the set is ON or it
    // is OFF, and the state itself is the glow. Two octaves re-rolled
    // ~90Hz, shaped hard: deep darks, bright sparkle, no gray soup.
    float t = floor(scan * 240.0);
    vec2 cell = floor(suv * vec2(64.0, 48.0));
    float n1 = hash(cell + t * vec2(7.13, 3.71));
    float n2 = hash(cell * 1.7 + t * vec2(2.9, 9.4));
    float g = n1 * 0.62 + n2 * 0.38;
    float field = pow(g, 2.2) + smoothstep(0.86, 0.97, g) * 0.26;

    // analog artifacts — the detail budget the bezel gave up: rare
    // DROPOUT streaks (a row flares for a frame) and a whisper of
    // per-cell CHROMA noise (the rainbow sparkle of a dead channel)
    float row = floor(suv.y * 48.0);
    field += step(0.986, hash(vec2(row * 1.7, t * 3.1))) * 0.45 * lit;
    vec3 chroma = vec3(1.0) + vec3(hash(cell + t * 1.3) - 0.5,
                                   hash(cell * 2.3 + t) - 0.5,
                                   hash(cell * 3.1 - t) - 0.5) * 0.12;

    // burst sparkle rides on top when the signal hiccups
    float sn = smoothstep(0.72, 0.95, g) * snow;

    float sl = 1.0 - 0.13 * (0.5 + 0.5 * sin(uv.y * 3.14159 * 36.0));
    // interlace: alternate rows trade a hair of brightness each frame
    sl *= 1.0 + (mod(row + mod(t, 2.0), 2.0) - 0.5) * 0.05;
    vec2 c = uv - vec2(0.5);
    float vig = 1.0 - smoothstep(0.12, 0.34, dot(c, c)) * 0.30;

    // channel OSD — appears only once the v-hold has LOCKED
    float inA = step(0.26, suv.x) * step(suv.x, 0.315)
              * step(0.31, suv.y) * step(suv.y, 0.40);
    float inV = step(0.335, suv.x) * step(suv.x, 0.39)
              * step(0.31, suv.y) * step(suv.y, 0.40);
    float osd = (inA + inV) * lit * (1.0 - min(roll * 20.0, 1.0));

    // the bezel OVERHANGS the recessed glass: its shadow falls across
    // the image's crown — the depth cue a flat emissive cannot fake
    float lid = 1.0 - 0.38 * (1.0 - smoothstep(0.151, 0.24, uv.y));

    float bedA = clamp(bed, 0.0, 1.0);
    vec3 em = tint.rgb * bedA
            + tint.rgb * chroma * (field * 0.40 + sn) * lit
            + vec3(0.35, 0.95, 0.42) * osd * 0.55;
    EMISSIVE_COLOR = em * (sl * vig * seam * lid) * cap;
}
