#pragma once

#include <algorithm>
#include <cmath>

namespace LSPOpenTextureGlareMapping {

constexpr float kSpreadMin = 0.004f;
constexpr float kSpreadMax = 1.0f;
constexpr float kNitsPerLinear = 100.0f;
constexpr float kHighlightsNitsMin = 100.0f;
constexpr float kHighlightsNitsMax = 10000.0f;
constexpr float kMinHighlightsUiDefault = 0.0f;
constexpr float kMaxHighlightsUiDefault = 0.25f;
constexpr int kForcedQuality = 2;

constexpr int kGlareDisplayRender = 0;
constexpr int kGlareDisplaySource = 1;
constexpr int kGlareDisplayDiffusion = 2;

inline float clampHighlightsNits(float nits) {
    return std::max(kHighlightsNitsMin, std::min(kHighlightsNitsMax, nits));
}

inline float uiToHighlightsNits(float ui) {
    ui = std::max(0.0f, std::min(1.0f, ui));
    const float logMin = std::log(kHighlightsNitsMin);
    const float logMax = std::log(kHighlightsNitsMax);
    return std::exp(logMin + ui * (logMax - logMin));
}

inline float highlightsNitsToUi(float nits) {
    nits = clampHighlightsNits(nits);
    const float logMin = std::log(kHighlightsNitsMin);
    const float logMax = std::log(kHighlightsNitsMax);
    const float t = std::log(nits);
    return std::max(0.0f, std::min(1.0f, (t - logMin) / (logMax - logMin)));
}

inline float nitsToLinear(float nits) {
    return clampHighlightsNits(nits) / kNitsPerLinear;
}

inline float uiToMaxHighlightsNits(float ui) {
    return uiToHighlightsNits(ui);
}

inline float nitsToMaxBrightness(float nits) {
    return nitsToLinear(nits);
}

inline float defaultMinHighlightsUi() {
    return kMinHighlightsUiDefault;
}

inline float defaultMinHighlightsNits() {
    return uiToHighlightsNits(kMinHighlightsUiDefault);
}

inline float defaultMaxHighlightsUi() {
    return kMaxHighlightsUiDefault;
}

inline float defaultMaxHighlightsNits() {
    return uiToHighlightsNits(kMaxHighlightsUiDefault);
}

inline float defaultThresholdUi() {
    return defaultMinHighlightsUi();
}

inline float uiToThreshold(float ui) {
    return nitsToLinear(uiToHighlightsNits(ui));
}

inline float defaultSpreadUi() {
    return 0.5f;
}

inline float uiToSpread(float ui) {
    ui = std::max(0.0f, std::min(1.0f, ui));
    if (ui <= 0.0f)
        return 0.0f;
    const float logMin = std::log(kSpreadMin);
    const float logMax = std::log(kSpreadMax);
    return std::exp(logMin + ui * (logMax - logMin));
}

// old presets stored nits as a plain number (>1); fold that into log ui
inline float normalizeHighlightsUi(double value) {
    const float v = static_cast<float>(value);
    if (v > 1.0f)
        return highlightsNitsToUi(v);
    return std::max(0.0f, std::min(1.0f, v));
}

struct BloomChainPlan {
    float chainF = 0.0f;
    int chainPrimary = 0;
    int chainAlt = 0;
    float chainBlend = 0.0f;
    float bloomBlurSigma = 0.0f;
};

constexpr float kBloomBlurSigmaBase = 2.0f;

// bloom size vs spread: blend pyramid chains; dont snap chain 1 to 2 or bloom jumps ugly
inline BloomChainPlan planBloomChain(int width, int height, float spread) {
    BloomChainPlan plan{};
    if (spread <= 0.0f) {
        return plan;
    }

    const int smaller = (width < height) ? width : height;
    const float scaled = std::max(1.0f, static_cast<float>(smaller) * spread);
    plan.chainF = std::log2(scaled);
    const int maxChain = std::max(1, static_cast<int>(std::floor(std::log2(static_cast<float>(smaller)))));

    if (plan.chainF < 1.0f) {
        plan.chainPrimary = 1;
        plan.chainAlt = 1;
        plan.chainBlend = 0.0f;
        plan.bloomBlurSigma = kBloomBlurSigmaBase * std::max(0.25f, plan.chainF);
        return plan;
    }

    const int chainLo = static_cast<int>(std::floor(plan.chainF));
    plan.chainPrimary = std::max(1, chainLo);
    plan.chainAlt = std::min(plan.chainPrimary + 1, maxChain);
    plan.chainBlend = (plan.chainAlt > plan.chainPrimary) ? (plan.chainF - static_cast<float>(chainLo)) : 0.0f;
    plan.bloomBlurSigma = kBloomBlurSigmaBase;
    return plan;
}

inline float normalizationChainLengthF(const BloomChainPlan& plan) {
    return std::max(1.0f, plan.chainF);
}

}
