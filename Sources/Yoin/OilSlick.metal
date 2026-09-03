#include <metal_stdlib>
using namespace metal;

static float hash21(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

// Value noise + fbm (Inigo Quilez style) — for organic, non-repeating drip shapes.
static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
static float fbm(float2 p) {
    float s = 0.0, amp = 0.5;
    for (int i = 0; i < 4; i++) { s += amp * vnoise(p); p *= 2.0; amp *= 0.5; }
    return s;
}

// Grain-gradient background whose colours MELT downward in organic drips — like the dripping
// chrome lettering on Drake's "Honestly, Nevermind". Uses the cover's own palette (col1..col3).
// Drips are WIDE + low-frequency so they still read as hanging tongues under a heavy blur.
[[ stitchable ]] half4 oilSlick(float2 position, half4 color, float2 size, float time,
                                float3 col1, float3 col2, float3 col3) {
    float2 uv = position / size;
    float2 q = uv * 2.2;

    // Colour field flows slowly downward (melt), not sideways.
    q.y -= time * 0.05;

    // DRIPS: wide organic tongues (from fbm) that grow downward, hang, then release — each region
    // on its own phase. Displacing q.y pulls the upper colour down into a tongue = dripping paint.
    float ridge = fbm(float2(uv.x * 3.0, 3.7));                 // wide, organic horizontal variation
    float drip  = pow(clamp(ridge, 0.0, 1.0), 2.5);            // rounded tongues
    float phase = fract(time * 0.05 + fbm(float2(uv.x * 3.0, 20.0)));  // per-region grow/fall cycle
    float grow  = phase * phase * (1.0 - smoothstep(0.82, 1.0, phase));
    q.y += drip * grow * 2.3;   // stronger so the colour tongues survive the blur
    // A little vertical wobble so tongues waver as they fall.
    q.y += 0.10 * drip * sin(uv.x * 6.0 + time * 0.4);

    // Secondary in-place morph so it's alive but not a rigid scroll.
    float ph1 = 0.6 * sin(time * 0.06);
    float ph2 = 0.6 * cos(time * 0.048);
    float a = 0.5 + 0.5 * sin(q.x * 1.6 + ph1 + sin(q.y * 1.9 + ph2));
    float b = 0.5 + 0.5 * sin((q.x + q.y) * 1.2 + ph2 + cos(q.x * 2.3 + ph1));
    float f = pow(0.5 * a + 0.5 * b, 0.85);

    // Ramp from the cover's own colours (darkest → brightest).
    float3 c0 = col1 * 0.25;
    float3 col;
    if (f < 0.4)      col = mix(c0,  col1, f / 0.4);
    else if (f < 0.7) col = mix(col1, col2, (f - 0.4) / 0.3);
    else              col = mix(col2, col3, (f - 0.7) / 0.3);

    // Gentle framing.
    float r = distance(uv, float2(0.5, 0.5));
    col *= smoothstep(1.35, 0.10, r);
    col *= mix(0.72, 1.0, smoothstep(0.10, 0.40, r));

    return half4(half3(max(col, 0.0)), 1.0h);
}

// STATIC film grain (no time term) so it doesn't shimmer; applied on top of the blurred gradient.
[[ stitchable ]] half4 filmGrain(float2 position, half4 color, float time) {
    float n = hash21(position);
    return half4(half3(n), 1.0h);
}
