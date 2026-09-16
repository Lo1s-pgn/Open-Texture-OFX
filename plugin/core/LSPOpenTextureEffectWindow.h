#pragma once

#include <algorithm>
#include <cmath>

struct LSPOpenTextureEffectWindowGeo {
    float overlayLeft;
    float overlayTop;
    float overlayWidth;
    float overlayHeight;
};

static const float kOpenTextureEffectWindowDefaultAspect = 1.78f;

inline LSPOpenTextureEffectWindowGeo computeOpenTextureEffectWindowGeo(int width, int height, float aspectRatio, bool useVerticalAspect) {
    LSPOpenTextureEffectWindowGeo g{};
    if (width <= 0 || height <= 0)
        return g;
    float targetAspect = aspectRatio;
    if (useVerticalAspect) {
        if (aspectRatio > 1.0e-6f)
            targetAspect = 1.0f / aspectRatio;
    }
    if (targetAspect < 1.0e-6f)
        targetAspect = kOpenTextureEffectWindowDefaultAspect;
    const float actualWidth = static_cast<float>(width);
    const float actualHeight = static_cast<float>(height);
    const float frameAspect = actualWidth / actualHeight;
    if (frameAspect > targetAspect) {
        g.overlayHeight = actualHeight;
        g.overlayWidth = actualHeight * targetAspect;
        g.overlayLeft = (actualWidth - g.overlayWidth) * 0.5f;
        g.overlayTop = 0.0f;
    } else {
        g.overlayWidth = actualWidth;
        g.overlayHeight = actualWidth / targetAspect;
        g.overlayLeft = 0.0f;
        g.overlayTop = (actualHeight - g.overlayHeight) * 0.5f;
    }
    return g;
}

inline bool halationPixelInEffectWindowGeo(int x, int y, const LSPOpenTextureEffectWindowGeo& geo) {
    const float xf = static_cast<float>(x);
    const float yf = static_cast<float>(y);
    return xf >= geo.overlayLeft && xf < geo.overlayLeft + geo.overlayWidth && yf >= geo.overlayTop &&
           yf < geo.overlayTop + geo.overlayHeight;
}

inline void halationClampToEffectWindowGeo(int& x, int& y, const LSPOpenTextureEffectWindowGeo& geo) {
    const int x1 = static_cast<int>(std::ceil(geo.overlayLeft));
    const int y1 = static_cast<int>(std::ceil(geo.overlayTop));
    const int x2 = static_cast<int>(std::floor(geo.overlayLeft + geo.overlayWidth));
    const int y2 = static_cast<int>(std::floor(geo.overlayTop + geo.overlayHeight));
    if (x < x1)
        x = x1;
    else if (x >= x2)
        x = std::max(x1, x2 - 1);
    if (y < y1)
        y = y1;
    else if (y >= y2)
        y = std::max(y1, y2 - 1);
}

static const int kOpenTextureEffectWindowAspectPresetCustom = 0;
static const int kOpenTextureEffectWindowAspectPresetDefault = 5;
static const int kOpenTextureEffectWindowAspectPresetCount = 12;

static const float kOpenTextureEffectWindowAspectPresetValues[kOpenTextureEffectWindowAspectPresetCount] = {
    0.0f,
    1.33f,
    1.37f,
    1.43f,
    1.66f,
    1.78f,
    1.85f,
    2.0f,
    2.20f,
    2.35f,
    2.39f,
    2.4f,
};

inline float halationEffectWindowAspectForPresetIndex(int presetIdx) {
    if (presetIdx <= kOpenTextureEffectWindowAspectPresetCustom || presetIdx >= kOpenTextureEffectWindowAspectPresetCount)
        return -1.0f;
    return kOpenTextureEffectWindowAspectPresetValues[presetIdx];
}

inline bool halationEffectWindowPixelOnBorder(int x, int y, const LSPOpenTextureEffectWindowGeo& geo, float borderWidth = 4.0f) {
    const float fx = static_cast<float>(x);
    const float fy = static_cast<float>(y);
    const float ol = geo.overlayLeft;
    const float ot = geo.overlayTop;
    const float ow = geo.overlayWidth;
    const float oh = geo.overlayHeight;
    const float bw = borderWidth;
    const float winRight = ol + ow;
    const float winBottom = ot + oh;
    if (fx >= ol && fx < winRight && fy >= ot && fy < winBottom)
        return false;
    return (fx >= ol - bw && fx < ol && fy >= ot && fy < winBottom) ||
           (fx >= winRight && fx < winRight + bw && fy >= ot && fy < winBottom) ||
           (fy >= ot - bw && fy < ot && fx >= ol && fx < winRight) ||
           (fy >= winBottom && fy < winBottom + bw && fx >= ol && fx < winRight);
}

inline void halationEffectWindowBorderRgb(float& r, float& g, float& b) {
    r = 0.5f;
    g = 0.0f;
    b = 0.0f;
}
