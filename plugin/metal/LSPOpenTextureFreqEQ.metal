#include <metal_stdlib>
using namespace metal;
#include "LSPOpenTextureMetalCommon.metal"

constant float kMaxLinearRgb = 65504.0f;
constant float kLabThresh = 0.008856f;
constant float kLabThreshInv = 0.206893f;
constant float kLab7787 = 7.787f;
constant float kLab16_116 = 0.137931034f;

// MTF lab treats working rgb as rec709; no gamut convert (paul dore / baldavenger path)
constant float kLabXn = 0.412453f + 0.357580f + 0.180423f;
constant float kLabYn = 0.212671f + 0.715160f + 0.072169f;
constant float kLabZn = 0.019334f + 0.119193f + 0.950227f;

inline float labf(float x) {
    return (x >= kLabThresh) ? pow(x, 1.0f / 3.0f) : (kLab7787 * x + kLab16_116);
}

inline float labfi(float x) {
    return (x >= kLabThreshInv) ? (x * x * x) : ((x - kLab16_116) / kLab7787);
}

inline float3 rgbToXyz709(float3 c) {
    return float3(0.4124564f * c.r + 0.3575761f * c.g + 0.1804375f * c.b,
                  0.2126729f * c.r + 0.7151522f * c.g + 0.0721750f * c.b,
                  0.0193339f * c.r + 0.1191920f * c.g + 0.9503041f * c.b);
}

inline float3 xyzToRgb709(float3 xyz) {
    return float3(3.2404542f * xyz.x + -1.5371385f * xyz.y + -0.4985314f * xyz.z,
                  -0.9692660f * xyz.x + 1.8760108f * xyz.y + 0.0415560f * xyz.z,
                  0.0556434f * xyz.x + -0.2040259f * xyz.y + 1.0572252f * xyz.z);
}

inline float rgbToLabL709(float3 c) {
    float yy = rgbToXyz709(c).y;
    float fy = labf(yy / kLabYn);
    float l = (116.0f * fy - 16.0f) * 0.01f;
    return isfinite(l) ? l : 0.0f;
}

kernel void k_decode_strided_rgb_to_l_tex(device const float* srcStrided [[buffer(0)]],
                                          texture2d<float, access::write> rgbLin [[texture(0)]],
                                          texture2d<float, access::write> lSource [[texture(1)]],
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
    float l = rgbToLabL709(c);
    lSource.write(float4(l, 0.0f, 0.0f, 1.0f), gid);
}

inline float presplitBandDetail(float lOrig, float b0, float b1, float b2, float b3, float b4, float b5, int band) {
    if (band == 0)
        return lOrig - b0;
    if (band == 1)
        return b0 - b1;
    if (band == 2)
        return b1 - b2;
    if (band == 3)
        return b2 - b3;
    if (band == 4)
        return b3 - b4;
    return b4 - b5;
}

inline float presplitWeightedDetail(float lOrig, float b0, float b1, float b2, float b3, float b4, float b5,
                                    constant float* eq) {
    float acc = 0.0f;
    acc += eq[0] * (lOrig - b0);
    acc += eq[1] * (b0 - b1);
    acc += eq[2] * (b1 - b2);
    acc += eq[3] * (b2 - b3);
    acc += eq[4] * (b3 - b4);
    acc += eq[5] * (b4 - b5);
    return acc;
}

kernel void k_presplit_accum_detail_tex(texture2d<float, access::read> lOrig [[texture(0)]],
                                        texture2d<float, access::read> blur0 [[texture(1)]],
                                        texture2d<float, access::read> blur1 [[texture(2)]],
                                        texture2d<float, access::read> blur2 [[texture(3)]],
                                        texture2d<float, access::read> blur3 [[texture(4)]],
                                        texture2d<float, access::read> blur4 [[texture(5)]],
                                        texture2d<float, access::read> blur5 [[texture(6)]],
                                        texture2d<float, access::write> acc [[texture(7)]],
                                        constant int& width [[buffer(2)]],
                                        constant int& height [[buffer(3)]],
                                        constant float* eq [[buffer(4)]],
                                        uint2 gid [[thread_position_in_grid]]) {
    if ((int)gid.x >= width || (int)gid.y >= height)
        return;
    float l = lOrig.read(gid).r;
    float b0 = blur0.read(gid).r;
    float b1 = blur1.read(gid).r;
    float b2 = blur2.read(gid).r;
    float b3 = blur3.read(gid).r;
    float b4 = blur4.read(gid).r;
    float b5 = blur5.read(gid).r;
    float a = presplitWeightedDetail(l, b0, b1, b2, b3, b4, b5, eq);
    acc.write(float4(a, 0.0f, 0.0f, 1.0f), gid);
}

kernel void k_presplit_fused_strided_tex(texture2d<float, access::read> lOrig [[texture(0)]],
                                         texture2d<float, access::read> blur0 [[texture(1)]],
                                         texture2d<float, access::read> blur1 [[texture(2)]],
                                         texture2d<float, access::read> blur2 [[texture(3)]],
                                         texture2d<float, access::read> blur3 [[texture(4)]],
                                         texture2d<float, access::read> blur4 [[texture(5)]],
                                         texture2d<float, access::read> blur5 [[texture(6)]],
                                         texture2d<float, access::read> rgbLin [[texture(7)]],
                                         device float* dstStrided [[buffer(0)]],
                                         constant OpenTextureMetalParams& p [[buffer(1)]],
                                         constant float* eq [[buffer(2)]],
                                         constant float& blendTowardOriginal [[buffer(3)]],
                                         constant float& lumaBlend [[buffer(4)]],
                                         uint2 gid [[thread_position_in_grid]]) {
    if ((int)gid.x >= p.width || (int)gid.y >= p.height)
        return;
    float lNorm0 = lOrig.read(gid).r;
    float b0 = blur0.read(gid).r;
    float b1 = blur1.read(gid).r;
    float b2 = blur2.read(gid).r;
    float b3 = blur3.read(gid).r;
    float b4 = blur4.read(gid).r;
    float b5 = blur5.read(gid).r;
    float lNorm1 = b5 + presplitWeightedDetail(lNorm0, b0, b1, b2, b3, b4, b5, eq);

    float4 px = rgbLin.read(gid);
    float3 xyz = rgbToXyz709(px.rgb);
    float fx = labf(xyz.x / kLabXn);
    float fy = labf(xyz.y / kLabYn);
    float fz = labf(xyz.z / kLabZn);
    float a = 500.0f * (fx - fy);
    float b = 200.0f * (fy - fz);
    float l0 = lNorm0 * 100.0f;
    float l1 = lNorm1 * 100.0f;
    if (!isfinite(l0))
        l0 = 116.0f * fy - 16.0f;
    if (!isfinite(l1))
        l1 = l0;
    float t = clamp(blendTowardOriginal, 0.0f, 1.0f);
    float l = l1 * (1.0f - t) + l0 * t;
    if (!isfinite(l))
        l = l0;

    float cy = (l + 16.0f) / 116.0f;
    float cx = a / 500.0f + cy;
    float cz = cy - b / 200.0f;
    float3 xyzLab = float3(kLabXn * labfi(cx), kLabYn * labfi(cy), kLabZn * labfi(cz));
    float3 rgbLab = xyzToRgb709(xyzLab);

    // lumaBlend 0 = scale rec709 Y only; 1 = full lab reconstruct (defualt path in ui)
    float lb = clamp(lumaBlend, 0.0f, 1.0f);
    float y1 = kLabYn * labfi(cy);
    float yAbs = fabs(xyz.y);
    float yScale = (yAbs > 1.0e-6f) ? (y1 / xyz.y) : 1.0f;
    yScale = mix(1.0f, yScale, smoothstep(0.0f, 1.0e-4f, yAbs));
    float3 rgbXy = px.rgb * yScale;
    float3 o = mix(rgbXy, rgbLab, lb);
    o = min(o, float3(kMaxLinearRgb));
    if (!isfinite(o.x) || !isfinite(o.y) || !isfinite(o.z))
        o = px.rgb;
    float3 outEnc = working_to_host(o, p);
    int so = (int)gid.y * p.dstRowFloats + (int)gid.x * 4;
    dstStrided[so + 0] = sanitizeFinite(outEnc.r, 0.0f);
    dstStrided[so + 1] = sanitizeFinite(outEnc.g, 0.0f);
    dstStrided[so + 2] = sanitizeFinite(outEnc.b, 0.0f);
    dstStrided[so + 3] = px.a;
}

kernel void k_preview_band_presplit_strided(texture2d<float, access::read> lOrig [[texture(0)]],
                                            texture2d<float, access::read> blur0 [[texture(1)]],
                                            texture2d<float, access::read> blur1 [[texture(2)]],
                                            texture2d<float, access::read> blur2 [[texture(3)]],
                                            texture2d<float, access::read> blur3 [[texture(4)]],
                                            texture2d<float, access::read> blur4 [[texture(5)]],
                                            texture2d<float, access::read> blur5 [[texture(6)]],
                                            device float* dstStrided [[buffer(0)]],
                                            constant OpenTextureMetalParams& p [[buffer(1)]],
                                            constant float& eq [[buffer(2)]],
                                            constant int& band [[buffer(3)]],
                                            constant int& greyBG [[buffer(4)]],
                                            uint2 gid [[thread_position_in_grid]]) {
    if ((int)gid.x >= p.width || (int)gid.y >= p.height)
        return;
    float l = lOrig.read(gid).r;
    float b0 = blur0.read(gid).r;
    float b1 = blur1.read(gid).r;
    float b2 = blur2.read(gid).r;
    float b3 = blur3.read(gid).r;
    float b4 = blur4.read(gid).r;
    float b5 = blur5.read(gid).r;
    float d = eq * presplitBandDetail(l, b0, b1, b2, b3, b4, b5, band);
    float base = (greyBG != 0) ? 0.5f : 0.0f;
    float enc = d + base;
    int so = (int)gid.y * p.dstRowFloats + (int)gid.x * 4;
    dstStrided[so + 0] = enc;
    dstStrided[so + 1] = enc;
    dstStrided[so + 2] = enc;
    dstStrided[so + 3] = 1.0f;
}

kernel void k_preview_accum_strided(texture2d<float, access::read> acc [[texture(0)]],
                                    device float* dstStrided [[buffer(0)]],
                                    constant OpenTextureMetalParams& p [[buffer(1)]],
                                    constant int& greyBG [[buffer(2)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    if ((int)gid.x >= p.width || (int)gid.y >= p.height)
        return;
    float a = acc.read(gid).r;
    float base = (greyBG != 0) ? 0.5f : 0.0f;
    float enc = a + base;
    int so = (int)gid.y * p.dstRowFloats + (int)gid.x * 4;
    dstStrided[so + 0] = enc;
    dstStrided[so + 1] = enc;
    dstStrided[so + 2] = enc;
    dstStrided[so + 3] = 1.0f;
}
