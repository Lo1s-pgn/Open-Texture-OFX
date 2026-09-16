#include "LSPOpenTextureTfMapping.h"

#include <cmath>

namespace LSPOpenTextureTfMapping {

namespace {

constexpr float kHueCoolGreen = -0.3f;
constexpr float kHueCoolBlue = -3.5f;
constexpr float kHueNeutral = -1.4f;
constexpr float kHueWarmGreen = -2.8f;
constexpr float kHueWarmBlue = -0.3f;

float clampStops(float stops) {
    if (stops < kStopMin)
        return kStopMin;
    if (stops > kStopMax)
        return kStopMax;
    return stops;
}

}

float clampf(float v, float mn, float mx) {
    if (v < mn)
        return mn;
    if (v > mx)
        return mx;
    return v;
}

float clampHue01(float hue) {
    return clampf(hue, 0.0f, 1.0f);
}

float clampSaturation(float saturation) {
    return clampf(saturation, 0.0f, kSaturationMax);
}

float clampIntensity(float intensity) {
    return clampf(intensity, 0.0f, 2.0f);
}

float intensityToExposureLostStops(float intensity) {
    const float t = clampIntensity(intensity);
    if (t <= 1.0f)
        return clampStops(-10.0f + t * 7.0f);
    return clampStops(-3.0f + (t - 1.0f) * 3.0f);
}

Stops hueToExposureStops(float hue01) {
    const float h = clampHue01(hue01);
    Stops s{};
    if (h <= 0.5f) {
        const float t = h * 2.0f;
        s.green = clampStops(kHueCoolGreen + (kHueNeutral - kHueCoolGreen) * t);
        s.blue = clampStops(kHueCoolBlue + (kHueNeutral - kHueCoolBlue) * t);
    } else {
        const float t = (h - 0.5f) * 2.0f;
        s.green = clampStops(kHueNeutral + (kHueWarmGreen - kHueNeutral) * t);
        s.blue = clampStops(kHueNeutral + (kHueWarmBlue - kHueNeutral) * t);
    }
    return s;
}

Stops applySaturationToStops(const Stops& hueStops, float saturation) {
    const float s = clampSaturation(saturation);
    Stops o{};
    o.green = clampStops(s * hueStops.green);
    o.blue = clampStops(s * hueStops.blue);
    return o;
}

float stopsToLinear(float stops) {
    return std::exp2(clampStops(stops));
}

void buildRedshiftInvMatrix(
    float exposureLostLin,
    float greenLin,
    float blueLin,
    float invOut[9],
    float distributionScale) {
    const float dr = distributionScale > 1.0e-6f ? distributionScale : 1.0f;
    const float e = exposureLostLin;
    const float g = greenLin;
    const float b = blueLin;
    const float a = 1.0f + e * dr;
    const float invA = 1.0f / std::fmax(a, 1.0e-6f);
    const float c = e * g * dr;
    const float d = e * g * b * dr;
    invOut[0] = invA;
    invOut[1] = 0.0f;
    invOut[2] = 0.0f;
    invOut[3] = -c * invA;
    invOut[4] = 1.0f;
    invOut[5] = 0.0f;
    invOut[6] = -d * invA;
    invOut[7] = 0.0f;
    invOut[8] = 1.0f;
}

ResolvedTf resolveTfParams(float intensity, float hue, float saturation) {
    ResolvedTf r{};
    const Stops hueStops = hueToExposureStops(hue);
    const Stops eff = applySaturationToStops(hueStops, saturation);
    const float expBase = stopsToLinear(intensityToExposureLostStops(intensity));
    const float expBoosted = expBase * kIntensityUnderHoodGain;
    const float expMax = stopsToLinear(0.0f) * kIntensityUnderHoodGain;
    r.exposureLostLin = expBoosted > expMax ? expMax : expBoosted;
    r.greenLin = stopsToLinear(eff.green);
    r.blueLin = stopsToLinear(eff.blue);
    buildRedshiftInvMatrix(r.exposureLostLin, r.greenLin, r.blueLin, r.invMatrix, 1.0f);
    r.matrixValid = r.exposureLostLin > 1.0e-6f;
    return r;
}

float mpsSigmaFromSpread(float spread) {
    const float s = spread < 0.0f ? 0.0f : spread;
    return std::fmax(0.1f, std::fmax(1.0f, s * 4.5f) / 2.4f);
}

namespace {

float safePowDistribution(float base, float exp) {
    if (base <= 0.0f)
        return 0.0f;
    return std::pow(base, exp);
}

float blurPathGamma(float value, float gamma, float whitepoint) {
    float v = value / whitepoint;
    if (v > 1.0e-6f) {
        const float gammaAdjusted = safePowDistribution(v, 1.0f / gamma);
        const float weight = v * (1.0f - v) + gammaAdjusted * v;
        v = 0.75f * gammaAdjusted + 0.25f * weight;
    }
    return v * whitepoint;
}

}

float highlightDistributionBlurScale(float sceneLuma, float distribution, float whitepoint) {
    const float gamma = clampf(distribution, 0.6f, 1.0f);
    if (gamma >= 1.0f - 1.0e-5f)
        return 1.0f;
    if (sceneLuma <= 1.0e-6f)
        return 1.0f;
    const float yShaped = blurPathGamma(sceneLuma, gamma, whitepoint);
    return yShaped / sceneLuma;
}

RGBf scaleLinearForBlurDistribution(const RGBf& lin, float distribution, float whitepoint, const float cieLumaCoeffs[3]) {
    const float y = cieLumaCoeffs[0] * lin.r + cieLumaCoeffs[1] * lin.g + cieLumaCoeffs[2] * lin.b;
    const float scale = highlightDistributionBlurScale(y, distribution, whitepoint);
    RGBf o{};
    o.r = lin.r * scale;
    o.g = lin.g * scale;
    o.b = lin.b * scale;
    return o;
}

}

