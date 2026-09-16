#pragma once

#include <cstddef>

#include "LSPOpenTextureGlareParams.h"

namespace LSPOpenTextureMetal {

bool renderHost(
    const void* srcMetalBuffer,
    void* dstMetalBuffer,
    int width,
    int height,
    size_t srcRowBytes,
    size_t dstRowBytes,
    int srcPixelCol,
    int srcPixelRow,
    int dstPixelCol,
    int dstPixelRow,
    bool halationEnable,
    float halationGlobalBlend,
    float intensity,
    float spread,
    float hue,
    float saturation,
    float highlightDistribution,
    bool showDistribution,
    int transferFunction,
    int inputGamut,
    int operationOrder,
    bool mtfEnable,
    float mtfGlobalBlend,
    const float mtfEq[8],
    int mtfDisplay,
    int mtfGrey,
    float mtfLumaBlend,
    bool effectWindowEnabled,
    float effectWindowAspect,
    bool effectWindowVertical,
    bool effectWindowShowBorder,
    bool glareEnable,
    float glareGlobalBlend,
    float glareThreshold,
    float glareSmoothness,
    bool glareClampHighlights,
    float glareMaxHighlights,
    float glareStrength,
    float glareSaturation,
    float glareTemperature,
    float glareExposure,
    float glareSpread,
    int glareDisplay,
    void* metalCommandQueue);

}
