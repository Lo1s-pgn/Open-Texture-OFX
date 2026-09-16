#include <metal_stdlib>
using namespace metal;
#include "LSPOpenTextureMetalCommon.metal"

struct OpenTextureGlareParams {
    float threshold;
    float smoothness;
    float maxBrightness;
    int quality;
    int qualityFactor;
    float spread;
    float strength;
    float saturation;
    float temperature;
    float exposure;
    float glareAmount;
    int chainLength;
    int chainLengthAlt;
    float chainBlend;
    int clampEnabled;
    int displayMode;
    int highlightsWidth;
    int highlightsHeight;
    float bloomBlurSigma;
};

constant int kGlareDisplayRender = 0;
constant int kGlareDisplaySource = 1;
constant int kGlareDisplayDiffusion = 2;

constant int kGlareQualityHigh = 0;
constant int kGlareQualityMedium = 1;
constant int kGlareQualityLow = 2;

inline float glareExtractHighlightV(float v, float minL, float maxL, float smoothness, int clampEnabled) {
    float src = max(v, 0.0f);
    if (clampEnabled != 0)
        src = min(src, maxL);
    const float knee = clamp(smoothness, 0.0f, 1.0f) * max(minL, 1.0e-3f);
    const float lo = max(minL - knee, 0.0f);
    if (knee <= 1.0e-6f)
        return max(src - minL, 0.0f);
    if (src <= lo)
        return 0.0f;
    if (src < minL) {
        const float d = src - lo;
        return (d * d) / (2.0f * knee);
    }
    return src - minL + 0.5f * knee;
}

inline void glare_rgb_to_hsv(float3 rgb, thread float& h, thread float& s, thread float& v) {
    float cmax = max(rgb.r, max(rgb.g, rgb.b));
    float cmin = min(rgb.r, min(rgb.g, rgb.b));
    float delta = cmax - cmin;
    v = cmax;
    if (delta < 1.0e-8f) {
        h = 0.0f;
        s = 0.0f;
        return;
    }
    s = delta / cmax;
    if (cmax == rgb.r)
        h = (rgb.g - rgb.b) / delta + (rgb.g < rgb.b ? 6.0f : 0.0f);
    else if (cmax == rgb.g)
        h = (rgb.b - rgb.r) / delta + 2.0f;
    else
        h = (rgb.r - rgb.g) / delta + 4.0f;
    h /= 6.0f;
}

inline float3 glare_hsv_to_rgb(float h, float s, float v) {
    if (s <= 1.0e-8f)
        return float3(v);
    float hh = fract(h) * 6.0f;
    int i = int(hh);
    float f = hh - float(i);
    float p = v * (1.0f - s);
    float q = v * (1.0f - s * f);
    float t = v * (1.0f - s * (1.0f - f));
    if (i == 0) return float3(v, t, p);
    if (i == 1) return float3(q, v, p);
    if (i == 2) return float3(p, v, t);
    if (i == 3) return float3(p, q, v);
    if (i == 4) return float3(t, p, v);
    return float3(v, p, q);
}

// log compress core mask so hdr cores dont pin at 1.0 (rings if clamp off)
inline float glareLog1p(float x) {
    return log(1.0f + max(x, 0.0f));
}

inline float glareHighlightAmount(float3 rgbLin, float threshold, float maxBrightness, float smoothness,
                                  int clampEnabled) {
    float h, s, v;
    glare_rgb_to_hsv(max(rgbLin, float3(0.0f)), h, s, v);
    return glareExtractHighlightV(v, threshold, maxBrightness, smoothness, clampEnabled);
}

inline float glareCoreWeight(float highlightAmt, float threshold, float smoothness, float exposure,
                             float maxBrightness) {
    if (highlightAmt <= 1.0e-6f)
        return 0.0f;

    const float lowShift = 1.0f - clamp(exposure, 0.0f, 1.0f);
    const bool unclamped = maxBrightness > threshold + 100.0f;

    float headroom = max(maxBrightness - threshold, 0.0f);
    if (unclamped) {
        headroom = max(threshold * 0.35f + smoothness * 0.5f + 0.15f, 0.35f);
        headroom *= (5.0f + lowShift * 5.0f);
    } else {
        headroom = max(headroom, smoothness * 0.25f + 0.08f);
    }

    const float knee = max(headroom * (0.25f + lowShift * 0.5f), smoothness * 0.12f + 0.04f);
    const float srcSoft = glareLog1p(highlightAmt / knee);
    const float highSoft = glareLog1p(headroom / knee);

    float core = smoothstep(0.0f, max(highSoft, 1.0e-4f), srcSoft);
    core = pow(core, 1.0f + lowShift * 3.0f);
    return core;
}

inline float3 glareApplyExposureShift(float exposure, float3 bloomDelta, float3 inputLin, float threshold,
                                      float smoothness, float maxBrightness, int clampEnabled) {
    if (abs(exposure - 1.0f) < 1.0e-5f)
        return bloomDelta;
    const float highlightAmt = glareHighlightAmount(inputLin, threshold, maxBrightness, smoothness, clampEnabled);
    const float core = glareCoreWeight(highlightAmt, threshold, smoothness, exposure, maxBrightness);
    const float scale = mix(1.0f, exposure, core);
    return bloomDelta * scale;
}

kernel void k_glare_decode_to_lin_tex(device const float* srcStrided [[buffer(0)]],
                                      texture2d<float, access::write> rgbLin [[texture(0)]],
                                      constant OpenTextureMetalParams& p [[buffer(2)]],
                                      uint2 gid [[thread_position_in_grid]]) {
    if ((int)gid.x >= p.width || (int)gid.y >= p.height)
        return;
    int si = (int)gid.y * p.dstRowFloats + (int)gid.x * 4;
    float3 enc = make3(sanitizeFinite(srcStrided[si + 0], 0.0f),
                       sanitizeFinite(srcStrided[si + 1], 0.0f),
                       sanitizeFinite(srcStrided[si + 2], 0.0f));
    float a = sanitizeFinite(srcStrided[si + 3], 1.0f);
    float3 c = host_to_working(enc, p);
    rgbLin.write(float4(c, a), gid);
}

kernel void k_glare_highlights(texture2d<float, access::sample> inputTex [[texture(0)]],
                               texture2d<float, access::write> outputTex [[texture(1)]],
                               constant OpenTextureGlareParams& gp [[buffer(0)]],
                               constant OpenTextureMetalParams& p [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if ((int)gid.x >= gp.highlightsWidth || (int)gid.y >= gp.highlightsHeight)
        return;

    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float4 color = float4(0.0f);
    const int iw = p.width;
    const int ih = p.height;

    if (gp.quality == kGlareQualityHigh) {
        float2 uv = (float2(gid) + 0.5f) / float2(iw, ih);
        color = inputTex.sample(smp, uv);
    } else if (gp.quality == kGlareQualityMedium) {
        float2 uv = (float2(gid) * 2.0f + float2(1.0f)) / float2(iw, ih);
        color = inputTex.sample(smp, uv);
    } else if (gp.quality == kGlareQualityLow) {
        float2 ll = (float2(gid) * 4.0f + float2(1.0f)) / float2(iw, ih);
        float2 lr = (float2(gid) * 4.0f + float2(3.0f, 1.0f)) / float2(iw, ih);
        float2 ul = (float2(gid) * 4.0f + float2(1.0f, 3.0f)) / float2(iw, ih);
        float2 ur = (float2(gid) * 4.0f + float2(3.0f)) / float2(iw, ih);
        color = (inputTex.sample(smp, ul) + inputTex.sample(smp, ur) +
                 inputTex.sample(smp, ll) + inputTex.sample(smp, lr)) * 0.25f;
    }

    float h, s, v;
    glare_rgb_to_hsv(color.rgb, h, s, v);
    v = glareExtractHighlightV(v, gp.threshold, gp.maxBrightness, gp.smoothness, gp.clampEnabled);
    float3 outRgb = glare_hsv_to_rgb(h, s, v);
    outputTex.write(float4(outRgb, 1.0f), gid);
}

kernel void k_glare_bloom_up(texture2d<float, access::sample> inputTex [[texture(0)]],
                             texture2d<float, access::read_write> outputTex [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    const int ow = outputTex.get_width();
    const int oh = outputTex.get_height();
    if ((int)gid.x >= ow || (int)gid.y >= oh)
        return;

    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 coordinates = (float2(gid) + 0.5f) / float2(ow, oh);
    float2 pixel_size = 1.0f / float2(ow, oh);

    float4 upsampled = float4(0.0f);
    upsampled += (4.0f / 16.0f) * inputTex.sample(smp, coordinates);
    upsampled += (2.0f / 16.0f) * inputTex.sample(smp, coordinates + pixel_size * float2(-1.0f, 0.0f));
    upsampled += (2.0f / 16.0f) * inputTex.sample(smp, coordinates + pixel_size * float2(0.0f, 1.0f));
    upsampled += (2.0f / 16.0f) * inputTex.sample(smp, coordinates + pixel_size * float2(1.0f, 0.0f));
    upsampled += (2.0f / 16.0f) * inputTex.sample(smp, coordinates + pixel_size * float2(0.0f, -1.0f));
    upsampled += (1.0f / 16.0f) * inputTex.sample(smp, coordinates + pixel_size * float2(-1.0f, -1.0f));
    upsampled += (1.0f / 16.0f) * inputTex.sample(smp, coordinates + pixel_size * float2(-1.0f, 1.0f));
    upsampled += (1.0f / 16.0f) * inputTex.sample(smp, coordinates + pixel_size * float2(1.0f, -1.0f));
    upsampled += (1.0f / 16.0f) * inputTex.sample(smp, coordinates + pixel_size * float2(1.0f, 1.0f));

    float4 combined = outputTex.read(gid) + upsampled;
    outputTex.write(float4(combined.rgb, 1.0f), gid);
}

kernel void k_glare_copy_tex(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    const int w = dst.get_width();
    const int h = dst.get_height();
    if ((int)gid.x >= w || (int)gid.y >= h)
        return;
    dst.write(src.read(gid), gid);
}

kernel void k_glare_lerp_tex(texture2d<float, access::read> a [[texture(0)]],
                             texture2d<float, access::read> b [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant float& blend [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    const int w = dst.get_width();
    const int h = dst.get_height();
    if ((int)gid.x >= w || (int)gid.y >= h)
        return;
    float t = clamp(blend, 0.0f, 1.0f);
    float4 ca = a.read(gid);
    float4 cb = b.read(gid);
    dst.write(mix(ca, cb, t), gid);
}

// tent upsample; bilinear alone leaves ~4px stairs on bloom upscale
kernel void k_glare_half_res_up(texture2d<float, access::sample> inputTex [[texture(0)]],
                                texture2d<float, access::write> outputTex [[texture(1)]],
                                constant int2& inSize [[buffer(0)]],
                                constant int2& outSize [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    const int ow = outSize.x;
    const int oh = outSize.y;
    if ((int)gid.x >= ow || (int)gid.y >= oh)
        return;

    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    const float2 coord = (float2(gid) + 0.5f) / float2(ow, oh);
    const float2 pixel_size = 1.0f / float2(inSize.x, inSize.y);

    float4 up = float4(0.0f);
    up += (4.0f / 16.0f) * inputTex.sample(smp, coord);
    up += (2.0f / 16.0f) * inputTex.sample(smp, coord + pixel_size * float2(-1.0f, 0.0f));
    up += (2.0f / 16.0f) * inputTex.sample(smp, coord + pixel_size * float2(1.0f, 0.0f));
    up += (2.0f / 16.0f) * inputTex.sample(smp, coord + pixel_size * float2(0.0f, -1.0f));
    up += (2.0f / 16.0f) * inputTex.sample(smp, coord + pixel_size * float2(0.0f, 1.0f));
    up += (1.0f / 16.0f) * inputTex.sample(smp, coord + pixel_size * float2(-1.0f, -1.0f));
    up += (1.0f / 16.0f) * inputTex.sample(smp, coord + pixel_size * float2(1.0f, -1.0f));
    up += (1.0f / 16.0f) * inputTex.sample(smp, coord + pixel_size * float2(-1.0f, 1.0f));
    up += (1.0f / 16.0f) * inputTex.sample(smp, coord + pixel_size * float2(1.0f, 1.0f));

    outputTex.write(float4(up.rgb, 1.0f), gid);
}

kernel void k_glare_mix_encode(texture2d<float, access::sample> glareTex [[texture(0)]],
                               device const float* baseStrided [[buffer(0)]],
                               device float* dstStrided [[buffer(1)]],
                               constant OpenTextureGlareParams& gp [[buffer(2)]],
                               constant OpenTextureMetalParams& p [[buffer(3)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if ((int)gid.x >= p.width || (int)gid.y >= p.height)
        return;

    int si = (int)gid.y * p.dstRowFloats + (int)gid.x * 4;
    float3 enc = make3(sanitizeFinite(baseStrided[si + 0], 0.0f),
                       sanitizeFinite(baseStrided[si + 1], 0.0f),
                       sanitizeFinite(baseStrided[si + 2], 0.0f));
    float alpha = sanitizeFinite(baseStrided[si + 3], 1.0f);
    float3 inputLin = max(host_to_working(enc, p), float3(0.0f));

    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    const float2 uv = (float2(gid) + 0.5f) / float2(p.width, p.height);
    float3 glareRgb = float3(glareTex.sample(smp, uv).rgb);

    if (gp.displayMode == kGlareDisplaySource) {
        float3 outEnc = working_to_host(max(glareRgb, float3(0.0f)), p);
        dstStrided[si + 0] = outEnc.r;
        dstStrided[si + 1] = outEnc.g;
        dstStrided[si + 2] = outEnc.b;
        dstStrided[si + 3] = alpha;
        return;
    }

    const float lum = dot(glareRgb, float3(0.2126f, 0.7152f, 0.0722f));
    float3 chroma = glareRgb - float3(lum);
    glareRgb = float3(lum) + chroma * gp.saturation;

    const float warm = (gp.temperature - 0.5f) * 2.0f;
    const float3 tempGain = float3(1.0f + 0.35f * warm, 1.0f, 1.0f - 0.35f * warm);
    glareRgb *= tempGain;
    glareRgb *= gp.glareAmount;

    if (gp.displayMode == kGlareDisplayRender)
        glareRgb = glareApplyExposureShift(gp.exposure, glareRgb, inputLin, gp.threshold, gp.smoothness,
                                             gp.maxBrightness, gp.clampEnabled);

    if (gp.displayMode == kGlareDisplayDiffusion) {
        float3 outEnc = working_to_host(max(glareRgb, float3(0.0f)), p);
        dstStrided[si + 0] = outEnc.r;
        dstStrided[si + 1] = outEnc.g;
        dstStrided[si + 2] = outEnc.b;
        dstStrided[si + 3] = alpha;
        return;
    }

    float3 combined = inputLin + glareRgb;
    float3 outEnc = working_to_host(combined, p);

    dstStrided[si + 0] = outEnc.r;
    dstStrided[si + 1] = outEnc.g;
    dstStrided[si + 2] = outEnc.b;
    dstStrided[si + 3] = alpha;
}