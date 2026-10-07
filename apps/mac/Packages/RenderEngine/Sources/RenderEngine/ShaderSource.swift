enum ShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut compositor_vertex(uint vid [[vertex_id]],
                                       constant float4 *vertices [[buffer(0)]]) {
        float4 v = vertices[vid];
        VertexOut out;
        out.position = float4(v.xy, 0.0, 1.0);
        out.uv = v.zw;
        return out;
    }

    fragment float4 compositor_solid(VertexOut in [[stage_in]],
                                     constant float4 &color [[buffer(0)]]) {
        return color;
    }

    fragment float4 compositor_textured(VertexOut in [[stage_in]],
                                        texture2d<float> tex [[texture(0)]],
                                        constant float &opacity [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        return tex.sample(s, in.uv) * opacity;
    }

    struct VideoUniforms {
        float3x3 ycbcrMatrix;
        float3 ycbcrOffset;
        float3x3 gamutToWorking;
        float4 params;
    };

    static inline float3 video_eotf(float3 c) {
        float3 lo = c / 12.92;
        float3 hi = pow((c + 0.055) / 1.055, 2.4);
        return select(hi, lo, c <= 0.04045);
    }

    fragment float4 compositor_video_ycbcr(VertexOut in [[stage_in]],
                                           texture2d<float> lumaTex [[texture(0)]],
                                           texture2d<float> chromaTex [[texture(1)]],
                                           constant VideoUniforms &u [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float inBounds = all(in.uv >= 0.0) && all(in.uv <= 1.0) ? 1.0 : 0.0;
        float y = lumaTex.sample(s, in.uv).r;
        float2 c = chromaTex.sample(s, in.uv).rg;
        float3 rgb = u.ycbcrMatrix * (float3(y, c.x, c.y) - u.ycbcrOffset);
        rgb = clamp(rgb, 0.0, 1.0);
        rgb = u.gamutToWorking * video_eotf(rgb);
        return float4(rgb, 1.0) * u.params.y * inBounds;
    }

    fragment float4 compositor_video_rgba(VertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          constant VideoUniforms &u [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float inBounds = all(in.uv >= 0.0) && all(in.uv <= 1.0) ? 1.0 : 0.0;
        float4 c = tex.sample(s, in.uv);
        float3 straight = (u.params.x > 0.5 && c.a > 0.0) ? c.rgb / c.a : c.rgb;
        float3 lin = u.gamutToWorking * video_eotf(clamp(straight, 0.0, 1.0));
        return float4(lin * c.a, c.a) * u.params.y * inBounds;
    }

    static inline float2 masked_media_uv(float2 uv, float4 uvMap) {
        return uv * uvMap.xy + uvMap.zw;
    }

    static inline float mask_coverage(float2 muv, float4 uvBounds,
                                      texture2d<float> maskTex, float2 uv) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float inBounds = all(muv >= uvBounds.xy) && all(muv <= uvBounds.zw) ? 1.0 : 0.0;
        return inBounds * maskTex.sample(s, uv).a;
    }

    fragment float4 compositor_video_ycbcr_masked(VertexOut in [[stage_in]],
                                                  texture2d<float> lumaTex [[texture(0)]],
                                                  texture2d<float> chromaTex [[texture(1)]],
                                                  texture2d<float> maskTex [[texture(2)]],
                                                  constant VideoUniforms &u [[buffer(0)]],
                                                  constant float4 &uvMap [[buffer(1)]],
                                                  constant float4 &uvBounds [[buffer(2)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float2 muv = masked_media_uv(in.uv, uvMap);
        float coverage = mask_coverage(muv, uvBounds, maskTex, in.uv);
        float y = lumaTex.sample(s, clamp(muv, 0.0, 1.0)).r;
        float2 c = chromaTex.sample(s, clamp(muv, 0.0, 1.0)).rg;
        float3 rgb = u.ycbcrMatrix * (float3(y, c.x, c.y) - u.ycbcrOffset);
        rgb = clamp(rgb, 0.0, 1.0);
        rgb = u.gamutToWorking * video_eotf(rgb);
        return float4(rgb, 1.0) * u.params.y * coverage;
    }

    fragment float4 compositor_color_adjust(VertexOut in [[stage_in]],
                                            texture2d<float> tex [[texture(0)]],
                                            constant float4 &adjust [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float4 c = tex.sample(s, in.uv);
        float3 straight = c.a > 0.0 ? c.rgb / c.a : c.rgb;
        if (abs(adjust.w) > 1e-4) {
            float hk = cos(adjust.w), ht = sin(adjust.w);
            float3x3 hm = float3x3(
                float3(0.213 + hk * 0.787 - ht * 0.213, 0.213 - hk * 0.213 + ht * 0.143, 0.213 - hk * 0.213 - ht * 0.787),
                float3(0.715 - hk * 0.715 - ht * 0.715, 0.715 + hk * 0.285 + ht * 0.140, 0.715 - hk * 0.715 + ht * 0.715),
                float3(0.072 - hk * 0.072 + ht * 0.928, 0.072 - hk * 0.072 - ht * 0.283, 0.072 + hk * 0.928 + ht * 0.072));
            straight = clamp(hm * straight, 0.0, 1.0);
        }
        float luma = dot(straight, float3(0.2126, 0.7152, 0.0722));
        straight = mix(float3(luma), straight, adjust.z);
        straight = (straight - 0.5) * (1.0 + adjust.y) + 0.5;
        straight = max(straight + adjust.x, 0.0);
        return float4(straight * c.a, c.a);
    }

    fragment float4 compositor_hue_rotate(VertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float4 c = tex.sample(s, in.uv);
        float3 straight = c.a > 0.0 ? c.rgb / c.a : c.rgb;
        float k = cos(params.x), t = sin(params.x);
        float3x3 m = float3x3(
            float3(0.213 + k * 0.787 - t * 0.213, 0.213 - k * 0.213 + t * 0.143, 0.213 - k * 0.213 - t * 0.787),
            float3(0.715 - k * 0.715 - t * 0.715, 0.715 + k * 0.285 + t * 0.140, 0.715 - k * 0.715 + t * 0.715),
            float3(0.072 - k * 0.072 + t * 0.928, 0.072 - k * 0.072 - t * 0.283, 0.072 + k * 0.928 + t * 0.072));
        straight = clamp(m * straight, 0.0, 1.0);
        return float4(straight * c.a, c.a);
    }

    fragment float4 compositor_invert(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float4 c = tex.sample(s, in.uv);
        float3 straight = c.a > 0.0 ? c.rgb / c.a : c.rgb;
        straight = 1.0 - straight;
        return float4(straight * c.a, c.a);
    }

    fragment float4 compositor_posterize(VertexOut in [[stage_in]],
                                         texture2d<float> tex [[texture(0)]],
                                         constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float4 c = tex.sample(s, in.uv);
        float3 straight = c.a > 0.0 ? c.rgb / c.a : c.rgb;
        float steps = max(params.x - 1.0, 1.0);
        straight = round(straight * steps) / steps;
        return float4(straight * c.a, c.a);
    }

    fragment float4 compositor_pixelate(VertexOut in [[stage_in]],
                                        texture2d<float> tex [[texture(0)]],
                                        constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::nearest, min_filter::nearest);
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 cell = max(params.x, 1.0) / size;
        float2 uv = (floor(in.uv / cell) + 0.5) * cell;
        return tex.sample(s, uv);
    }

    fragment float4 compositor_vignette(VertexOut in [[stage_in]],
                                        texture2d<float> tex [[texture(0)]],
                                        constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float4 c = tex.sample(s, in.uv);
        float3 straight = c.a > 0.0 ? c.rgb / c.a : c.rgb;
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 p = in.uv - 0.5;
        p.x *= size.x / max(size.y, 1.0);
        float span = length(float2(0.5 * size.x / max(size.y, 1.0), 0.5));
        float d = length(p) / max(span, 1e-4);
        float shade = 1.0 - clamp(params.x, 0.0, 1.5) * smoothstep(0.35, 1.0, d);
        straight *= max(shade, 0.0);
        return float4(straight * c.a, c.a);
    }

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

    fragment float4 compositor_warp(VertexOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_zero,
                            mag_filter::linear, min_filter::linear);
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 px = in.uv * size;
        float cell = max(params.y, 1.0);
        float3 p = float3(px / cell, params.z);
        float nx = warp_noise(p) * 0.7 + warp_noise(p * 2.0 + 17.0) * 0.3 - 0.5;
        float ny = warp_noise(p + float3(41.7, 13.3, 7.9)) * 0.7
                 + warp_noise(p * 2.0 + float3(29.1, 5.2, 3.3)) * 0.3 - 0.5;
        float2 offset = float2(nx, ny) * 2.0 * params.x;
        return tex.sample(s, (px + offset) / size);
    }

    static float2 scatter_offset(float2 p, float roll) {
        float2 c = floor(p);
        return float2(warp_hash(float3(c, roll)), warp_hash(float3(c + 71.3, roll + 3.7))) - 0.5;
    }

    fragment float4 compositor_scatter(VertexOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_zero,
                            mag_filter::linear, min_filter::linear);
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 px = in.uv * size;
        float2 p = px / max(params.z, 1.0);
        float2 hard = scatter_offset(p, params.y);
        float2 n = hard;
        if (params.w > 0.001) {
            float2 f = fract(p - 0.5);
            f = f * f * (3.0 - 2.0 * f);
            float2 base = p - 0.5;
            float2 o00 = scatter_offset(base, params.y);
            float2 o10 = scatter_offset(base + float2(1, 0), params.y);
            float2 o01 = scatter_offset(base + float2(0, 1), params.y);
            float2 o11 = scatter_offset(base + float2(1, 1), params.y);
            float2 smoothed = mix(mix(o00, o10, f.x), mix(o01, o11, f.x), f.y);
            n = mix(hard, smoothed, params.w);
        }
        float2 offset = n * 2.0 * params.x;
        return tex.sample(s, (px + offset) / size);
    }

    fragment float4 compositor_stained_glass(VertexOut in [[stage_in]],
                                             texture2d<float> tex [[texture(0)]],
                                             constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_zero,
                            mag_filter::linear, min_filter::linear);
        float2 size = float2(tex.get_width(), tex.get_height());
        float cell = max(params.x, 2.0);
        float2 p = in.uv * size / cell;
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
        float4 pane = tex.sample(s, best * cell / size);
        float lead = params.y / cell;
        float aa = 1.0 / cell;
        float edge = smoothstep(lead, lead + aa * 1.5, d2 - d1);
        return float4(pane.rgb * edge, pane.a);
    }

    fragment float4 compositor_grain(VertexOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 cell = floor(in.uv * size / max(params.y, 1.0));
        float n = warp_hash(float3(cell, params.z)) - 0.5;
        float4 c = tex.sample(s, in.uv);
        float3 straight = c.a > 0.0 ? c.rgb / c.a : c.rgb;
        straight = clamp(straight + n * params.x, 0.0, 1.0);
        return float4(straight * c.a, c.a);
    }

    fragment float4 compositor_glitch(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float2 size = float2(tex.get_width(), tex.get_height());
        float strength = params.x;
        float roll = floor(params.y * 24.0);
        float band = floor(in.uv.y * 18.0);
        float h = warp_hash(float3(band, roll, 1.0));
        float active = h > (1.0 - 0.55 * strength) ? 1.0 : 0.0;
        float dir = warp_hash(float3(band, roll, 2.0)) - 0.5;
        float shift = active * dir * params.z * strength / max(size.x, 1.0);
        float2 uv = in.uv + float2(shift, 0.0);
        float split = strength * 6.0 / max(size.x, 1.0);
        float4 c = tex.sample(s, uv);
        float4 r = tex.sample(s, uv + float2(split, 0.0));
        float4 b = tex.sample(s, uv - float2(split, 0.0));
        float a = max(c.a, max(r.a, b.a));
        return float4(r.r, c.g, b.b, a);
    }

    fragment float4 compositor_burn(VertexOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float4 c = tex.sample(s, in.uv);
        float center = mix(-0.4, 1.4, params.y);
        float d = (in.uv.x - center) / 0.35;
        float leak = params.x * exp(-d * d);
        float3 warm = float3(1.0, 0.72, 0.42);
        float3 rgb = c.rgb * (1.0 + leak * 1.5) + warm * leak * c.a;
        return float4(min(rgb, float3(c.a) * 4.0), c.a);
    }

    fragment float4 compositor_tint(VertexOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float4 c = tex.sample(s, in.uv);
        float3 straight = c.a > 0.0 ? c.rgb / c.a : c.rgb;
        straight = mix(straight, params.xyz, clamp(params.w, 0.0, 1.0));
        return float4(straight * c.a, c.a);
    }

    fragment float4 compositor_echo(VertexOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    texture2d<float> history [[texture(1)]],
                                    constant float4 &params [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float4 fresh = tex.sample(s, in.uv);
        if (params.y < 0.5) { return fresh; }
        float4 trail = history.sample(s, in.uv) * clamp(params.x, 0.0, 0.999);
        return max(fresh, trail);
    }

    fragment float4 compositor_ghost_trails(VertexOut in [[stage_in]],
                                            texture2d<float> tex [[texture(0)]],
                                            texture2d<float> history [[texture(1)]],
                                            constant float4 &params [[buffer(0)]],
                                            constant float4 &drift [[buffer(1)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_zero,
                            mag_filter::linear, min_filter::linear);
        float4 fresh = tex.sample(s, in.uv);
        if (params.y < 0.5) { return fresh; }
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 px = in.uv * size;
        float cell = max(drift.y, 1.0);
        float3 p = float3(px / cell, drift.z);
        float nx = warp_noise(p) * 0.7 + warp_noise(p * 2.0 + 17.0) * 0.3 - 0.5;
        float ny = warp_noise(p + float3(41.7, 13.3, 7.9)) * 0.7
                 + warp_noise(p * 2.0 + float3(29.1, 5.2, 3.3)) * 0.3 - 0.5;
        float2 offset = float2(nx, ny) * 2.0 * drift.x;
        float4 trail = history.sample(s, (px + offset) / size) * clamp(params.x, 0.0, 0.999);
        return max(fresh, trail);
    }

    fragment float4 compositor_masked(VertexOut in [[stage_in]],
                                      texture2d<float> content [[texture(0)]],
                                      texture2d<float> matte [[texture(1)]],
                                      constant float4 &uvMap [[buffer(0)]],
                                      constant float4 &params [[buffer(1)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float4 c = content.sample(s, in.uv);
        float2 muv = in.uv * uvMap.xy + uvMap.zw;
        float inBounds = (all(muv >= 0.0) && all(muv <= 1.0)) ? 1.0 : 0.0;
        float alpha = matte.sample(s, clamp(muv, 0.0, 1.0)).a * inBounds;
        float coverage = params.x > 0.5 ? (1.0 - alpha) : alpha;
        return c * coverage * params.y;
    }

    fragment float4 compositor_video_rgba_masked(VertexOut in [[stage_in]],
                                                 texture2d<float> tex [[texture(0)]],
                                                 texture2d<float> maskTex [[texture(1)]],
                                                 constant VideoUniforms &u [[buffer(0)]],
                                                 constant float4 &uvMap [[buffer(1)]],
                                                 constant float4 &uvBounds [[buffer(2)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float2 muv = masked_media_uv(in.uv, uvMap);
        float coverage = mask_coverage(muv, uvBounds, maskTex, in.uv);
        float4 c = tex.sample(s, clamp(muv, 0.0, 1.0));
        float3 straight = (u.params.x > 0.5 && c.a > 0.0) ? c.rgb / c.a : c.rgb;
        float3 lin = u.gamutToWorking * video_eotf(clamp(straight, 0.0, 1.0));
        return float4(lin * c.a, c.a) * u.params.y * coverage;
    }

    struct OutputWarpVertex {
        float4 posUV;
        float4 q;
    };

    struct OutputWarpOut {
        float4 position [[position]];
        float3 uvq;
    };

    struct OutputAdjustUniforms {
        float4 color;
        float4 rgb;
        float4 blendLeft;
        float4 blendRight;
        float4 blendTop;
        float4 blendBottom;
        float4 sourceRect;
    };

    vertex OutputWarpOut output_warp_vertex(uint vid [[vertex_id]],
                                            constant OutputWarpVertex *verts [[buffer(0)]]) {
        OutputWarpVertex v = verts[vid];
        OutputWarpOut out;
        out.position = float4(v.posUV.xy, 0.0, 1.0);
        out.uvq = float3(v.posUV.zw, v.q.x);
        return out;
    }

    static inline float2 output_edge_blend(float distance, float4 edge) {
        if (edge.x <= 0.0) { return float2(1.0, 0.0); }
        float t = clamp(distance / max(edge.x, 1e-4), 0.0, 1.0);
        float ramp = pow(t, max(edge.y, 0.01));
        return float2(1.0 - edge.z * (1.0 - ramp), edge.w * ramp);
    }

    struct BuildUniforms {
        float4 matteRect;
        float4 params;
        float4 wipe;
        float4 wipeFeather;
        float4 wipeFeatherMax;
    };

    static inline float build_edge(float distance, float feather) {
        return feather > 1e-6 ? clamp(distance / feather, 0.0, 1.0) : (distance >= 0.0 ? 1.0 : 0.0);
    }

    fragment float4 compositor_build(OutputWarpOut in [[stage_in]],
                                     texture2d<float> content [[texture(0)]],
                                     texture2d<float> matte [[texture(1)]],
                                     constant BuildUniforms &u [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float2 uv = in.uvq.xy / max(in.uvq.z, 1e-6);
        if (any(uv < 0.0) || any(uv > 1.0)) { return float4(0.0); }
        float4 c = content.sample(s, uv);
        float coverage = 1.0;
        if (u.params.z > 0.5) {
            float2 muv = (in.position.xy - u.matteRect.xy) / u.matteRect.zw;
            float inBounds = (all(muv >= 0.0) && all(muv <= 1.0)) ? 1.0 : 0.0;
            float alpha = matte.sample(s, clamp(muv, 0.0, 1.0)).a * inBounds;
            coverage = u.params.x > 0.5 ? (1.0 - alpha) : alpha;
        }
        if (u.wipeFeather.z > 0.5) {
            float wx = min(build_edge(uv.x - u.wipe.x, u.wipeFeather.x),
                           build_edge(u.wipe.y - uv.x, u.wipeFeatherMax.x));
            float wy = min(build_edge(uv.y - u.wipe.z, u.wipeFeather.y),
                           build_edge(u.wipe.w - uv.y, u.wipeFeatherMax.y));
            coverage *= wx * wy;
        }
        return c * coverage * u.params.y;
    }

    fragment float4 output_adjust_fragment(OutputWarpOut in [[stage_in]],
                                           texture2d<float> tex [[texture(0)]],
                                           texture2d<float> mask [[texture(1)]],
                                           constant OutputAdjustUniforms &u [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear);
        float2 uv = in.uvq.xy / max(in.uvq.z, 1e-6);
        float2 local = (uv - u.sourceRect.xy) / u.sourceRect.zw;
        if (any(local < 0.0) || any(local > 1.0)) { return float4(0.0); }
        float4 c = tex.sample(s, uv);
        float alpha = c.a;
        float3 rgb = alpha > 0.0 ? c.rgb / alpha : c.rgb;
        rgb = max(rgb + u.color.w, 0.0);
        rgb = rgb + u.color.x;
        rgb = (rgb - 0.5) * (1.0 + u.color.y) + 0.5;
        rgb = rgb * (1.0 + u.rgb.xyz);
        rgb = pow(max(rgb, 0.0), float3(1.0 / clamp(1.0 + u.color.z, 0.05, 20.0)));
        float2 left = output_edge_blend(local.x, u.blendLeft);
        float2 right = output_edge_blend(1.0 - local.x, u.blendRight);
        float2 top = output_edge_blend(local.y, u.blendTop);
        float2 bottom = output_edge_blend(1.0 - local.y, u.blendBottom);
        float falloff = left.x * right.x * top.x * bottom.x;
        float lift = max(max(left.y, right.y), max(top.y, bottom.y));
        float coverage = u.rgb.w > 0.5 ? mask.sample(s, uv).r : 1.0;
        float outAlpha = alpha * falloff * coverage;
        return float4(rgb * outAlpha + lift * alpha * coverage, outAlpha);
    }
    """
}
