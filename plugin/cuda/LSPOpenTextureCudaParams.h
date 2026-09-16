#pragma once

#include "../core/LSPOpenTextureMetalParams.h"
#include "LSPOpenTextureCudaCommon.cuh"

#include <cstring>

inline OpenTextureCudaParams toCudaParams(const LSPOpenTextureMetalParamsHost& host) {
    OpenTextureCudaParams p{};
    p.distribution = host.distribution;
    p.inputTransferFunction = host.inputTransferFunction;
    p.workingTransferFunction = host.workingTransferFunction;
    p.showDistribution = host.showDistribution;
    p.width = host.width;
    p.height = host.height;
    p.srcRowFloats = host.srcRowFloats;
    p.dstRowFloats = host.dstRowFloats;
    p.exposureLostLin = host.exposureLostLin;
    p.greenExposureLostLin = host.greenExposureLostLin;
    p.blueExposureLostLin = host.blueExposureLostLin;
    std::memcpy(p.invMatrix, host.invMatrix, sizeof(p.invMatrix));
    std::memcpy(p.inputToDwg, host.inputToDwg, sizeof(p.inputToDwg));
    std::memcpy(p.dwgToInput, host.dwgToInput, sizeof(p.dwgToInput));
    std::memcpy(p.cieLumaCoeffs, host.cieLumaCoeffs, sizeof(p.cieLumaCoeffs));
    p.effectWindowEnabled = host.effectWindowEnabled;
    p.effectWindowLeft = host.effectWindowLeft;
    p.effectWindowTop = host.effectWindowTop;
    p.effectWindowWidth = host.effectWindowWidth;
    p.effectWindowHeight = host.effectWindowHeight;
    p.effectWindowShowBorder = host.effectWindowShowBorder;
    return p;
}
