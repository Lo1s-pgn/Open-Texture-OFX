#pragma once

#include "LSPOpenTextureEffectWindow.h"

struct LSPOpenTextureMetalParamsHost {
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

inline void fillOpenTextureMetalEffectWindow(LSPOpenTextureMetalParamsHost& p, const LSPOpenTextureEffectWindowGeo& geo, bool enabled, bool showBorder) {
    p.effectWindowEnabled = enabled ? 1 : 0;
    p.effectWindowLeft = geo.overlayLeft;
    p.effectWindowTop = geo.overlayTop;
    p.effectWindowWidth = geo.overlayWidth;
    p.effectWindowHeight = geo.overlayHeight;
    p.effectWindowShowBorder = (enabled && showBorder) ? 1 : 0;
}
