#pragma once

#include "LSPOpenTextureVanVliet.h"

struct OpenTextureMtfPyramidPlan {
    int levels = 0;
    float mpsSigma = 0.0f;
};

inline OpenTextureMtfPyramidPlan openTextureMtfPyramidPlan(float sigma, int bandIndex) {
    OpenTextureMtfPyramidPlan plan{};
    if (sigma < kOpenTexturePyramidBlurSigmaThreshold || (sigma < 12.0f && bandIndex < 5)) {
        plan.levels = 1;
        plan.mpsSigma = sigma * 0.5f;
        return plan;
    }
    plan.levels = 2;
    plan.mpsSigma = sigma * 0.25f;
    return plan;
}
