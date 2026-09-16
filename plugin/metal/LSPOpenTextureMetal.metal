#include <metal_stdlib>
using namespace metal;
#include "LSPOpenTextureMetalCommon.metal"

inline float highlight_distribution_blur_scale(float sceneLuma, float gamma, float whitepoint) {
    if (gamma >= 1.0f - 1.0e-5f)
        return 1.0f;
    if (sceneLuma <= 1.0e-6f)
        return 1.0f;
    const float yShaped = applyGamma(sceneLuma, gamma, whitepoint);
    return yShaped / sceneLuma;
}

inline float3 scale_linear_for_blur_distribution(float3 lin, float gamma, float whitepoint, constant float* cieLumaCoeffs) {
    const float y = cie_y(lin, cieLumaCoeffs);
    const float scale = highlight_distribution_blur_scale(y, gamma, whitepoint);
    return make3(lin.r * scale, lin.g * scale, lin.b * scale);
}

inline float3 apply_redshift_inv_with_distribution(float3 halLin, float e, float g, float b, float dr) {
    const float scale = dr > 1.0e-6f ? dr : 1.0f;
    const float a = 1.0f + e * scale;
    const float invA = 1.0f / fmax(a, 1.0e-6f);
    const float c = e * g * scale;
    const float d = e * g * b * scale;
    return make3(
        halLin.r * invA,
        halLin.g - c * invA * halLin.r,
        halLin.b - d * invA * halLin.r);
}

inline float3 composeTfHalation(float3 inRgb, float3 blurredLinDwg, constant OpenTextureMetalParams& p) {
    float3 rgbLinDwg = host_to_working(inRgb, p);
    const float diffusedR = blurredLinDwg.r;
    const float e = p.exposureLostLin;
    const float g = p.greenExposureLostLin;
    const float b = p.blueExposureLostLin;
    float3 halLin = make3(
        rgbLinDwg.r + diffusedR * e,
        rgbLinDwg.g + diffusedR * e * g,
        rgbLinDwg.b + diffusedR * e * g * b);
    const float gamma = clampf(p.distribution, 0.6f, 1.0f);
    const float wp = whitepoint_for_tf(p.workingTransferFunction);
    const float dr = highlight_distribution_blur_scale(cie_y(rgbLinDwg, p.cieLumaCoeffs), gamma, wp);
    float3 corrected = apply_redshift_inv_with_distribution(halLin, e, g, b, dr);
    if (p.showDistribution != 0) {
        float3 delta = make3(
            fmax(corrected.r - rgbLinDwg.r, 0.0f),
            fmax(corrected.g - rgbLinDwg.g, 0.0f),
            fmax(corrected.b - rgbLinDwg.b, 0.0f));
        return working_to_host(delta, p);
    }
    return working_to_host(corrected, p);
}

kernel void LSPOpenTexturePreprocessTextureKernel(device const float* src [[buffer(0)]],
                                                  texture2d<float, access::write> pre [[texture(0)]],
                                                  constant OpenTextureMetalParams& p [[buffer(2)]],
                                                  uint2 gid [[thread_position_in_grid]]) {
    int x = (int)gid.x, y = (int)gid.y;
    if (x >= p.width || y >= p.height)
        return;
    int iSrc = y * p.srcRowFloats + x * 4;
    float3 inRgb = make3(sanitizeFinite(src[iSrc + 0], 0.0f), sanitizeFinite(src[iSrc + 1], 0.0f), sanitizeFinite(src[iSrc + 2], 0.0f));
    const float gamma = clampf(p.distribution, 0.6f, 1.0f);
    const float wp = whitepoint_for_tf(p.workingTransferFunction);
    float3 lin = host_to_working(inRgb, p);
    lin = scale_linear_for_blur_distribution(lin, gamma, wp, p.cieLumaCoeffs);
    pre.write(float4(lin, 1.0f), gid);
}

kernel void LSPOpenTextureCompositeTextureKernel(device const float* src [[buffer(0)]], texture2d<float, access::read> blurredTex [[texture(0)]], device float* dst [[buffer(2)]], constant OpenTextureMetalParams& p [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
    int x = (int)gid.x, y = (int)gid.y; if (x >= p.width || y >= p.height) return;
    int iSrc = y * p.srcRowFloats + x * 4; int iDst = y * p.dstRowFloats + x * 4;
    float3 inRgb = make3(sanitizeFinite(src[iSrc + 0], 0.0f), sanitizeFinite(src[iSrc + 1], 0.0f), sanitizeFinite(src[iSrc + 2], 0.0f));
    float srcA = sanitizeFinite(src[iSrc + 3], 1.0f);
    float4 blurPx = blurredTex.read(gid);
    float3 blurRgb = make3(sanitizeFinite(blurPx.r, 0.0f), sanitizeFinite(blurPx.g, 0.0f), sanitizeFinite(blurPx.b, 0.0f));
    float3 outRgb = composeTfHalation(inRgb, blurRgb, p);
    dst[iDst + 0] = sanitizeFinite(outRgb.r, inRgb.r); dst[iDst + 1] = sanitizeFinite(outRgb.g, inRgb.g); dst[iDst + 2] = sanitizeFinite(outRgb.b, inRgb.b); dst[iDst + 3] = srcA;
}

kernel void LSPOpenTextureRegionCopyKernel(device const float* src [[buffer(0)]], device float* dst [[buffer(1)]], constant OpenTextureMetalParams& p [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
    int x = (int)gid.x;
    int y = (int)gid.y;
    if (x >= p.width || y >= p.height)
        return;
    int si = y * p.srcRowFloats + x * 4;
    int di = y * p.dstRowFloats + x * 4;
    dst[di + 0] = sanitizeFinite(src[si + 0], 0.0f);
    dst[di + 1] = sanitizeFinite(src[si + 1], 0.0f);
    dst[di + 2] = sanitizeFinite(src[si + 2], 0.0f);
    dst[di + 3] = sanitizeFinite(src[si + 3], 1.0f);
}

kernel void LSPOpenTextureGlobalBlendKernel(device const float* src [[buffer(0)]], device float* dst [[buffer(1)]], constant OpenTextureMetalParams& p [[buffer(2)]], constant float& mixEffect [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
    int x = (int)gid.x;
    int y = (int)gid.y;
    if (x >= p.width || y >= p.height)
        return;
    int si = y * p.srcRowFloats + x * 4;
    int di = y * p.dstRowFloats + x * 4;
    float g = clampf(mixEffect, 0.0f, 1.0f);
    float om = 1.0f - g;
    if (p.showDistribution != 0) {
        for (int c = 0; c < 3; c++) {
            float d = sanitizeFinite(dst[di + c], 0.0f);
            dst[di + c] = g * d;
        }
        float sA = sanitizeFinite(src[si + 3], 1.0f);
        dst[di + 3] = sA;
        return;
    }
    for (int c = 0; c < 4; c++) {
        float s = sanitizeFinite(src[si + c], c == 3 ? 1.0f : 0.0f);
        float d = sanitizeFinite(dst[di + c], s);
        dst[di + c] = om * s + g * d;
    }
}

kernel void LSPOpenTextureEffectWindowEdgeReplicateTextureKernel(texture2d<float, access::read_write> tex [[texture(0)]],
                                                                 constant OpenTextureMetalParams& p [[buffer(0)]],
                                                                 uint2 gid [[thread_position_in_grid]]) {
    int x = (int)gid.x;
    int y = (int)gid.y;
    if (x >= p.width || y >= p.height)
        return;
    if (p.effectWindowEnabled == 0 || halationInEffectWindow(x, y, p))
        return;
    int x1 = (int)floor(p.effectWindowLeft);
    int y1 = (int)floor(p.effectWindowTop);
    int x2 = (int)ceil(p.effectWindowLeft + p.effectWindowWidth);
    int y2 = (int)ceil(p.effectWindowTop + p.effectWindowHeight);
    x2 = max(x1 + 1, min(x2, p.width));
    y2 = max(y1 + 1, min(y2, p.height));
    int cx = halationClampWindowCoord(x, x1, x2);
    int cy = halationClampWindowCoord(y, y1, y2);
    float4 px = tex.read(uint2(cx, cy));
    tex.write(px, gid);
}

kernel void LSPOpenTextureEffectWindowEdgeReplicateStridedKernel(device float* buf [[buffer(0)]], constant OpenTextureMetalParams& p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    int x = (int)gid.x;
    int y = (int)gid.y;
    if (x >= p.width || y >= p.height)
        return;
    if (p.effectWindowEnabled == 0 || halationInEffectWindow(x, y, p))
        return;
    int x1 = (int)floor(p.effectWindowLeft);
    int y1 = (int)floor(p.effectWindowTop);
    int x2 = (int)ceil(p.effectWindowLeft + p.effectWindowWidth);
    int y2 = (int)ceil(p.effectWindowTop + p.effectWindowHeight);
    x2 = max(x1 + 1, min(x2, p.width));
    y2 = max(y1 + 1, min(y2, p.height));
    int cx = halationClampWindowCoord(x, x1, x2);
    int cy = halationClampWindowCoord(y, y1, y2);
    int di = y * p.dstRowFloats + x * 4;
    int si = cy * p.dstRowFloats + cx * 4;
    buf[di + 0] = buf[si + 0];
    buf[di + 1] = buf[si + 1];
    buf[di + 2] = buf[si + 2];
    buf[di + 3] = buf[si + 3];
}

kernel void LSPOpenTextureEffectWindowBlackMaskKernel(device float* dst [[buffer(0)]], constant OpenTextureMetalParams& p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    int x = (int)gid.x;
    int y = (int)gid.y;
    if (x >= p.width || y >= p.height)
        return;
    if (p.effectWindowEnabled == 0 || halationInEffectWindow(x, y, p))
        return;
    int di = y * p.dstRowFloats + x * 4;
    dst[di + 0] = 0.0f;
    dst[di + 1] = 0.0f;
    dst[di + 2] = 0.0f;
}

inline bool halationEffectWindowPixelOnBorder(int x, int y, constant OpenTextureMetalParams& p, float borderWidth) {
    float fx = (float)x;
    float fy = (float)y;
    float ol = p.effectWindowLeft;
    float ot = p.effectWindowTop;
    float ow = p.effectWindowWidth;
    float oh = p.effectWindowHeight;
    float bw = borderWidth;
    float winRight = ol + ow;
    float winBottom = ot + oh;
    if (fx >= ol && fx < winRight && fy >= ot && fy < winBottom)
        return false;
    return (fx >= ol - bw && fx < ol && fy >= ot && fy < winBottom) ||
           (fx >= winRight && fx < winRight + bw && fy >= ot && fy < winBottom) ||
           (fy >= ot - bw && fy < ot && fx >= ol && fx < winRight) ||
           (fy >= winBottom && fy < winBottom + bw && fx >= ol && fx < winRight);
}

kernel void LSPOpenTextureEffectWindowBorderKernel(device float* dst [[buffer(0)]], constant OpenTextureMetalParams& p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    int x = (int)gid.x;
    int y = (int)gid.y;
    if (x >= p.width || y >= p.height)
        return;
    if (p.effectWindowEnabled == 0 || p.effectWindowShowBorder == 0)
        return;
    if (!halationEffectWindowPixelOnBorder(x, y, p, 4.0f))
        return;
    int di = y * p.dstRowFloats + x * 4;
    dst[di + 0] = 0.5f;
    dst[di + 1] = 0.0f;
    dst[di + 2] = 0.0f;
}
