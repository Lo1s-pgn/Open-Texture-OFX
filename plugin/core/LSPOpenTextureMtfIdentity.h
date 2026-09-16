#pragma once

#include <cmath>

inline bool openTextureMtfIsIdentity(const float eq[8], int displaySwitch, float globalBlend) {
    constexpr float kEps = 1.0e-5f;
    if (eq == nullptr)
        return true;
    if (globalBlend <= kEps)
        return true;
    if (displaySwitch != 0)
        return false;
    for (int i = 0; i < 6; ++i) {
        if (std::fabs(eq[i] - 1.0f) > kEps)
            return false;
    }
    if (std::fabs(eq[7]) > kEps)
        return false;
    return true;
}

inline float openTextureMtfClampGlobalStrength(float v) {
    if (v < 0.0f)
        return 0.0f;
    if (v > 2.0f)
        return 2.0f;
    return v;
}

inline float openTextureMtfUiGainToLin(float uiGain) {
    return uiGain + 1.0f;
}

inline void openTextureMtfBuildEffectiveEq(float out[8], const float uiRaw[8], float globalStrength) {
    const float s = openTextureMtfClampGlobalStrength(globalStrength);
    if (uiRaw == nullptr || out == nullptr)
        return;
    constexpr float kNeutralLin = 1.0f;
    for (int i = 0; i < 8; ++i) {
        if (i < 6) {
            const float gainLin = openTextureMtfUiGainToLin(uiRaw[i]);
            out[i] = kNeutralLin + s * (gainLin - kNeutralLin);
        } else {
            out[i] = uiRaw[i];
        }
    }
}
