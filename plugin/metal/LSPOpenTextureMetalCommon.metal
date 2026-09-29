#include <metal_stdlib>
using namespace metal;

// Must match LSPOpenTextureHostParams field order (plugin/core).
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

#include "LSPOpenTextureTransfers.inc"

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
    return whitepoint_for_transfer(clamp_tf(tf));
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
