#ifndef LSP_OPEN_TEXTURE_TF_MAPPING_H
#define LSP_OPEN_TEXTURE_TF_MAPPING_H

namespace LSPOpenTextureTfMapping {

constexpr float kSaturationMax = 2.0f;

constexpr float kIntensityUnderHoodGain = 1.33f;

constexpr float kStopMin = -10.0f;
constexpr float kStopMax = 0.0f;

struct RGBf {
    float r;
    float g;
    float b;
};

struct Stops {
    float green;
    float blue;
};

struct ResolvedTf {
    float exposureLostLin;
    float greenLin;
    float blueLin;
    float invMatrix[9];
    bool matrixValid;
};

float clampf(float v, float mn, float mx);
float clampHue01(float hue);
float clampSaturation(float saturation);
float clampIntensity(float intensity);

float intensityToExposureLostStops(float intensity);

Stops hueToExposureStops(float hue01);

Stops applySaturationToStops(const Stops& hueStops, float saturation);

float stopsToLinear(float stops);

void buildRedshiftInvMatrix(
    float exposureLostLin,
    float greenLin,
    float blueLin,
    float invOut[9],
    float distributionScale = 1.0f);

ResolvedTf resolveTfParams(float intensity, float hue, float saturation);

float mpsSigmaFromSpread(float spread);

float highlightDistributionBlurScale(float sceneLuma, float distribution, float whitepoint);

RGBf scaleLinearForBlurDistribution(const RGBf& lin, float distribution, float whitepoint, const float cieLumaCoeffs[3]);

}


#endif
