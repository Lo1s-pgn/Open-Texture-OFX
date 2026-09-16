#include "LSPOpenTextureCuda.h"
#include "LSPOpenTextureCudaLaunch.h"
#include "LSPOpenTextureCudaParams.h"
#include "LSPOpenTextureFreqEQCuda.h"
#include "LSPOpenTextureGlareCuda.h"

#include "../core/LSPOpenTextureConstants.h"
#include "../core/LSPOpenTextureEffectWindow.h"
#include "../core/LSPOpenTextureGamut.h"
#include "../core/LSPOpenTextureGlareIdentity.h"
#include "../core/LSPOpenTextureLog.h"
#include "../core/LSPOpenTextureMetalParams.h"
#include "../core/LSPOpenTextureMtfIdentity.h"
#include "../core/LSPOpenTextureProfile.h"
#include "../core/LSPOpenTextureTextureFormats.h"
#include "../core/LSPOpenTextureTfMapping.h"
#include "../core/LSPOpenTextureVanVliet.h"
#include "../metal/LSPOpenTextureGlareParams.h"

#include <cmath>
#include <cstring>
#include <mutex>
#include <sstream>

namespace {

struct HalationScratchCache {
    float* preprocess = nullptr;
    float* blurScratchA = nullptr;
    float* blurScratchB = nullptr;
    float* pyramidSrc = nullptr;
    float* pyramidBlur = nullptr;
    size_t packedBytes = 0;
    int width = 0;
    int height = 0;
};

struct MtfPreCudaCache {
    float* buf = nullptr;
    size_t byteCapacity = 0;
};

struct CudaRenderContext {
    HalationScratchCache halation;
    MtfPreCudaCache mtfPre;
    std::mutex mtfPostMutex;
};

CudaRenderContext& context() {
    static CudaRenderContext ctx;
    return ctx;
}

bool syncStreamIfNeeded(cudaStream_t stream, void* hostStream) {
    if (hostStream != nullptr)
        return true;
    const cudaError_t err = cudaStreamSynchronize(stream);
    return err == cudaSuccess;
}

void releaseHalationScratch(HalationScratchCache& cache) {
    if (cache.preprocess) {
        cudaFree(cache.preprocess);
        cache.preprocess = nullptr;
    }
    if (cache.blurScratchA) {
        cudaFree(cache.blurScratchA);
        cache.blurScratchA = nullptr;
    }
    if (cache.blurScratchB) {
        cudaFree(cache.blurScratchB);
        cache.blurScratchB = nullptr;
    }
    if (cache.pyramidSrc) {
        cudaFree(cache.pyramidSrc);
        cache.pyramidSrc = nullptr;
    }
    if (cache.pyramidBlur) {
        cudaFree(cache.pyramidBlur);
        cache.pyramidBlur = nullptr;
    }
    cache.packedBytes = 0;
    cache.width = 0;
    cache.height = 0;
}

void releaseMtfPreCache(MtfPreCudaCache& cache) {
    if (cache.buf) {
        cudaFree(cache.buf);
        cache.buf = nullptr;
    }
    cache.byteCapacity = 0;
}

bool ensureHalationScratch(HalationScratchCache& cache, int width, int height) {
    if (width <= 0 || height <= 0)
        return false;
    const size_t packedBytes = openTextureBlurPackedBytes(width, height);
    const int pw = std::max((width + 1) / 2, 1);
    const int ph = std::max((height + 1) / 2, 1);
    const size_t pyramidBytes = openTextureBlurPackedBytes(pw, ph);
    if (cache.preprocess && cache.width == width && cache.height == height && cache.packedBytes == packedBytes)
        return true;
    releaseHalationScratch(cache);
    cache.width = width;
    cache.height = height;
    cache.packedBytes = packedBytes;
    if (cudaMalloc(reinterpret_cast<void**>(&cache.preprocess), packedBytes) != cudaSuccess)
        return false;
    if (cudaMalloc(reinterpret_cast<void**>(&cache.blurScratchA), packedBytes) != cudaSuccess)
        return false;
    if (cudaMalloc(reinterpret_cast<void**>(&cache.blurScratchB), packedBytes) != cudaSuccess)
        return false;
    if (cudaMalloc(reinterpret_cast<void**>(&cache.pyramidSrc), pyramidBytes) != cudaSuccess)
        return false;
    if (cudaMalloc(reinterpret_cast<void**>(&cache.pyramidBlur), pyramidBytes) != cudaSuccess)
        return false;
    return cache.preprocess != nullptr;
}

bool ensureMtfPreBuffer(MtfPreCudaCache& cache, size_t regionBytes) {
    if (cache.buf && cache.byteCapacity >= regionBytes)
        return true;
    releaseMtfPreCache(cache);
    if (cudaMalloc(reinterpret_cast<void**>(&cache.buf), regionBytes) != cudaSuccess)
        return false;
    cache.byteCapacity = regionBytes;
    return cache.buf != nullptr;
}

bool encodeRegionCopy(float* src, float* dst, const OpenTextureCudaParams& io, cudaStream_t stream) {
    return otLaunchRegionCopy(src, dst, io, stream) == cudaSuccess;
}

bool encodeGlobalBlend(float* src, float* dst, const OpenTextureCudaParams& io, float mixEffect, cudaStream_t stream) {
    float g = mixEffect;
    if (g < 0.0f)
        g = 0.0f;
    else if (g > 1.0f)
        g = 1.0f;
    return otLaunchGlobalBlend(src, dst, io, g, stream) == cudaSuccess;
}

bool encodeWindowEdgeReplicateDense(float* buf, const OpenTextureCudaParams& io, cudaStream_t stream) {
    if (!io.effectWindowEnabled)
        return true;
    return otLaunchWindowEdgeReplicateDense(buf, io, stream) == cudaSuccess;
}

bool encodeWindowEdgeReplicateStrided(float* buf, const OpenTextureCudaParams& io, cudaStream_t stream) {
    if (!io.effectWindowEnabled)
        return true;
    return otLaunchWindowEdgeReplicateStrided(buf, io, stream) == cudaSuccess;
}

bool encodeFinishRender(float* dst, const OpenTextureCudaParams& io, cudaStream_t stream) {
    if (!otLaunchWindowBlackMask(dst, io, stream))
        return false;
    return otLaunchWindowBorder(dst, io, stream) == cudaSuccess;
}

bool encodeHalationBlur(HalationScratchCache& cache, int width, int height, float spread, cudaStream_t stream) {
    OPEN_TEXTURE_PROFILE_STAGE("halation");
    if (spread < 1.0e-6f) {
        return cudaMemcpyAsync(cache.blurScratchB, cache.preprocess, cache.packedBytes, cudaMemcpyDeviceToDevice, stream) == cudaSuccess;
    }
    const float sigma = LSPOpenTextureTfMapping::mpsSigmaFromSpread(spread);
    return blurRGBA_VanVliet(cache.blurScratchB, cache.preprocess, width, height, sigma, cache.blurScratchA, cache.blurScratchB,
                             cache.pyramidSrc, cache.pyramidBlur, stream) == cudaSuccess;
}

bool encodeMtfPost(float* dstBuffer, const OpenTextureCudaParams& io, const float mtfEq[8], int mtfDisplay, int mtfGrey, float mtfLumaBlend,
                   float mtfGlobalBlend, cudaStream_t stream) {
    OPEN_TEXTURE_PROFILE_STAGE("mtf");
    auto& ctx = context();
    std::lock_guard<std::mutex> mtfLock(ctx.mtfPostMutex);
    const float mg = (mtfGlobalBlend < 0.0f) ? 0.0f : ((mtfGlobalBlend > 1.0f) ? 1.0f : mtfGlobalBlend);
    if (mg <= 1.0e-5f)
        return true;
    if (openTextureMtfIsIdentity(mtfEq, mtfDisplay, mg))
        return true;
    if (!encodeWindowEdgeReplicateStrided(dstBuffer, io, stream))
        return false;

    LSPOpenTextureMetalParamsHost hostIo{};
    hostIo.width = io.width;
    hostIo.height = io.height;
    hostIo.srcRowFloats = io.srcRowFloats;
    hostIo.dstRowFloats = io.dstRowFloats;
    hostIo.inputTransferFunction = io.inputTransferFunction;
    hostIo.workingTransferFunction = io.workingTransferFunction;
    hostIo.distribution = io.distribution;
    hostIo.showDistribution = io.showDistribution;
    hostIo.exposureLostLin = io.exposureLostLin;
    hostIo.greenExposureLostLin = io.greenExposureLostLin;
    hostIo.blueExposureLostLin = io.blueExposureLostLin;
    std::memcpy(hostIo.invMatrix, io.invMatrix, sizeof(hostIo.invMatrix));
    std::memcpy(hostIo.inputToDwg, io.inputToDwg, sizeof(hostIo.inputToDwg));
    std::memcpy(hostIo.dwgToInput, io.dwgToInput, sizeof(hostIo.dwgToInput));
    std::memcpy(hostIo.cieLumaCoeffs, io.cieLumaCoeffs, sizeof(hostIo.cieLumaCoeffs));
    hostIo.effectWindowEnabled = io.effectWindowEnabled;
    hostIo.effectWindowLeft = io.effectWindowLeft;
    hostIo.effectWindowTop = io.effectWindowTop;
    hostIo.effectWindowWidth = io.effectWindowWidth;
    hostIo.effectWindowHeight = io.effectWindowHeight;
    hostIo.effectWindowShowBorder = io.effectWindowShowBorder;

    const size_t regionBytes = static_cast<size_t>(io.height) * static_cast<size_t>(io.dstRowFloats) * sizeof(float);
    const bool needPre = mg < 1.0f - 1.0e-5f;
    if (needPre) {
        if (!ensureMtfPreBuffer(ctx.mtfPre, regionBytes))
            return false;
        if (!encodeRegionCopy(dstBuffer, ctx.mtfPre.buf, io, stream))
            return false;
    }

    float eqCopy[8];
    std::memcpy(eqCopy, mtfEq, sizeof(eqCopy));
    bool skipUnpack = false;
    if (!LSPOpenTextureFreqEQ_EncodeCuda(dstBuffer, dstBuffer, hostIo, eqCopy, mtfDisplay, mtfGrey, mtfLumaBlend, &skipUnpack, stream))
        return false;
    (void)skipUnpack;

    if (needPre)
        return encodeGlobalBlend(ctx.mtfPre.buf, dstBuffer, io, mg, stream);
    return true;
}

bool encodeGlarePost(
    float* dstBuffer,
    const OpenTextureCudaParams& io,
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
    cudaStream_t stream) {
    OPEN_TEXTURE_PROFILE_STAGE("glare");
    const float eps = 1.0e-5f;
    if (!glareEnable || (glareDisplay == 0 && (glareGlobalBlend <= eps || glareStrength <= eps)))
        return true;

    LSPOpenTextureMetalParamsHost hostIo{};
    hostIo.width = io.width;
    hostIo.height = io.height;
    hostIo.srcRowFloats = io.srcRowFloats;
    hostIo.dstRowFloats = io.dstRowFloats;
    hostIo.inputTransferFunction = io.inputTransferFunction;
    hostIo.workingTransferFunction = io.workingTransferFunction;
    hostIo.distribution = io.distribution;
    hostIo.showDistribution = io.showDistribution;
    hostIo.exposureLostLin = io.exposureLostLin;
    hostIo.greenExposureLostLin = io.greenExposureLostLin;
    hostIo.blueExposureLostLin = io.blueExposureLostLin;
    std::memcpy(hostIo.invMatrix, io.invMatrix, sizeof(hostIo.invMatrix));
    std::memcpy(hostIo.inputToDwg, io.inputToDwg, sizeof(hostIo.inputToDwg));
    std::memcpy(hostIo.dwgToInput, io.dwgToInput, sizeof(hostIo.dwgToInput));
    std::memcpy(hostIo.cieLumaCoeffs, io.cieLumaCoeffs, sizeof(hostIo.cieLumaCoeffs));
    hostIo.effectWindowEnabled = io.effectWindowEnabled;
    hostIo.effectWindowLeft = io.effectWindowLeft;
    hostIo.effectWindowTop = io.effectWindowTop;
    hostIo.effectWindowWidth = io.effectWindowWidth;
    hostIo.effectWindowHeight = io.effectWindowHeight;
    hostIo.effectWindowShowBorder = io.effectWindowShowBorder;

    LSPOpenTextureGlareParamsHost glare{};
    openTextureGlareBuildHostParams(
        glare,
        io.width,
        io.height,
        glareThreshold,
        glareSmoothness,
        glareClampHighlights,
        glareMaxHighlights,
        glareSpread,
        glareStrength,
        glareSaturation,
        glareTemperature,
        glareExposure,
        glareDisplay);

    float gg = glareGlobalBlend;
    if (gg < 0.0f)
        gg = 0.0f;
    else if (gg > 1.0f)
        gg = 1.0f;
    return LSPOpenTextureGlareCuda::EncodeCuda(dstBuffer, hostIo, glare, gg, stream);
}

}

namespace LSPOpenTextureCuda {

bool renderHost(
    const float* srcDevice,
    float* dstDevice,
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
    void* cudaStream) {
    if (!srcDevice || !dstDevice || width <= 0 || height <= 0)
        return false;

    OPEN_TEXTURE_PROFILE_FRAME();

    cudaStream_t stream = cudaStream ? reinterpret_cast<cudaStream_t>(cudaStream) : cudaStreamLegacy;

    const size_t packedRowBytes = static_cast<size_t>(width) * 4u * sizeof(float);
    size_t srb = srcRowBytes == 0 ? packedRowBytes : srcRowBytes;
    size_t drb = dstRowBytes == 0 ? packedRowBytes : dstRowBytes;
    if (srb < packedRowBytes || drb < packedRowBytes || srcPixelCol < 0 || srcPixelRow < 0 || dstPixelCol < 0 || dstPixelRow < 0)
        return false;

    auto offsetFor = [](size_t rb, int col, int row) -> size_t {
        return static_cast<size_t>(row) * rb + static_cast<size_t>(col) * 4u * sizeof(float);
    };

    const size_t srcOffsetBytes = offsetFor(srb, srcPixelCol, srcPixelRow);
    const size_t dstOffsetBytes = offsetFor(drb, dstPixelCol, dstPixelRow);

    float* src = const_cast<float*>(srcDevice) + srcOffsetBytes / sizeof(float);
    float* dst = dstDevice + dstOffsetBytes / sizeof(float);

    auto& ctx = context();

    const LSPOpenTextureTfMapping::ResolvedTf tf = LSPOpenTextureTfMapping::resolveTfParams(intensity, hue, saturation);

    LSPOpenTextureMetalParamsHost hostParams{};
    hostParams.distribution = highlightDistribution;
    hostParams.inputTransferFunction = transferFunction;
    hostParams.showDistribution = showDistribution ? 1 : 0;
    openTextureFillWorkingGamutParams(inputGamut, hostParams);
    hostParams.width = width;
    hostParams.height = height;
    hostParams.srcRowFloats = static_cast<int>(srb / sizeof(float));
    hostParams.dstRowFloats = static_cast<int>(drb / sizeof(float));
    hostParams.exposureLostLin = tf.exposureLostLin;
    hostParams.greenExposureLostLin = tf.greenLin;
    hostParams.blueExposureLostLin = tf.blueLin;
    std::memcpy(hostParams.invMatrix, tf.invMatrix, sizeof(hostParams.invMatrix));
    {
        const LSPOpenTextureEffectWindowGeo geo =
            computeOpenTextureEffectWindowGeo(width, height, effectWindowAspect, effectWindowVertical);
        fillOpenTextureMetalEffectWindow(hostParams, geo, effectWindowEnabled, effectWindowShowBorder);
    }

    OpenTextureCudaParams p = toCudaParams(hostParams);
    OpenTextureCudaParams ph = p;

    const float eps = 1.0e-5f;
    float hg = halationGlobalBlend;
    if (hg < 0.0f)
        hg = 0.0f;
    else if (hg > 1.0f)
        hg = 1.0f;
    float mg = mtfGlobalBlend;
    if (mg < 0.0f)
        mg = 0.0f;
    else if (mg > 1.0f)
        mg = 1.0f;

    int opOrder = operationOrder;
    if (opOrder < 0)
        opOrder = 0;
    else if (opOrder > 1)
        opOrder = 1;

    const bool halationBypass = !halationEnable || hg <= eps;
    if (halationBypass) {
        if (!encodeRegionCopy(src, dst, p, stream))
            return false;
        if (mtfEnable && mg > eps) {
            if (!encodeMtfPost(dst, p, mtfEq, mtfDisplay, mtfGrey, mtfLumaBlend, mg, stream))
                return false;
        }
        if (!encodeGlarePost(dst, p, glareEnable, glareGlobalBlend, glareThreshold, glareSmoothness, glareClampHighlights,
                             glareMaxHighlights, glareStrength, glareSaturation, glareTemperature, glareExposure, glareSpread, glareDisplay,
                             stream))
            return false;
        if (!encodeFinishRender(dst, p, stream))
            return false;
        return syncStreamIfNeeded(stream, cudaStream);
    }

    float* halSrc = src;
    const bool useMtfFirst = (opOrder == 1) && mtfEnable && (mg > eps);
    if (useMtfFirst) {
        if (!encodeRegionCopy(src, dst, p, stream))
            return false;
        if (!encodeMtfPost(dst, p, mtfEq, mtfDisplay, mtfGrey, mtfLumaBlend, mg, stream))
            return false;
        halSrc = dst;
        ph = p;
    }

    if (spread < 1.0e-6f && !showDistribution) {
        if (!encodeRegionCopy(halSrc, dst, ph, stream))
            return false;
        if (hg < 1.0f - eps) {
            if (!encodeGlobalBlend(src, dst, ph, hg, stream))
                return false;
        }
        if (!useMtfFirst && mtfEnable && mg > eps) {
            if (!encodeMtfPost(dst, p, mtfEq, mtfDisplay, mtfGrey, mtfLumaBlend, mg, stream))
                return false;
        }
        if (!encodeGlarePost(dst, p, glareEnable, glareGlobalBlend, glareThreshold, glareSmoothness, glareClampHighlights,
                             glareMaxHighlights, glareStrength, glareSaturation, glareTemperature, glareExposure, glareSpread, glareDisplay,
                             stream))
            return false;
        if (!encodeFinishRender(dst, p, stream))
            return false;
        return syncStreamIfNeeded(stream, cudaStream);
    }

    if (!ensureHalationScratch(ctx.halation, width, height))
        return false;

    if (otLaunchPreprocessPacked(halSrc, ctx.halation.preprocess, ph, stream) != cudaSuccess)
        return false;
    if (!encodeWindowEdgeReplicateDense(ctx.halation.preprocess, ph, stream))
        return false;
    if (!encodeHalationBlur(ctx.halation, width, height, spread, stream))
        return false;
    if (otLaunchCompositePacked(halSrc, ctx.halation.blurScratchB, dst, ph, stream) != cudaSuccess)
        return false;

    if (hg < 1.0f - eps) {
        if (!encodeGlobalBlend(src, dst, ph, hg, stream))
            return false;
    }
    if (!useMtfFirst && mtfEnable && mg > eps) {
        if (!encodeMtfPost(dst, p, mtfEq, mtfDisplay, mtfGrey, mtfLumaBlend, mg, stream))
            return false;
    }
    if (!encodeGlarePost(dst, p, glareEnable, glareGlobalBlend, glareThreshold, glareSmoothness, glareClampHighlights, glareMaxHighlights,
                         glareStrength, glareSaturation, glareTemperature, glareExposure, glareSpread, glareDisplay, stream))
        return false;
    if (!encodeFinishRender(dst, p, stream))
        return false;
    return syncStreamIfNeeded(stream, cudaStream);
}

}
