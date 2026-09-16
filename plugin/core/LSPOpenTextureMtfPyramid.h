#pragma once

#include "LSPOpenTextureVanVliet.h"

struct OpenTextureMtfPyramidPlan {
    bool usePyramid = false;
    int levels = 0;
    float mpsSigma = 0.0f;
};

inline OpenTextureMtfPyramidPlan openTextureMtfPyramidPlan(float sigma, int bandIndex) {
    OpenTextureMtfPyramidPlan plan{};
    plan.mpsSigma = sigma;
    if (sigma < kOpenTexturePyramidBlurSigmaThreshold) {
        plan.usePyramid = true;
        plan.levels = 1;
        plan.mpsSigma = sigma * 0.5f;
        return plan;
    }
    if (sigma < 12.0f && bandIndex < 5) {
        plan.usePyramid = true;
        plan.levels = 1;
        plan.mpsSigma = sigma * 0.5f;
        return plan;
    }
    plan.usePyramid = true;
    plan.levels = 2;
    plan.mpsSigma = sigma * 0.25f;
    return plan;
}
