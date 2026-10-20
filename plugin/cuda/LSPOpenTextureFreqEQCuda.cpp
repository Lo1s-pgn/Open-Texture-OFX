#include "LSPOpenTextureFreqEQCuda.h"
#include "LSPOpenTextureCudaLaunch.h"

#include "../core/LSPOpenTextureConstants.h"
#include "../core/LSPOpenTextureLog.h"
#include "../core/LSPOpenTextureHostParams.h"
#include "../core/LSPOpenTextureMtfIdentity.h"
#include "../core/LSPOpenTextureMtfPyramid.h"
#include "../core/LSPOpenTextureVanVliet.h"

#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>

namespace {

constexpr int kPresplitBandCount = 6;
constexpr float kEqIdentityEps = 1.0e-5f;

std::mutex gFqCacheMutex;

struct ResCache {
    int width = 0;
    int height = 0;
    float* originalLinear = nullptr;
    float* lSource = nullptr;
    float* accDetail = nullptr;
    size_t packedBytes = 0;
};

struct PyramidPlan {
    int levels = 0;
    float mpsSigma = 0.0f;
};

struct PresplitBlurCache {
    int width = 0;
    int height = 0;
    float* bandBlur[kPresplitBandCount] = {nullptr};
    float* pyramidSrc = nullptr;
    float* pyramidSrc2 = nullptr;
    float* pyramidBlur = nullptr;
    float* blurScratchA = nullptr;
    float* blurScratchB = nullptr;
    float sigma[kPresplitBandCount] = {-1.0f, -1.0f, -1.0f, -1.0f, -1.0f, -1.0f};
    size_t scalarBytes = 0;
    size_t pyramidScalarBytes = 0;
};

struct EqCache {
    float* eqBands = nullptr;
};

ResCache gRes;
PresplitBlurCache gBlur;
EqCache gEq;

std::atomic<bool> g_loggedFreqEqNilArgs{false};
std::atomic<bool> g_loggedFreqEqResources{false};
std::atomic<bool> g_loggedFreqEqBody{false};

void logFreqEqOnce(std::atomic<bool>& flag, const char* message) {
    if (flag.exchange(true))
        return;
    LSPOpenTextureLog::writeErrorLine(message);
}

void fqReleaseBlurCache() {
    for (int i = 0; i < kPresplitBandCount; ++i) {
        if (gBlur.bandBlur[i]) {
            cudaFree(gBlur.bandBlur[i]);
            gBlur.bandBlur[i] = nullptr;
        }
        gBlur.sigma[i] = -1.0f;
    }
    if (gBlur.pyramidSrc) {
        cudaFree(gBlur.pyramidSrc);
        gBlur.pyramidSrc = nullptr;
    }
    if (gBlur.pyramidSrc2) {
        cudaFree(gBlur.pyramidSrc2);
        gBlur.pyramidSrc2 = nullptr;
    }
    if (gBlur.pyramidBlur) {
        cudaFree(gBlur.pyramidBlur);
        gBlur.pyramidBlur = nullptr;
    }
    if (gBlur.blurScratchA) {
        cudaFree(gBlur.blurScratchA);
        gBlur.blurScratchA = nullptr;
    }
    if (gBlur.blurScratchB) {
        cudaFree(gBlur.blurScratchB);
        gBlur.blurScratchB = nullptr;
    }
    gBlur.width = 0;
    gBlur.height = 0;
    gBlur.scalarBytes = 0;
    gBlur.pyramidScalarBytes = 0;
}

void fqReleaseResources() {
    if (gRes.originalLinear) {
        cudaFree(gRes.originalLinear);
        gRes.originalLinear = nullptr;
    }
    if (gRes.lSource) {
        cudaFree(gRes.lSource);
        gRes.lSource = nullptr;
    }
    if (gRes.accDetail) {
        cudaFree(gRes.accDetail);
        gRes.accDetail = nullptr;
    }
    gRes.width = 0;
    gRes.height = 0;
    gRes.packedBytes = 0;
    fqReleaseBlurCache();
}

bool fqEnsureEqCache() {
    if (!gEq.eqBands) {
        if (cudaMalloc(reinterpret_cast<void**>(&gEq.eqBands), sizeof(float) * 6) != cudaSuccess)
            return false;
    }
    return true;
}

bool fqEnsureResources(int width, int height) {
    if (width < 1 || height < 1)
        return false;
    const size_t packedBytes = static_cast<size_t>(width) * static_cast<size_t>(height) * 4u * sizeof(float);
    const size_t scalarBytes = static_cast<size_t>(width) * static_cast<size_t>(height) * sizeof(float);
    if (gRes.originalLinear && gRes.lSource && gRes.width == width && gRes.height == height && gRes.packedBytes == packedBytes)
        return true;
    fqReleaseResources();
    gRes.width = width;
    gRes.height = height;
    gRes.packedBytes = packedBytes;
    if (cudaMalloc(reinterpret_cast<void**>(&gRes.originalLinear), packedBytes) != cudaSuccess)
        return false;
    if (cudaMalloc(reinterpret_cast<void**>(&gRes.lSource), scalarBytes) != cudaSuccess)
        return false;
    if (cudaMalloc(reinterpret_cast<void**>(&gRes.accDetail), scalarBytes) != cudaSuccess)
        return false;
    return gRes.originalLinear != nullptr && gRes.lSource != nullptr && gRes.accDetail != nullptr;
}

int fqPyramidDim(int full, int levels) {
    int v = full;
    for (int i = 0; i < levels; ++i)
        v = (v + 1) / 2;
    return v < 1 ? 1 : v;
}

bool fqEnsurePresplitBlur(int width, int height, const float sigmas[kPresplitBandCount]) {
    const size_t scalarBytes = openTextureBlurScalarBytes(width, height);
    const int pw = fqPyramidDim(width, 1);
    const int ph = fqPyramidDim(height, 1);
    const size_t pyramidScalarBytes = static_cast<size_t>(pw) * static_cast<size_t>(ph) * sizeof(float);

    const bool sizeOk = gBlur.width == width && gBlur.height == height && gBlur.bandBlur[0] != nullptr;
    if (!sizeOk) {
        fqReleaseBlurCache();
        gBlur.width = width;
        gBlur.height = height;
        gBlur.scalarBytes = scalarBytes;
        gBlur.pyramidScalarBytes = pyramidScalarBytes;
        for (int i = 0; i < kPresplitBandCount; ++i) {
            if (cudaMalloc(reinterpret_cast<void**>(&gBlur.bandBlur[i]), scalarBytes) != cudaSuccess)
                return false;
        }
        if (cudaMalloc(reinterpret_cast<void**>(&gBlur.pyramidSrc), pyramidScalarBytes) != cudaSuccess)
            return false;
        const size_t quarterBytes =
            static_cast<size_t>(fqPyramidDim(width, 2)) * static_cast<size_t>(fqPyramidDim(height, 2)) * sizeof(float);
        if (cudaMalloc(reinterpret_cast<void**>(&gBlur.pyramidSrc2), quarterBytes) != cudaSuccess)
            return false;
        if (cudaMalloc(reinterpret_cast<void**>(&gBlur.pyramidBlur), pyramidScalarBytes) != cudaSuccess)
            return false;
        if (cudaMalloc(reinterpret_cast<void**>(&gBlur.blurScratchA), scalarBytes) != cudaSuccess)
            return false;
        if (cudaMalloc(reinterpret_cast<void**>(&gBlur.blurScratchB), scalarBytes) != cudaSuccess)
            return false;
    }

    for (int i = 0; i < kPresplitBandCount; ++i)
        gBlur.sigma[i] = sigmas[i] < 0.1f ? 0.1f : sigmas[i];
    return true;
}

void fqComputeBandSigmas(int width, int height, float baseBlur, float outSigmas[kPresplitBandCount]) {
    const float srcDiag = std::hypot(static_cast<float>(width), static_cast<float>(height));
    const float resScale =
        (srcDiag > 1.0e-6f && kOpenTextureReferenceDiagonalPixels > 1.0e-6f) ? (srcDiag / kOpenTextureReferenceDiagonalPixels) : 1.0f;
    float blur = (0.4f * resScale) * baseBlur;
    for (int i = 0; i < kPresplitBandCount; ++i) {
        outSigmas[i] = blur < 0.1f ? 0.1f : blur;
        blur *= 2.0f;
    }
}

PyramidPlan fqPyramidPlan(float sigma, int bandIndex) {
    const OpenTextureMtfPyramidPlan shared = openTextureMtfPyramidPlan(sigma, bandIndex);
    PyramidPlan plan{};
    plan.levels = shared.levels;
    plan.mpsSigma = shared.mpsSigma;
    return plan;
}

void fqComputeBlurNeeded(const float eq[6], int displaySwitch, bool needBlur[kPresplitBandCount]) {
    for (int i = 0; i < kPresplitBandCount; ++i)
        needBlur[i] = false;

    if (displaySwitch >= 1 && displaySwitch <= 6) {
        const int band = displaySwitch - 1;
        needBlur[band] = true;
        if (band > 0)
            needBlur[band - 1] = true;
        return;
    }
    if (displaySwitch == 7) {
        for (int i = 0; i < kPresplitBandCount; ++i)
            needBlur[i] = true;
        return;
    }

    needBlur[5] = true;
    for (int i = 0; i < kPresplitBandCount; ++i) {
        if (fabsf(eq[i] - 1.0f) <= kEqIdentityEps)
            continue;
        needBlur[i] = true;
        if (i > 0)
            needBlur[i - 1] = true;
    }
}

bool fqDownsampleLevel(int levels, float* dst, cudaStream_t stream) {
    int pw = gBlur.width;
    int ph = gBlur.height;
    for (int i = 0; i < levels; ++i) {
        pw = std::max((pw + 1) / 2, 1);
        ph = std::max((ph + 1) / 2, 1);
    }
    return otLaunchBilinearDownscaleScalar(gBlur.width, gBlur.height, pw, ph, gRes.lSource, dst, stream) == cudaSuccess;
}

bool fqEncodePresplitBlurs(const float eq[6], int displaySwitch, cudaStream_t stream) {
    bool needBlur[kPresplitBandCount];
    fqComputeBlurNeeded(eq, displaySwitch, needBlur);

    int bandLevel[kPresplitBandCount];
    float bandMpsSigma[kPresplitBandCount];
    bool wantLevel[3] = {false, false, false};
    bool any = false;
    for (int i = 0; i < kPresplitBandCount; ++i) {
        bandLevel[i] = 1;
        bandMpsSigma[i] = 0.0f;
        if (!needBlur[i])
            continue;
        const PyramidPlan plan = fqPyramidPlan(gBlur.sigma[i], i);
        int levels = plan.levels;
        if (levels < 1)
            levels = 1;
        else if (levels > 2)
            levels = 2;
        bandLevel[i] = levels;
        bandMpsSigma[i] = plan.mpsSigma;
        wantLevel[levels] = true;
        any = true;
    }
    if (!any && displaySwitch == 0) {
        const PyramidPlan plan = fqPyramidPlan(gBlur.sigma[5], 5);
        int levels = plan.levels;
        if (levels < 1)
            levels = 1;
        else if (levels > 2)
            levels = 2;
        needBlur[5] = true;
        bandLevel[5] = levels;
        bandMpsSigma[5] = plan.mpsSigma;
        wantLevel[levels] = true;
        any = true;
    }
    if (!any)
        return true;

    // une seule fois
    if (wantLevel[1] && !fqDownsampleLevel(1, gBlur.pyramidSrc, stream))
        return false;
    if (wantLevel[2] && !fqDownsampleLevel(2, gBlur.pyramidSrc2, stream))
        return false;

    for (int i = 0; i < kPresplitBandCount; ++i) {
        if (!needBlur[i])
            continue;
        float* src = bandLevel[i] == 2 ? gBlur.pyramidSrc2 : gBlur.pyramidSrc;
        if (blurScalar_VanVlietFromPrepared(gBlur.bandBlur[i], src, gBlur.width, gBlur.height, bandMpsSigma[i], bandLevel[i],
                                            gBlur.blurScratchA, gBlur.blurScratchB, gBlur.pyramidBlur, stream) != cudaSuccess)
            return false;
    }
    return true;
}

bool fqEncodeFreqEQBody(
    float* srcStrided,
    float* dstStrided,
    const LSPOpenTextureHostParams& io,
    const float p_EQ[8],
    int p_Switch,
    int p_Grey,
    float lumaBlend,
    bool* outSkipUnpack,
    cudaStream_t stream) {
    if (outSkipUnpack)
        *outSkipUnpack = false;

    const int width = io.width;
    const int height = io.height;
    float bandSigmas[kPresplitBandCount];
    fqComputeBandSigmas(width, height, p_EQ[6], bandSigmas);

    if (LSPOpenTextureFreqEQ_IsIdentity(p_EQ, p_Switch, 1.0f)) {
        const size_t rowBytes = static_cast<size_t>(io.dstRowFloats) * sizeof(float);
        const size_t packedRowBytes = static_cast<size_t>(width) * 4u * sizeof(float);
        if (srcStrided == dstStrided && rowBytes == packedRowBytes)
            return true;
        if (rowBytes == packedRowBytes) {
            return cudaMemcpyAsync(dstStrided, srcStrided, static_cast<size_t>(height) * packedRowBytes, cudaMemcpyDeviceToDevice, stream) ==
                   cudaSuccess;
        }
        for (int y = 0; y < height; ++y) {
            const float* so = srcStrided + static_cast<size_t>(y) * io.dstRowFloats;
            float* ddo = dstStrided + static_cast<size_t>(y) * io.dstRowFloats;
            if (cudaMemcpyAsync(ddo, so, packedRowBytes, cudaMemcpyDeviceToDevice, stream) != cudaSuccess)
                return false;
        }
        return true;
    }

    if (!fqEnsurePresplitBlur(width, height, bandSigmas))
        return false;
    if (!fqEnsureEqCache())
        return false;

    float eqBands[6];
    std::memcpy(eqBands, p_EQ, sizeof(float) * 6);
    if (cudaMemcpyAsync(gEq.eqBands, eqBands, sizeof(eqBands), cudaMemcpyHostToDevice, stream) != cudaSuccess)
        return false;

    const OpenTextureCudaParams& p = io;

    if (otLaunchDecodeStridedRgbToL(srcStrided, gRes.originalLinear, gRes.lSource, p, stream) != cudaSuccess)
        return false;

    if (!fqEncodePresplitBlurs(eqBands, p_Switch, stream))
        return false;

    const bool previewBand = (p_Switch >= 1 && p_Switch <= 6);
    const bool previewAccum = (p_Switch == 7);

    if (previewBand) {
        const int band = p_Switch - 1;
        const float eq = p_EQ[band];
        const int grey = p_Grey ? 1 : 0;
        if (otLaunchPreviewBandPresplitStrided(gRes.lSource, gBlur.bandBlur[0], gBlur.bandBlur[1], gBlur.bandBlur[2], gBlur.bandBlur[3],
                                               gBlur.bandBlur[4], gBlur.bandBlur[5], dstStrided, p, eq, band, grey, stream) !=
            cudaSuccess)
            return false;
        if (outSkipUnpack)
            *outSkipUnpack = true;
        return true;
    }

    if (previewAccum) {
        if (otLaunchPresplitAccumDetail(gRes.lSource, gBlur.bandBlur[0], gBlur.bandBlur[1], gBlur.bandBlur[2], gBlur.bandBlur[3],
                                        gBlur.bandBlur[4], gBlur.bandBlur[5], gRes.accDetail, width, height, gEq.eqBands, stream) !=
            cudaSuccess)
            return false;
        const int grey = p_Grey ? 1 : 0;
        if (otLaunchPreviewAccumStrided(gRes.accDetail, dstStrided, p, grey, stream) != cudaSuccess)
            return false;
        if (outSkipUnpack)
            *outSkipUnpack = true;
        return true;
    }

    const float blendOrig = p_EQ[7];
    if (otLaunchPresplitFusedStrided(gRes.lSource, gBlur.bandBlur[0], gBlur.bandBlur[1], gBlur.bandBlur[2], gBlur.bandBlur[3],
                                     gBlur.bandBlur[4], gBlur.bandBlur[5], gRes.originalLinear, dstStrided, p, gEq.eqBands, blendOrig,
                                     lumaBlend, stream) != cudaSuccess)
        return false;
    return true;
}

}

bool LSPOpenTextureFreqEQ_IsIdentity(const float eq[8], int displaySwitch, float globalBlend) {
    return openTextureMtfIsIdentity(eq, displaySwitch, globalBlend);
}

bool LSPOpenTextureFreqEQ_EncodeCuda(
    float* srcStrided,
    float* dstStrided,
    const LSPOpenTextureHostParams& io,
    const float eq[8],
    int displaySwitch,
    int grey,
    float lumaBlend,
    bool* outSkipUnpack,
    void* cudaStream) {
    if (!srcStrided || !dstStrided) {
        logFreqEqOnce(g_loggedFreqEqNilArgs, "cuda_freqeq_nil_src_or_dst");
        return false;
    }
    if (io.width < 1 || io.height < 1) {
        logFreqEqOnce(g_loggedFreqEqNilArgs, "cuda_freqeq_invalid_dimensions");
        return false;
    }

    cudaStream_t stream = cudaStream ? reinterpret_cast<cudaStream_t>(cudaStream) : cudaStreamLegacy;

    float eqCopy[8];
    std::memcpy(eqCopy, eq, sizeof(eqCopy));

    {
        std::lock_guard<std::mutex> lock(gFqCacheMutex);
        if (!fqEnsureResources(io.width, io.height)) {
            logFreqEqOnce(g_loggedFreqEqResources, "cuda_freqeq_ensure_buffers_failed");
            return false;
        }
    }

    if (!fqEncodeFreqEQBody(srcStrided, dstStrided, io, eqCopy, displaySwitch, grey, lumaBlend, outSkipUnpack, stream)) {
        logFreqEqOnce(g_loggedFreqEqBody, "cuda_freqeq_encode_body_failed");
        return false;
    }
    return true;
}
