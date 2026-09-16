#include "LSPOpenTextureGlareCuda.h"
#include "LSPOpenTextureCudaLaunch.h"
#include "LSPOpenTextureCudaParams.h"
#include "LSPOpenTextureGlareCudaParams.h"

#include "../core/LSPOpenTextureGlareMapping.h"
#include "../core/LSPOpenTextureLog.h"
#include "../metal/LSPOpenTextureGlareParams.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>
#include <vector>

namespace {

OpenTextureGlareParamsCuda toCudaGlare(const LSPOpenTextureGlareParamsHost& host) {
    OpenTextureGlareParamsCuda gp{};
    gp.threshold = host.threshold;
    gp.smoothness = host.smoothness;
    gp.maxBrightness = host.maxBrightness;
    gp.quality = host.quality;
    gp.qualityFactor = host.qualityFactor;
    gp.spread = host.spread;
    gp.strength = host.strength;
    gp.saturation = host.saturation;
    gp.temperature = host.temperature;
    gp.exposure = host.exposure;
    gp.glareAmount = host.glareAmount;
    gp.bloomBlurSigma = host.bloomBlurSigma;
    gp.chainLength = host.chainLength;
    gp.chainLengthAlt = host.chainLengthAlt;
    gp.chainBlend = host.chainBlend;
    gp.clampEnabled = host.clampEnabled;
    gp.displayMode = host.displayMode;
    gp.highlightsWidth = host.highlightsWidth;
    gp.highlightsHeight = host.highlightsHeight;
    return gp;
}

struct GlareCudaScratch {
    float* rgbLinFull = nullptr;
    float* highlights = nullptr;
    float* bloomStaging = nullptr;
    float* bloomPrimaryStore = nullptr;
    float* bloomUpscaleHalf = nullptr;
    float* highlightsFullRes = nullptr;
    float* blurScratchA = nullptr;
    float* blurScratchB = nullptr;
    float* pyramidSrc = nullptr;
    float* pyramidBlur = nullptr;
    float* preBuffer = nullptr;
    std::vector<float*> bloomChain;
    size_t fullBytes = 0;
    size_t hiBytes = 0;
    size_t halfBytes = 0;
    size_t blurScratchBytes = 0;
    size_t preBytes = 0;
    int width = 0;
    int height = 0;
    int hiW = 0;
    int hiH = 0;
    int chainLength = 0;
};

std::mutex gGlareCudaMutex;
GlareCudaScratch gGlareCudaScratch;
std::atomic<bool> g_loggedGlareCudaFail{false};

void logGlareCudaOnce(const char* message) {
    if (g_loggedGlareCudaFail.exchange(true))
        return;
    LSPOpenTextureLog::writeErrorLine(message);
}

void releasePacked(float*& ptr) {
    if (ptr) {
        cudaFree(ptr);
        ptr = nullptr;
    }
}

void releaseGlareScratch(GlareCudaScratch& cache) {
    releasePacked(cache.rgbLinFull);
    releasePacked(cache.highlights);
    releasePacked(cache.bloomStaging);
    releasePacked(cache.bloomPrimaryStore);
    releasePacked(cache.bloomUpscaleHalf);
    releasePacked(cache.highlightsFullRes);
    releasePacked(cache.blurScratchA);
    releasePacked(cache.blurScratchB);
    releasePacked(cache.pyramidSrc);
    releasePacked(cache.pyramidBlur);
    releasePacked(cache.preBuffer);
    for (float* tex : cache.bloomChain)
        releasePacked(tex);
    cache.bloomChain.clear();
    cache.fullBytes = 0;
    cache.hiBytes = 0;
    cache.halfBytes = 0;
    cache.blurScratchBytes = 0;
    cache.preBytes = 0;
    cache.width = 0;
    cache.height = 0;
    cache.hiW = 0;
    cache.hiH = 0;
    cache.chainLength = 0;
}

size_t packedBytesFloat(int w, int h) {
    return static_cast<size_t>(w) * static_cast<size_t>(h) * 4u * sizeof(float);
}

bool allocPacked(float*& ptr, size_t bytes) {
    releasePacked(ptr);
    return cudaMalloc(reinterpret_cast<void**>(&ptr), bytes) == cudaSuccess;
}

bool ensureGlareScratch(int width, int height, int hiW, int hiH, int chainLength) {
    const size_t full = packedBytesFloat(width, height);
    const size_t hi = packedBytesFloat(hiW, hiH);
    const int halfW = std::max(1, hiW * 2);
    const int halfH = std::max(1, hiH * 2);
    const size_t half = packedBytesFloat(halfW, halfH);

    if (gGlareCudaScratch.width != width || gGlareCudaScratch.height != height || gGlareCudaScratch.hiW != hiW ||
        gGlareCudaScratch.hiH != hiH || gGlareCudaScratch.chainLength != chainLength) {
        releaseGlareScratch(gGlareCudaScratch);
        gGlareCudaScratch.width = width;
        gGlareCudaScratch.height = height;
        gGlareCudaScratch.hiW = hiW;
        gGlareCudaScratch.hiH = hiH;
        gGlareCudaScratch.chainLength = chainLength;
        gGlareCudaScratch.fullBytes = full;
        gGlareCudaScratch.hiBytes = hi;
        gGlareCudaScratch.halfBytes = half;
        gGlareCudaScratch.blurScratchBytes = hi;
    }

    if (!gGlareCudaScratch.rgbLinFull && !allocPacked(gGlareCudaScratch.rgbLinFull, full))
        return false;
    if (!gGlareCudaScratch.highlights && !allocPacked(gGlareCudaScratch.highlights, hi))
        return false;
    if (!gGlareCudaScratch.bloomStaging && !allocPacked(gGlareCudaScratch.bloomStaging, hi))
        return false;
    if (!gGlareCudaScratch.bloomPrimaryStore && !allocPacked(gGlareCudaScratch.bloomPrimaryStore, hi))
        return false;
    if (!gGlareCudaScratch.bloomUpscaleHalf && !allocPacked(gGlareCudaScratch.bloomUpscaleHalf, half))
        return false;
    if (!gGlareCudaScratch.blurScratchA && !allocPacked(gGlareCudaScratch.blurScratchA, hi))
        return false;
    if (!gGlareCudaScratch.blurScratchB && !allocPacked(gGlareCudaScratch.blurScratchB, hi))
        return false;
    const size_t pyramidBytes = packedBytesFloat(std::max(1, (hiW + 1) / 2), std::max(1, (hiH + 1) / 2));
    if (!gGlareCudaScratch.pyramidSrc && !allocPacked(gGlareCudaScratch.pyramidSrc, pyramidBytes))
        return false;
    if (!gGlareCudaScratch.pyramidBlur && !allocPacked(gGlareCudaScratch.pyramidBlur, pyramidBytes))
        return false;

    const int needed = chainLength > 0 ? chainLength : 1;
    if (static_cast<int>(gGlareCudaScratch.bloomChain.size()) != needed) {
        for (float* tex : gGlareCudaScratch.bloomChain)
            releasePacked(tex);
        gGlareCudaScratch.bloomChain.assign((size_t)needed, nullptr);
    }

    int w = hiW;
    int h = hiH;
    for (int i = 0; i < needed; ++i) {
        const size_t bytes = packedBytesFloat(w, h);
        if (!gGlareCudaScratch.bloomChain[(size_t)i] && !allocPacked(gGlareCudaScratch.bloomChain[(size_t)i], bytes))
            return false;
        w = std::max(1, w / 2);
        h = std::max(1, h / 2);
    }

    return gGlareCudaScratch.rgbLinFull != nullptr && gGlareCudaScratch.highlights != nullptr;
}

bool ensureGlareHighlightsFullRes(int width, int height) {
    const size_t bytes = packedBytesFloat(width, height);
    if (gGlareCudaScratch.highlightsFullRes && gGlareCudaScratch.width == width && gGlareCudaScratch.height == height)
        return true;
    return allocPacked(gGlareCudaScratch.highlightsFullRes, bytes);
}

bool ensureGlarePreBuffer(size_t bytes) {
    if (gGlareCudaScratch.preBuffer && gGlareCudaScratch.preBytes >= bytes)
        return true;
    gGlareCudaScratch.preBytes = bytes;
    return allocPacked(gGlareCudaScratch.preBuffer, bytes);
}

bool encodeGlareBloomChainVanVliet(float* highlights, int hiW, int hiH, int chainLength, float blurSigma, float*& outBloom, cudaStream_t stream) {
    if (chainLength < 1) {
        outBloom = highlights;
        return true;
    }

    if (chainLength == 1) {
        if (otLaunchGlareCopyPacked(hiW, hiH, highlights, gGlareCudaScratch.bloomChain[0], stream) != cudaSuccess)
            return false;
        if (blurRGBA_VanVliet(gGlareCudaScratch.bloomChain[0], gGlareCudaScratch.bloomChain[0], hiW, hiH, blurSigma,
                              gGlareCudaScratch.blurScratchA, gGlareCudaScratch.blurScratchB, gGlareCudaScratch.pyramidSrc,
                              gGlareCudaScratch.pyramidBlur, stream) != cudaSuccess)
            return false;
        outBloom = gGlareCudaScratch.bloomChain[0];
        return true;
    }

    if (otLaunchGlareCopyPacked(hiW, hiH, highlights, gGlareCudaScratch.bloomChain[0], stream) != cudaSuccess)
        return false;

    int srcW = hiW;
    int srcH = hiH;
    const int passes = chainLength - 1;
    for (int i = 0; i < passes; ++i) {
        const int dstW = std::max(1, srcW / 2);
        const int dstH = std::max(1, srcH / 2);
        float* srcTex = gGlareCudaScratch.bloomChain[(size_t)i];
        float* dstTex = gGlareCudaScratch.bloomChain[(size_t)(i + 1)];
        if (srcW == dstW && srcH == dstH) {
            if (otLaunchGlareCopyPacked(dstW, dstH, srcTex, dstTex, stream) != cudaSuccess)
                return false;
        } else if (otLaunchBilinearDownscaleRGBA(srcW, srcH, dstW, dstH, srcTex, dstTex, stream) != cudaSuccess) {
            return false;
        }
        if (blurRGBA_VanVliet(dstTex, dstTex, dstW, dstH, blurSigma, gGlareCudaScratch.blurScratchA,
                              gGlareCudaScratch.blurScratchB, gGlareCudaScratch.pyramidSrc, gGlareCudaScratch.pyramidBlur,
                              stream) != cudaSuccess)
            return false;
        srcW = dstW;
        srcH = dstH;
    }

    for (int i = 0; i < passes; ++i) {
        const int upIdx = passes - 1 - i;
        const int outIdx = upIdx;
        const int inIdx = upIdx + 1;
        float* inputTex = gGlareCudaScratch.bloomChain[(size_t)inIdx];
        float* outputTex = gGlareCudaScratch.bloomChain[(size_t)outIdx];
        const int ow = std::max(1, hiW >> outIdx);
        const int oh = std::max(1, hiH >> outIdx);
        const int iw = std::max(1, hiW >> inIdx);
        const int ih = std::max(1, hiH >> inIdx);
        if (otLaunchGlareBloomUp(ow, oh, iw, ih, inputTex, outputTex, stream) != cudaSuccess)
            return false;
    }

    outBloom = gGlareCudaScratch.bloomChain[0];
    return true;
}

bool encodeGlareUpscaleToFull(float* src, int srcW, int srcH, float* dst, int dstW, int dstH, cudaStream_t stream) {
    if (srcW == dstW && srcH == dstH)
        return otLaunchGlareCopyPacked(dstW, dstH, src, dst, stream) == cudaSuccess;

    float* cur = src;
    int curW = srcW;
    int curH = srcH;
    while (curW < dstW || curH < dstH) {
        const int nextW = std::min(dstW, curW * 2);
        const int nextH = std::min(dstH, curH * 2);
        const bool finalPass = (nextW >= dstW && nextH >= dstH);
        float* next = finalPass ? dst : gGlareCudaScratch.bloomUpscaleHalf;
        if (otLaunchGlareHalfResUp(nextW, nextH, curW, curH, cur, next, stream) != cudaSuccess)
            return false;
        cur = next;
        curW = nextW;
        curH = nextH;
    }
    return true;
}

}

namespace LSPOpenTextureGlareCuda {

bool EncodeCuda(float* dstStrided, const LSPOpenTextureMetalParamsHost& io, const LSPOpenTextureGlareParamsHost& glare, float globalBlend,
                cudaStream_t stream) {
    std::lock_guard<std::mutex> lock(gGlareCudaMutex);

    const int chainPrimary = glare.chainLength;
    const int chainAlt = glare.chainLengthAlt;
    const float chainBlend = glare.chainBlend;
    const int hiW = glare.highlightsWidth;
    const int hiH = glare.highlightsHeight;
    if (hiW <= 0 || hiH <= 0)
        return false;

    const int scratchChain = std::max({chainPrimary, chainAlt, 1});
    if (!ensureGlareScratch(io.width, io.height, hiW, hiH, scratchChain)) {
        logGlareCudaOnce("glare_cuda_scratch_unavailable");
        return false;
    }

    OpenTextureCudaParams p = toCudaParams(io);
    OpenTextureGlareParamsCuda gp = toCudaGlare(glare);

    const bool needPre = glare.displayMode == LSPOpenTextureGlareMapping::kGlareDisplayRender && globalBlend < 1.0f - 1.0e-5f;
    const size_t regionBytes = static_cast<size_t>(io.height) * static_cast<size_t>(io.dstRowFloats) * sizeof(float);
    if (needPre) {
        if (!ensureGlarePreBuffer(regionBytes))
            return false;
        if (cudaMemcpyAsync(gGlareCudaScratch.preBuffer, dstStrided, regionBytes, cudaMemcpyDeviceToDevice, stream) != cudaSuccess)
            return false;
    }

    if (otLaunchGlareDecodeStridedToPacked(dstStrided, gGlareCudaScratch.rgbLinFull, p, stream) != cudaSuccess)
        return false;
    if (!otLaunchWindowEdgeReplicateDense(gGlareCudaScratch.rgbLinFull, p, stream))
        return false;

    const bool sourceOverlay = glare.displayMode == LSPOpenTextureGlareMapping::kGlareDisplaySource;
    float* bloomResult = gGlareCudaScratch.highlights;
    float* glareFullRes = bloomResult;

    if (sourceOverlay) {
        if (!ensureGlareHighlightsFullRes(io.width, io.height))
            return false;
        OpenTextureGlareParamsCuda gpFull = gp;
        gpFull.quality = 0;
        gpFull.qualityFactor = 1;
        gpFull.highlightsWidth = io.width;
        gpFull.highlightsHeight = io.height;
        if (otLaunchGlareHighlights(gGlareCudaScratch.rgbLinFull, gGlareCudaScratch.highlightsFullRes, gpFull, p, stream) != cudaSuccess)
            return false;
        glareFullRes = gGlareCudaScratch.highlightsFullRes;
    } else {
        if (otLaunchGlareHighlights(gGlareCudaScratch.rgbLinFull, gGlareCudaScratch.highlights, gp, p, stream) != cudaSuccess)
            return false;

        if (chainPrimary >= 1) {
            const float blurSigma = glare.bloomBlurSigma;
            const float blendEps = 1.0e-4f;
            const bool needBlend = chainAlt > chainPrimary && chainBlend > blendEps;
            if (needBlend) {
                float* primaryChain = nullptr;
                if (!encodeGlareBloomChainVanVliet(gGlareCudaScratch.highlights, hiW, hiH, chainPrimary, blurSigma, primaryChain, stream))
                    return false;
                if (otLaunchGlareCopyPacked(hiW, hiH, primaryChain, gGlareCudaScratch.bloomPrimaryStore, stream) != cudaSuccess)
                    return false;
                float* bloomAlt = nullptr;
                if (!encodeGlareBloomChainVanVliet(gGlareCudaScratch.highlights, hiW, hiH, chainAlt, blurSigma, bloomAlt, stream))
                    return false;
                if (otLaunchGlareLerpPacked(hiW, hiH, gGlareCudaScratch.bloomPrimaryStore, bloomAlt, gGlareCudaScratch.bloomStaging, chainBlend,
                                            stream) != cudaSuccess)
                    return false;
                bloomResult = gGlareCudaScratch.bloomStaging;
            } else {
                if (!encodeGlareBloomChainVanVliet(gGlareCudaScratch.highlights, hiW, hiH, chainPrimary, blurSigma, bloomResult, stream))
                    return false;
            }
        }

        glareFullRes = bloomResult;
        const int bloomW = hiW;
        const int bloomH = hiH;
        if (bloomW < io.width || bloomH < io.height) {
            if (!encodeGlareUpscaleToFull(bloomResult, bloomW, bloomH, gGlareCudaScratch.rgbLinFull, io.width, io.height, stream))
                return false;
            glareFullRes = gGlareCudaScratch.rgbLinFull;
        }
    }

    int mixGlareW = hiW;
    int mixGlareH = hiH;
    if (glareFullRes == gGlareCudaScratch.rgbLinFull || glareFullRes == gGlareCudaScratch.highlightsFullRes) {
        mixGlareW = io.width;
        mixGlareH = io.height;
    }
    if (otLaunchGlareMixEncode(glareFullRes, mixGlareW, mixGlareH, io.width, io.height, dstStrided, dstStrided, gp, p, stream) != cudaSuccess)
        return false;

    if (needPre && glare.displayMode == LSPOpenTextureGlareMapping::kGlareDisplayRender) {
        float g = globalBlend;
        if (g < 0.0f)
            g = 0.0f;
        else if (g > 1.0f)
            g = 1.0f;
        if (otLaunchGlobalBlend(gGlareCudaScratch.preBuffer, dstStrided, p, g, stream) != cudaSuccess)
            return false;
    }

    return true;
}

}
