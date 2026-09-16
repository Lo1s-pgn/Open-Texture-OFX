#pragma once

#include <cmath>

#include "../core/LSPOpenTextureGlareMapping.h"

struct LSPOpenTextureGlareParamsHost {
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
    // bloomBlurSigma must stay last; older metallibs / host struct layout
    float bloomBlurSigma;
};

inline int openTextureGlareQualityFactor(int quality) {
    if (quality < 0)
        quality = 0;
    else if (quality > 2)
        quality = 2;
    return 1 << quality;
}

inline void openTextureGlareBuildHostParams(
    LSPOpenTextureGlareParamsHost& out,
    int width,
    int height,
    float thresholdUi,
    float smoothness,
    bool clampEnabled,
    float maxHighlights,
    float spread,
    float strength,
    float saturation,
    float temperature,
    float exposure,
    int displayMode) {
    if (spread < 0.0f)
        spread = 0.0f;
    if (strength < 0.0f)
        strength = 0.0f;
    if (saturation < 0.0f)
        saturation = 0.0f;
    else if (saturation > 2.0f)
        saturation = 2.0f;
    if (temperature < 0.0f)
        temperature = 0.0f;
    else if (temperature > 1.0f)
        temperature = 1.0f;
    if (exposure < 0.5f)
        exposure = 0.5f;
    else if (exposure > 2.5f)
        exposure = 2.5f;
    if (thresholdUi < 0.0f)
        thresholdUi = 0.0f;
    else if (thresholdUi > 1.0f)
        thresholdUi = 1.0f;
    if (maxHighlights < 0.0f)
        maxHighlights = 0.0f;
    else if (maxHighlights > 1.0f)
        maxHighlights = 1.0f;
    if (thresholdUi > maxHighlights)
        thresholdUi = maxHighlights;
    if (displayMode < 0)
        displayMode = 0;
    else if (displayMode > 2)
        displayMode = 2;

    const int quality = LSPOpenTextureGlareMapping::kForcedQuality;
    const int qf = openTextureGlareQualityFactor(quality);
    const int hiW = (width + qf - 1) / qf;
    const int hiH = (height + qf - 1) / qf;
    const LSPOpenTextureGlareMapping::BloomChainPlan plan = LSPOpenTextureGlareMapping::planBloomChain(hiW, hiH, spread);
    const float normScale = LSPOpenTextureGlareMapping::normalizationChainLengthF(plan);
    const float threshold = LSPOpenTextureGlareMapping::uiToThreshold(thresholdUi);

    out.threshold = threshold;
    out.smoothness = smoothness;
    out.maxBrightness =
        clampEnabled
            ? LSPOpenTextureGlareMapping::nitsToMaxBrightness(LSPOpenTextureGlareMapping::uiToMaxHighlightsNits(maxHighlights))
            : 1.0e6f;
    out.quality = quality;
    out.qualityFactor = qf;
    out.spread = spread;
    out.strength = strength;
    out.saturation = saturation;
    out.temperature = temperature;
    out.exposure = exposure;
    out.glareAmount = strength / normScale;
    out.bloomBlurSigma = plan.bloomBlurSigma;
    out.chainLength = plan.chainPrimary;
    out.chainLengthAlt = plan.chainAlt;
    out.chainBlend = plan.chainBlend;
    out.clampEnabled = clampEnabled ? 1 : 0;
    out.displayMode = displayMode;
    out.highlightsWidth = hiW;
    out.highlightsHeight = hiH;
}
