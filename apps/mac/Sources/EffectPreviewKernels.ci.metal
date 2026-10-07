#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

static float warp_hash(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

static float warp_noise(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = warp_hash(i + float3(0, 0, 0)), n100 = warp_hash(i + float3(1, 0, 0));
    float n010 = warp_hash(i + float3(0, 1, 0)), n110 = warp_hash(i + float3(1, 1, 0));
    float n001 = warp_hash(i + float3(0, 0, 1)), n101 = warp_hash(i + float3(1, 0, 1));
    float n011 = warp_hash(i + float3(0, 1, 1)), n111 = warp_hash(i + float3(1, 1, 1));
    float x00 = mix(n000, n100, f.x), x10 = mix(n010, n110, f.x);
    float x01 = mix(n001, n101, f.x), x11 = mix(n011, n111, f.x);
    float y0 = mix(x00, x10, f.y), y1 = mix(x01, x11, f.y);
    return mix(y0, y1, f.z);
}

static float2 scatter_offset(float2 p, float roll) {
    float2 c = floor(p);
    return float2(warp_hash(float3(c, roll)), warp_hash(float3(c + 71.3, roll + 3.7))) - 0.5;
}

extern "C" {

    float2 warpEffect(float4 params, coreimage::destination dest) {
        float2 px = dest.coord();
        float2 flipped = float2(px.x, params.w - px.y);
        float cell = max(params.y, 1.0);
        float3 p = float3(flipped / cell, params.z);
        float nx = warp_noise(p) * 0.7 + warp_noise(p * 2.0 + 17.0) * 0.3 - 0.5;
        float ny = warp_noise(p + float3(41.7, 13.3, 7.9)) * 0.7
                 + warp_noise(p * 2.0 + float3(29.1, 5.2, 3.3)) * 0.3 - 0.5;
        float2 offset = float2(nx, ny) * 2.0 * params.x;

        return px + float2(offset.x, -offset.y);
    }

    float2 scatterEffect(float4 params, float smooth, coreimage::destination dest) {
        float2 px = dest.coord();
        float2 p = float2(px.x, params.w - px.y) / max(params.z, 1.0);
        float2 hard = scatter_offset(p, params.y);
        float2 n = hard;
        if (smooth > 0.001) {
            float2 f = fract(p - 0.5);
            f = f * f * (3.0 - 2.0 * f);
            float2 base = p - 0.5;
            float2 o00 = scatter_offset(base, params.y);
            float2 o10 = scatter_offset(base + float2(1, 0), params.y);
            float2 o01 = scatter_offset(base + float2(0, 1), params.y);
            float2 o11 = scatter_offset(base + float2(1, 1), params.y);
            float2 smoothed = mix(mix(o00, o10, f.x), mix(o01, o11, f.x), f.y);
            n = mix(hard, smoothed, smooth);
        }
        float2 offset = n * 2.0 * params.x;
        return px + float2(offset.x, -offset.y);
    }

    float4 stainedGlassEffect(coreimage::sampler src, float4 params, float height,
                              coreimage::destination dest) {
        float2 px = dest.coord();
        float cell = max(params.x, 2.0);
        float2 flipped = float2(px.x, height - px.y);
        float2 p = flipped / cell;
        float2 g = floor(p), f = fract(p);
        float d1 = 8.0, d2 = 8.0;
        float2 best = g + 0.5;
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                float2 o = float2(i, j);
                float2 c = g + o;
                float2 h = float2(warp_hash(float3(c, 1.0)), warp_hash(float3(c, 2.0)));
                float2 r = 0.5 + (h - 0.5) * params.z;
                r += 0.15 * params.z * float2(sin(params.w + h.x * 6.2831), cos(params.w + h.y * 6.2831));
                float2 d = o + r - f;
                float dist = length(d);
                if (dist < d1) { d2 = d1; d1 = dist; best = c + r; }
                else if (dist < d2) { d2 = dist; }
            }
        }
        float2 seed = best * cell;
        float2 seedCI = float2(seed.x, height - seed.y);
        float4 pane = src.sample(src.transform(seedCI));
        float lead = params.y / cell;
        float aa = 1.0 / cell;
        float edge = smoothstep(lead, lead + aa * 1.5, d2 - d1);
        return float4(pane.rgb * edge, pane.a);
    }

    float4 grainEffect(coreimage::sample_t s, float4 params, coreimage::destination dest) {
        float2 px = dest.coord();
        float2 cell = floor(float2(px.x, params.w - px.y) / max(params.y, 1.0));
        float n = warp_hash(float3(cell, params.z)) - 0.5;
        float3 straight = s.a > 0.0 ? s.rgb / s.a : s.rgb;
        straight = clamp(straight + n * params.x, 0.0, 1.0);
        return float4(straight * s.a, s.a);
    }
}
