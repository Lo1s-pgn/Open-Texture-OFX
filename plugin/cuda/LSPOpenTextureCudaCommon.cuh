#pragma once

#include <cuda_runtime.h>
#include <cmath>

#include "../core/LSPOpenTextureHostParams.h"

using OpenTextureCudaParams = LSPOpenTextureHostParams;

#define OT_CUDA_CHECK(call)                                                                                            \
    do {                                                                                                               \
        const cudaError_t _ot_err = (call);                                                                            \
        if (_ot_err != cudaSuccess)                                                                                    \
            return _ot_err;                                                                                            \
    } while (0)

#define OT_CUDA_CHECK_VOID(call)                                                                                       \
    do {                                                                                                               \
        const cudaError_t _ot_err = (call);                                                                            \
        if (_ot_err != cudaSuccess)                                                                                    \
            return;                                                                                                    \
    } while (0)

#define OT_CUDA_CHECK_BOOL(call)                                                                                       \
    do {                                                                                                               \
        const cudaError_t _ot_err = (call);                                                                            \
        if (_ot_err != cudaSuccess)                                                                                    \
            return false;                                                                                              \
    } while (0)

inline __device__ __host__ float otClampf(float v, float mn, float mx) {
    return fminf(fmaxf(v, mn), mx);
}

inline __device__ __host__ float otSanitizeFinite(float v, float fb) {
    return isfinite(v) ? v : fb;
}

inline __device__ __host__ float otSafePow(float b, float e) {
    return b <= 0.0f ? 0.0f : powf(b, e);
}

#define OT_TF_FN inline __device__ __host__
#define exp2 exp2f
#define exp expf
#define log logf
#define log2 log2f
#define log10 log10f
#define fmax fmaxf
#define fmin fminf
#define pow powf
#include "../core/LSPOpenTextureTransfers.inc"
#undef pow
#undef fmin
#undef fmax
#undef log10
#undef log2
#undef log
#undef exp
#undef exp2
#undef OT_TF_FN

inline __device__ __host__ int otClampTf(int tf) {
    return tf < 0 ? 0 : (tf > 9 ? 9 : tf);
}

inline __device__ __host__ float otDecodeChan(float enc, int tf) {
    if (tf == 0)
        return enc;
    if (tf == 1)
        return decode_davinci_intermediate(enc);
    if (tf == 2)
        return decode_filmlight_tlog(enc);
    if (tf == 3)
        return decode_acescct(enc);
    if (tf == 4)
        return decode_arri_logc3(enc);
    if (tf == 5)
        return decode_arri_logc4(enc);
    if (tf == 6)
        return decode_red_log3g10(enc);
    if (tf == 7)
        return decode_panasonic_vlog(enc);
    if (tf == 8)
        return decode_sony_slog3(enc);
    if (tf == 9)
        return decode_fujifilm_flog2(enc);
    return enc;
}

inline __device__ __host__ float otEncodeChan(float lin, int tf) {
    if (tf == 0)
        return lin;
    if (tf == 1)
        return encode_davinci_intermediate(lin);
    if (tf == 2)
        return encode_filmlight_tlog(lin);
    if (tf == 3)
        return encode_acescct(lin);
    if (tf == 4)
        return encode_arri_logc3(lin);
    if (tf == 5)
        return encode_arri_logc4(lin);
    if (tf == 6)
        return encode_red_log3g10(lin);
    if (tf == 7)
        return encode_panasonic_vlog(lin);
    if (tf == 8)
        return encode_sony_slog3(lin);
    if (tf == 9)
        return encode_fujifilm_flog2(lin);
    return lin;
}

inline __device__ __host__ float otWhitepointForTf(int tf) {
    return whitepoint_for_transfer(otClampTf(tf));
}

inline __device__ __host__ float otApplyGamma(float value, float gamma, float whitepoint) {
    float v = value / whitepoint;
    if (v > 1e-6f) {
        const float ga = otSafePow(v, 1.0f / gamma);
        const float w = v * (1.0f - v) + ga * v;
        v = 0.75f * ga + 0.25f * w;
    }
    return v * whitepoint;
}

inline __device__ __host__ float3 otMulMat33RowMajor(const float* m, float3 v) {
    return make_float3(m[0] * v.x + m[1] * v.y + m[2] * v.z, m[3] * v.x + m[4] * v.y + m[5] * v.z,
                       m[6] * v.x + m[7] * v.y + m[8] * v.z);
}

inline __device__ __host__ float otCieY(float3 lin, const float* cieLumaCoeffs) {
    return cieLumaCoeffs[0] * lin.x + cieLumaCoeffs[1] * lin.y + cieLumaCoeffs[2] * lin.z;
}

inline __device__ __host__ float3 otClampLinearNonneg(float3 lin) {
    return make_float3(fmaxf(lin.x, 0.0f), fmaxf(lin.y, 0.0f), fmaxf(lin.z, 0.0f));
}

inline __device__ __host__ float3 otToLinearByTransfer(float3 enc, int tf) {
    const int t = otClampTf(tf);
    return make_float3(otDecodeChan(enc.x, t), otDecodeChan(enc.y, t), otDecodeChan(enc.z, t));
}

inline __device__ __host__ float3 otFromLinearByTransfer(float3 lin, int tf) {
    const int t = otClampTf(tf);
    return make_float3(otEncodeChan(lin.x, t), otEncodeChan(lin.y, t), otEncodeChan(lin.z, t));
}

inline __device__ __host__ float3 otHostToWorking(float3 enc, const OpenTextureCudaParams& p) {
    const float3 linIn = otToLinearByTransfer(enc, p.inputTransferFunction);
    return otClampLinearNonneg(otMulMat33RowMajor(p.inputToDwg, linIn));
}

inline __device__ __host__ float3 otWorkingToHost(float3 linDwg, const OpenTextureCudaParams& p) {
    const float3 linIn = otMulMat33RowMajor(p.dwgToInput, linDwg);
    return otFromLinearByTransfer(linIn, p.inputTransferFunction);
}

inline __device__ bool otHalationInEffectWindow(int x, int y, const OpenTextureCudaParams& p) {
    if (p.effectWindowEnabled == 0)
        return true;
    const float xf = static_cast<float>(x);
    const float yf = static_cast<float>(y);
    return xf >= p.effectWindowLeft && xf < p.effectWindowLeft + p.effectWindowWidth && yf >= p.effectWindowTop &&
           yf < p.effectWindowTop + p.effectWindowHeight;
}

inline __device__ int otHalationClampWindowCoord(int v, int lo, int hi) {
    if (hi <= lo)
        return lo;
    if (v < lo)
        return lo;
    if (v >= hi)
        return hi - 1;
    return v;
}

inline __device__ float otHighlightDistributionBlurScale(float sceneLuma, float gamma, float whitepoint) {
    if (gamma >= 1.0f - 1.0e-5f)
        return 1.0f;
    if (sceneLuma <= 1.0e-6f)
        return 1.0f;
    const float yShaped = otApplyGamma(sceneLuma, gamma, whitepoint);
    return yShaped / sceneLuma;
}

inline __device__ float3 otScaleLinearForBlurDistribution(float3 lin, float gamma, float whitepoint, const float* cieLumaCoeffs) {
    const float y = otCieY(lin, cieLumaCoeffs);
    const float scale = otHighlightDistributionBlurScale(y, gamma, whitepoint);
    return make_float3(lin.x * scale, lin.y * scale, lin.z * scale);
}

inline __device__ float3 otApplyRedshiftInvWithDistribution(float3 halLin, float e, float g, float b, float dr) {
    const float scale = dr > 1.0e-6f ? dr : 1.0f;
    const float a = 1.0f + e * scale;
    const float invA = 1.0f / fmaxf(a, 1.0e-6f);
    const float c = e * g * scale;
    const float d = e * g * b * scale;
    return make_float3(halLin.x * invA, halLin.y - c * invA * halLin.x, halLin.z - d * invA * halLin.x);
}

inline __device__ float3 otComposeTfHalation(float3 inRgb, float3 blurredLinDwg, const OpenTextureCudaParams& p) {
    const float3 rgbLinDwg = otHostToWorking(inRgb, p);
    const float diffusedR = blurredLinDwg.x;
    const float e = p.exposureLostLin;
    const float g = p.greenExposureLostLin;
    const float b = p.blueExposureLostLin;
    const float3 halLin =
        make_float3(rgbLinDwg.x + diffusedR * e, rgbLinDwg.y + diffusedR * e * g, rgbLinDwg.z + diffusedR * e * g * b);
    const float gamma = otClampf(p.distribution, 0.6f, 1.0f);
    const float wp = otWhitepointForTf(p.workingTransferFunction);
    const float dr = otHighlightDistributionBlurScale(otCieY(rgbLinDwg, p.cieLumaCoeffs), gamma, wp);
    const float3 corrected = otApplyRedshiftInvWithDistribution(halLin, e, g, b, dr);
    if (p.showDistribution != 0) {
        const float3 delta = make_float3(fmaxf(corrected.x - rgbLinDwg.x, 0.0f), fmaxf(corrected.y - rgbLinDwg.y, 0.0f),
                                         fmaxf(corrected.z - rgbLinDwg.z, 0.0f));
        return otWorkingToHost(delta, p);
    }
    return otWorkingToHost(corrected, p);
}

inline __device__ bool otHalationEffectWindowPixelOnBorder(int x, int y, const OpenTextureCudaParams& p, float borderWidth) {
    const float fx = static_cast<float>(x);
    const float fy = static_cast<float>(y);
    const float ol = p.effectWindowLeft;
    const float ot = p.effectWindowTop;
    const float ow = p.effectWindowWidth;
    const float oh = p.effectWindowHeight;
    const float bw = borderWidth;
    const float winRight = ol + ow;
    const float winBottom = ot + oh;
    if (fx >= ol && fx < winRight && fy >= ot && fy < winBottom)
        return false;
    return (fx >= ol - bw && fx < ol && fy >= ot && fy < winBottom) ||
           (fx >= winRight && fx < winRight + bw && fy >= ot && fy < winBottom) ||
           (fy >= ot - bw && fy < ot && fx >= ol && fx < winRight) ||
           (fy >= winBottom && fy < winBottom + bw && fx >= ol && fx < winRight);
}
