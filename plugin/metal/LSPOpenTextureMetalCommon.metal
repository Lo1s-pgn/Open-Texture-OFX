#include <metal_stdlib>
using namespace metal;

struct OpenTextureMetalParams {
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

inline bool halationInEffectWindow(int x, int y, constant OpenTextureMetalParams& p) {
    if (p.effectWindowEnabled == 0)
        return true;
    float xf = (float)x;
    float yf = (float)y;
    return xf >= p.effectWindowLeft && xf < p.effectWindowLeft + p.effectWindowWidth &&
           yf >= p.effectWindowTop && yf < p.effectWindowTop + p.effectWindowHeight;
}

inline int halationClampWindowCoord(int v, int lo, int hi) {
    if (hi <= lo)
        return lo;
    if (v < lo)
        return lo;
    if (v >= hi)
        return hi - 1;
    return v;
}

inline float clampf(float v, float mn, float mx) { return fmin(fmax(v, mn), mx); }
inline float sanitizeFinite(float v, float fb) { return isfinite(v) ? v : fb; }
inline float3 make3(float r, float g, float b) { return float3(r, g, b); }
inline float safePow(float b, float e) { return b <= 0.0f ? 0.0f : pow(b, e); }

inline float exp10_compat(float x) { return exp2(x * 3.3219280948873626f); }

inline float decode_davinci_intermediate(float e) {
    return e <= 0.02740668f ? e / 10.44426855f : exp2(e / 0.07329248f - 7.0f) - 0.0075f;
}
inline float decode_filmlight_tlog(float e) {
    return e < 0.075f ? (e - 0.075f) / 16.184376489665897f : exp((e - 0.5520126568606655f) / 0.09232902596577353f) - 0.0057048244042473785f;
}
inline float decode_acescct(float e) {
    float th = 0.155251141552511f;
    return e <= th ? (e - 0.0729055341958355f) / 10.5402377416545f : exp2(e * 17.52f - 9.72f);
}
inline float decode_arri_logc3(float e) {
    return e < 5.367655f * 0.010591f + 0.092809f ? (e - 0.092809f) / 5.367655f :
                                                    (exp10_compat((e - 0.385537f) / 0.247190f) - 0.052272f) / 5.555556f;
}
inline float decode_arri_logc4(float e) {
    return e < -0.7774983977293537f ? e * 0.3033266726886969f - 0.7774983977293537f :
                                      (exp2(14.0f * (e - 0.09286412512218964f) / 0.9071358748778103f + 6.0f) - 64.0f) /
                                          2231.8263090676883f;
}
inline float decode_red_log3g10(float e) {
    return e < 0.0f ? (e / 15.1927f) - 0.01f : (exp10_compat(e / 0.224282f) - 1.0f) / 155.975327f - 0.01f;
}
inline float decode_panasonic_vlog(float e) {
    return e < 0.181f ? (e - 0.125f) / 5.6f : exp10_compat((e - 0.598206f) / 0.241514f) - 0.00873f;
}
inline float decode_sony_slog3(float e) {
    float k1 = 171.2102946929f / 1023.0f;
    return e < k1 ? (e * 1023.0f - 95.0f) * 0.01125f / (171.2102946929f - 95.0f) :
                    (exp10_compat(((e * 1023.0f - 420.0f) / 261.5f)) * (0.18f + 0.01f) - 0.01f);
}
inline float decode_fujifilm_flog2(float e) {
    return e < 0.100686685370811f ? (e - 0.092864f) / 8.799461f :
                                    (exp10_compat((e - 0.384316f) / 0.245281f) / 5.555556f - 0.064829f / 5.555556f);
}

inline float encode_filmlight_tlog(float l) {
    float k = 16.184376489665897f;
    float cutE = 0.075f;
    float B = 0.5520126568606655f;
    float A = 0.09232902596577353f;
    float c = 0.0057048244042473785f;
    if (l <= 0.0f) return cutE + k * l;
    return B + A * log(fmax(l + c, 1e-30f));
}
inline float encode_davinci_intermediate(float lin) {
    float DI_A = 0.0075f, DI_B = 7.0f, DI_C = 0.07329248f, DI_M = 10.44426855f, DI_LIN_CUT = 0.00262409f;
    return lin > DI_LIN_CUT ? (log2(lin + DI_A) + DI_B) * DI_C : lin * DI_M;
}
inline float encode_arri_logc3(float lin) {
    return lin > 0.010591f ? 0.24719f * log10(5.555556f * lin + 0.052272f) + 0.385537f : 5.367655f * lin + 0.092809f;
}
inline float encode_acescct(float rgb) {
    return rgb > 0.0078125f ? (log(rgb) / log(2.0f) + 9.72f) / 17.52f : 10.5402377416545f * rgb + 0.0729055341958355f;
}
inline float encode_arri_logc4(float l) {
    float eSplit = -0.7774983977293537f, m = 0.3033266726886969f, offs = 0.7774983977293537f;
    float eLin = (l + offs) / m;
    if (eLin < eSplit - 1.0e-6f) return eLin;
    float e0 = 0.09286412512218964f, d = 0.9071358748778103f, big = 2231.8263090676883f;
    return e0 + d * ((log2(fmax(l * big + 64.0f, 1e-30f)) - 6.0f) / 14.0f);
}
inline float encode_red_log3g10(float l) {
    float kk = 0.224282f, mm = 155.975327f;
    if (l <= -0.01f) return (l + 0.01f) * 15.1927f;
    return kk * log10(fmax((l + 0.01f) * mm + 1.0f, 1e-30f));
}
inline float encode_panasonic_vlog(float l) {
    float cutL = (0.181f - 0.125f) / 5.6f;
    if (l <= cutL) return l * 5.6f + 0.125f;
    return 0.598206f + 0.241514f * log10(fmax(l + 0.00873f, 1e-30f));
}
inline float encode_sony_slog3(float l) {
    float threshE = 171.2102946929f / 1023.0f;
    float Lj = decode_sony_slog3(threshE - 1.0e-7f);
    if (l <= Lj)
        return ((l / 0.01125f * (171.2102946929f - 95.0f)) + 95.0f) / 1023.0f;
    return (261.5f * log10(fmax((l + 0.01f) / 0.19f, 1e-30f)) + 420.0f) / 1023.0f;
}
inline float encode_fujifilm_flog2(float l) {
    float eCut = 0.100686685370811f, kF = 8.799461f, e0 = 0.092864f;
    float Lcut = (eCut - e0) / kF;
    if (l <= Lcut) return l * kF + e0;
    float c = 0.064829f / 5.555556f;
    return 0.384316f + 0.245281f * log10(fmax((l + c) * 5.555556f, 1e-30f));
}

inline float decode_chan(float enc, int tf) {
    if (tf == 0) return enc;
    if (tf == 1) return decode_davinci_intermediate(enc);
    if (tf == 2) return decode_filmlight_tlog(enc);
    if (tf == 3) return decode_acescct(enc);
    if (tf == 4) return decode_arri_logc3(enc);
    if (tf == 5) return decode_arri_logc4(enc);
    if (tf == 6) return decode_red_log3g10(enc);
    if (tf == 7) return decode_panasonic_vlog(enc);
    if (tf == 8) return decode_sony_slog3(enc);
    if (tf == 9) return decode_fujifilm_flog2(enc);
    return enc;
}
inline float encode_chan(float lin, int tf) {
    if (tf == 0) return lin;
    if (tf == 1) return encode_davinci_intermediate(lin);
    if (tf == 2) return encode_filmlight_tlog(lin);
    if (tf == 3) return encode_acescct(lin);
    if (tf == 4) return encode_arri_logc3(lin);
    if (tf == 5) return encode_arri_logc4(lin);
    if (tf == 6) return encode_red_log3g10(lin);
    if (tf == 7) return encode_panasonic_vlog(lin);
    if (tf == 8) return encode_sony_slog3(lin);
    if (tf == 9) return encode_fujifilm_flog2(lin);
    return lin;
}

inline int clamp_tf(int tf) { return tf < 0 ? 0 : (tf > 9 ? 9 : tf); }

inline float3 to_linear_by_transfer(float3 enc, int tf) {
    int t = clamp_tf(tf);
    float r = decode_chan(enc.x, t);
    float g = decode_chan(enc.y, t);
    float b = decode_chan(enc.z, t);
    return make3(r, g, b);
}
inline float3 from_linear_by_transfer(float3 lin, int tf) {
    int t = clamp_tf(tf);
    float r = encode_chan(lin.x, t);
    float g = encode_chan(lin.y, t);
    float b = encode_chan(lin.z, t);
    return make3(r, g, b);
}

inline float whitepoint_for_tf(int tf) {
    tf = clamp_tf(tf);
    if (tf == 0) return 1.0f;
    if (tf == 1) return 100.0f;
    if (tf == 2 || tf == 5 || tf == 6 || tf == 7 || tf == 8 || tf == 9) return 100.0f;
    if (tf == 3) return 222.86f;
    if (tf == 4) return 55.08f;
    return 100.0f;
}

inline float applyGamma(float value, float gamma, float whitepoint) {
    float v = value / whitepoint;
    if (v > 1e-6f) {
        float ga = safePow(v, 1.0f / gamma);
        float w = v * (1.0f - v) + ga * v;
        v = 0.75f * ga + 0.25f * w;
    }
    return v * whitepoint;
}

inline float3 mulMat33RowMajor(constant float* m, float3 v) {
    return make3(
        m[0] * v.r + m[1] * v.g + m[2] * v.b,
        m[3] * v.r + m[4] * v.g + m[5] * v.b,
        m[6] * v.r + m[7] * v.g + m[8] * v.b);
}

inline float cie_y(float3 lin, constant float* cieLumaCoeffs) {
    return cieLumaCoeffs[0] * lin.r + cieLumaCoeffs[1] * lin.g + cieLumaCoeffs[2] * lin.b;
}

inline float3 clamp_linear_nonneg(float3 lin) {
    return make3(fmax(lin.r, 0.0f), fmax(lin.g, 0.0f), fmax(lin.b, 0.0f));
}

inline float3 host_to_working(float3 enc, constant OpenTextureMetalParams& p) {
    float3 linIn = to_linear_by_transfer(enc, p.inputTransferFunction);
    return clamp_linear_nonneg(mulMat33RowMajor(p.inputToDwg, linIn));
}

inline float3 working_to_host(float3 linDwg, constant OpenTextureMetalParams& p) {
    float3 linIn = mulMat33RowMajor(p.dwgToInput, linDwg);
    return from_linear_by_transfer(linIn, p.inputTransferFunction);
}
