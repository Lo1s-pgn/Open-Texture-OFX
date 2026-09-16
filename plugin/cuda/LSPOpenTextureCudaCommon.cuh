#pragma once

#include <cuda_runtime.h>
#include <cmath>

struct OpenTextureCudaParams {
    float distribution;
    int inputTransferFunction;
    int workingTransferFunction;
    int showDistribution;
    int width;
    int height;
    int srcRowFloats;
    int dstRowFloats;
    float exposureLostLin;
    float greenExposureLostLin;
    float blueExposureLostLin;
    float invMatrix[9];
    float inputToDwg[9];
    float dwgToInput[9];
    float cieLumaCoeffs[3];
    int effectWindowEnabled;
    float effectWindowLeft;
    float effectWindowTop;
    float effectWindowWidth;
    float effectWindowHeight;
    int effectWindowShowBorder;
};

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

inline __device__ __host__ float otExp10(float x) {
    return exp2f(x * 3.3219280948873626f);
}

inline __device__ __host__ float otDecodeDavinciIntermediate(float e) {
    return e <= 0.02740668f ? e / 10.44426855f : exp2f(e / 0.07329248f - 7.0f) - 0.0075f;
}
inline __device__ __host__ float otDecodeFilmlightTlog(float e) {
    return e < 0.075f ? (e - 0.075f) / 16.184376489665897f
                      : expf((e - 0.5520126568606655f) / 0.09232902596577353f) - 0.0057048244042473785f;
}
inline __device__ __host__ float otDecodeAcescct(float e) {
    const float th = 0.155251141552511f;
    return e <= th ? (e - 0.0729055341958355f) / 10.5402377416545f : exp2f(e * 17.52f - 9.72f);
}
inline __device__ __host__ float otDecodeArriLogc3(float e) {
    return e < 5.367655f * 0.010591f + 0.092809f ? (e - 0.092809f) / 5.367655f
                                                 : (otExp10((e - 0.385537f) / 0.247190f) - 0.052272f) / 5.555556f;
}
inline __device__ __host__ float otDecodeArriLogc4(float e) {
    return e < -0.7774983977293537f ? e * 0.3033266726886969f - 0.7774983977293537f
                                    : (exp2f(14.0f * (e - 0.09286412512218964f) / 0.9071358748778103f + 6.0f) - 64.0f) /
                                          2231.8263090676883f;
}
inline __device__ __host__ float otDecodeRedLog3g10(float e) {
    return e < 0.0f ? (e / 15.1927f) - 0.01f : (otExp10(e / 0.224282f) - 1.0f) / 155.975327f - 0.01f;
}
inline __device__ __host__ float otDecodePanasonicVlog(float e) {
    return e < 0.181f ? (e - 0.125f) / 5.6f : otExp10((e - 0.598206f) / 0.241514f) - 0.00873f;
}
inline __device__ __host__ float otDecodeSonySlog3(float e) {
    const float k1 = 171.2102946929f / 1023.0f;
    return e < k1 ? (e * 1023.0f - 95.0f) * 0.01125f / (171.2102946929f - 95.0f)
                  : (otExp10(((e * 1023.0f - 420.0f) / 261.5f)) * (0.18f + 0.01f) - 0.01f);
}
inline __device__ __host__ float otDecodeFujifilmFlog2(float e) {
    return e < 0.100686685370811f ? (e - 0.092864f) / 8.799461f
                                  : (otExp10((e - 0.384316f) / 0.245281f) / 5.555556f - 0.064829f / 5.555556f);
}

inline __device__ __host__ float otEncodeFilmlightTlog(float l) {
    const float k = 16.184376489665897f;
    const float cutE = 0.075f;
    const float B = 0.5520126568606655f;
    const float A = 0.09232902596577353f;
    const float c = 0.0057048244042473785f;
    if (l <= 0.0f)
        return cutE + k * l;
    return B + A * logf(fmaxf(l + c, 1e-30f));
}
inline __device__ __host__ float otEncodeDavinciIntermediate(float lin) {
    const float DI_A = 0.0075f, DI_B = 7.0f, DI_C = 0.07329248f, DI_M = 10.44426855f, DI_LIN_CUT = 0.00262409f;
    return lin > DI_LIN_CUT ? (log2f(lin + DI_A) + DI_B) * DI_C : lin * DI_M;
}
inline __device__ __host__ float otEncodeArriLogc3(float lin) {
    return lin > 0.010591f ? 0.24719f * log10f(5.555556f * lin + 0.052272f) + 0.385537f : 5.367655f * lin + 0.092809f;
}
inline __device__ __host__ float otEncodeAcescct(float rgb) {
    return rgb > 0.0078125f ? (logf(rgb) / logf(2.0f) + 9.72f) / 17.52f : 10.5402377416545f * rgb + 0.0729055341958355f;
}
inline __device__ __host__ float otEncodeArriLogc4(float l) {
    const float eSplit = -0.7774983977293537f, m = 0.3033266726886969f, offs = 0.7774983977293537f;
    const float eLin = (l + offs) / m;
    if (eLin < eSplit - 1.0e-6f)
        return eLin;
    const float e0 = 0.09286412512218964f, d = 0.9071358748778103f, big = 2231.8263090676883f;
    return e0 + d * ((log2f(fmaxf(l * big + 64.0f, 1e-30f)) - 6.0f) / 14.0f);
}
inline __device__ __host__ float otEncodeRedLog3g10(float l) {
    const float kk = 0.224282f, mm = 155.975327f;
    if (l <= -0.01f)
        return (l + 0.01f) * 15.1927f;
    return kk * log10f(fmaxf((l + 0.01f) * mm + 1.0f, 1e-30f));
}
inline __device__ __host__ float otEncodePanasonicVlog(float l) {
    const float cutL = (0.181f - 0.125f) / 5.6f;
    if (l <= cutL)
        return l * 5.6f + 0.125f;
    return 0.598206f + 0.241514f * log10f(fmaxf(l + 0.00873f, 1e-30f));
}
inline __device__ __host__ float otEncodeSonySlog3(float l) {
    const float threshE = 171.2102946929f / 1023.0f;
    const float Lj = otDecodeSonySlog3(threshE - 1.0e-7f);
    if (l <= Lj)
        return ((l / 0.01125f * (171.2102946929f - 95.0f)) + 95.0f) / 1023.0f;
    return (261.5f * log10f(fmaxf((l + 0.01f) / 0.19f, 1e-30f)) + 420.0f) / 1023.0f;
}
inline __device__ __host__ float otEncodeFujifilmFlog2(float l) {
    const float eCut = 0.100686685370811f, kF = 8.799461f, e0 = 0.092864f;
    const float Lcut = (eCut - e0) / kF;
    if (l <= Lcut)
        return l * kF + e0;
    const float c = 0.064829f / 5.555556f;
    return 0.384316f + 0.245281f * log10f(fmaxf((l + c) * 5.555556f, 1e-30f));
}

inline __device__ __host__ int otClampTf(int tf) {
    return tf < 0 ? 0 : (tf > 9 ? 9 : tf);
}

inline __device__ __host__ float otDecodeChan(float enc, int tf) {
    if (tf == 0)
        return enc;
    if (tf == 1)
        return otDecodeDavinciIntermediate(enc);
    if (tf == 2)
        return otDecodeFilmlightTlog(enc);
    if (tf == 3)
        return otDecodeAcescct(enc);
    if (tf == 4)
        return otDecodeArriLogc3(enc);
    if (tf == 5)
        return otDecodeArriLogc4(enc);
    if (tf == 6)
        return otDecodeRedLog3g10(enc);
    if (tf == 7)
        return otDecodePanasonicVlog(enc);
    if (tf == 8)
        return otDecodeSonySlog3(enc);
    if (tf == 9)
        return otDecodeFujifilmFlog2(enc);
    return enc;
}

inline __device__ __host__ float otEncodeChan(float lin, int tf) {
    if (tf == 0)
        return lin;
    if (tf == 1)
        return otEncodeDavinciIntermediate(lin);
    if (tf == 2)
        return otEncodeFilmlightTlog(lin);
    if (tf == 3)
        return otEncodeAcescct(lin);
    if (tf == 4)
        return otEncodeArriLogc3(lin);
    if (tf == 5)
        return otEncodeArriLogc4(lin);
    if (tf == 6)
        return otEncodeRedLog3g10(lin);
    if (tf == 7)
        return otEncodePanasonicVlog(lin);
    if (tf == 8)
        return otEncodeSonySlog3(lin);
    if (tf == 9)
        return otEncodeFujifilmFlog2(lin);
    return lin;
}

inline __device__ __host__ float otWhitepointForTf(int tf) {
    tf = otClampTf(tf);
    if (tf == 0)
        return 1.0f;
    if (tf == 1)
        return 100.0f;
    if (tf == 2 || tf == 5 || tf == 6 || tf == 7 || tf == 8 || tf == 9)
        return 100.0f;
    if (tf == 3)
        return 222.86f;
    if (tf == 4)
        return 55.08f;
    return 100.0f;
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
