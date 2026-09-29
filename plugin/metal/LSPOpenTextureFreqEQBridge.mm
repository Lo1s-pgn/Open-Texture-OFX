#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

#include "LSPOpenTextureFreqEQBridge.h"
#include "../core/LSPOpenTextureMtfIdentity.h"
#include "../core/LSPOpenTextureMtfPyramid.h"
#include "../core/LSPOpenTextureProfile.h"
#include "../core/LSPOpenTextureHostParams.h"
#include "LSPOpenTextureConstants.h"
#include "LSPOpenTextureLog.h"

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <mutex>
#include <sstream>
#include <string>

static std::atomic<bool> g_loggedFreqEqNilArgs{false};
static std::atomic<bool> g_loggedFreqEqDeviceNil{false};
static std::atomic<bool> g_loggedFreqEqKernels{false};
static std::atomic<bool> g_loggedFreqEqResources{false};
static std::atomic<bool> g_loggedFreqEqBody{false};
static std::atomic<bool> g_loggedFreqEqKernelCompile{false};
static std::atomic<bool> g_loggedFreqEqMps{false};

static void logFreqEqOnce(std::atomic<bool>& flag, const char* message) {
    if (flag.exchange(true))
        return;
    LSPOpenTextureLog::writeErrorLine(message);
}

static void logFreqEqKernelErrorOnce(NSError* err, const char* prefix) {
    if (g_loggedFreqEqKernelCompile.exchange(true))
        return;
    std::ostringstream o;
    o << prefix;
    if (err != nil && err.localizedDescription != nil && err.localizedDescription.UTF8String != nullptr)
        o << " " << err.localizedDescription.UTF8String;
    LSPOpenTextureLog::writeErrorLine(o.str());
}

@interface LSPOpenTextureFreqEQBundleAnchor : NSObject
@end
@implementation LSPOpenTextureFreqEQBundleAnchor
@end

namespace {

std::mutex gFqCacheMutex;

static constexpr int kPresplitBandCount = 6;
static constexpr float kEqIdentityEps = 1.0e-5f;

static std::string fqMetallibPathFromBundle(void) {
    NSBundle* bundle = [NSBundle bundleForClass:[LSPOpenTextureFreqEQBundleAnchor class]];
    if (bundle == nil)
        return {};
    NSString* path = [bundle pathForResource:@"LSPOpenTextureMetal" ofType:@"metallib"];
    if (path == nil || path.length == 0)
        return {};
    return std::string([path fileSystemRepresentation]);
}

static std::string fqModuleDirectory(void) {
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void*>(&fqMetallibPathFromBundle), &info) == 0 || info.dli_fname == nullptr)
        return std::string();
    std::filesystem::path p(info.dli_fname);
    return p.parent_path().string();
}

static std::string fqMetallibPath(void) {
    const std::string fromBundle = fqMetallibPathFromBundle();
    if (!fromBundle.empty()) {
        NSString* nsPath = [NSString stringWithUTF8String:fromBundle.c_str()];
        if (nsPath != nil && [[NSFileManager defaultManager] fileExistsAtPath:nsPath])
            return fromBundle;
    }
    const std::filesystem::path macosDir(fqModuleDirectory());
    if (macosDir.empty())
        return std::string();
    return (macosDir.parent_path() / "Resources" / "LSPOpenTextureMetal.metallib").string();
}

struct RgbKernelPSOs {
    id<MTLComputePipelineState> decodeStridedRgbToL = nil;
    id<MTLComputePipelineState> presplitAccumDetail = nil;
    id<MTLComputePipelineState> presplitFusedStrided = nil;
    id<MTLComputePipelineState> previewBandStrided = nil;
    id<MTLComputePipelineState> previewAccumStrided = nil;
};

struct ResCache {
    id<MTLDevice> device = nil;
    NSUInteger width = 0;
    NSUInteger height = 0;
    id<MTLTexture> originalLinear = nil;
    id<MTLTexture> accDetail = nil;
};

struct PyramidPlan {
    int levels = 0;
    float mpsSigma = 0.0f;
};

struct PresplitMpsCache {
    id<MTLDevice> device = nil;
    NSUInteger width = 0;
    NSUInteger height = 0;
    id<MTLTexture> lSource = nil;
    id<MTLTexture> bandBlur[kPresplitBandCount] = {nil};
    id<MTLTexture> pyramidSrc = nil;
    id<MTLTexture> pyramidBlur = nil;
    MPSImageGaussianBlur* blur[kPresplitBandCount] = {nil};
    MPSImageBilinearScale* bilinearScale = nil;
    float sigma[kPresplitBandCount] = {-1.0f, -1.0f, -1.0f, -1.0f, -1.0f, -1.0f};
};

static constexpr int kPyramidBlurOpSlots = 6;
struct PyramidBlurOpSlot {
    float sigma = -1.0f;
    MPSImageGaussianBlur* op = nil;
};
PyramidBlurOpSlot gPyramidBlurOps[kPyramidBlurOpSlots];

RgbKernelPSOs gKernels;
ResCache gRes;
PresplitMpsCache gMps;
id<MTLLibrary> gRgbLibrary = nil;
id<MTLDevice> gRgbDevice = nil;

static void fqReleaseIfNonNil(id obj) {
    if (obj != nil)
        [obj release];
}

static void fqRgbReleaseKernels(void) {
    fqReleaseIfNonNil(gKernels.decodeStridedRgbToL);
    fqReleaseIfNonNil(gKernels.presplitAccumDetail);
    fqReleaseIfNonNil(gKernels.presplitFusedStrided);
    fqReleaseIfNonNil(gKernels.previewBandStrided);
    fqReleaseIfNonNil(gKernels.previewAccumStrided);
    fqReleaseIfNonNil(gRgbLibrary);
    gRgbLibrary = nil;
    gKernels = RgbKernelPSOs{};
    gRgbDevice = nil;
}

static void fqReleasePyramidBlurOps(void) {
    for (int i = 0; i < kPyramidBlurOpSlots; ++i) {
        fqReleaseIfNonNil(gPyramidBlurOps[i].op);
        gPyramidBlurOps[i].op = nil;
        gPyramidBlurOps[i].sigma = -1.0f;
    }
}

static void fqRgbReleaseMpsCache(void) {
    fqReleaseIfNonNil(gMps.lSource);
    gMps.lSource = nil;
    fqReleaseIfNonNil(gMps.pyramidSrc);
    fqReleaseIfNonNil(gMps.pyramidBlur);
    gMps.pyramidSrc = nil;
    gMps.pyramidBlur = nil;
    fqReleaseIfNonNil(gMps.bilinearScale);
    gMps.bilinearScale = nil;
    fqReleasePyramidBlurOps();
    for (int i = 0; i < kPresplitBandCount; ++i) {
        fqReleaseIfNonNil(gMps.bandBlur[i]);
        fqReleaseIfNonNil(gMps.blur[i]);
        gMps.bandBlur[i] = nil;
        gMps.blur[i] = nil;
        gMps.sigma[i] = -1.0f;
    }
    gMps.width = 0;
    gMps.height = 0;
    gMps.device = nil;
}

static void fqRgbReleaseResources(void) {
    fqReleaseIfNonNil(gRes.originalLinear);
    fqReleaseIfNonNil(gRes.accDetail);
    gRes.originalLinear = nil;
    gRes.accDetail = nil;
    gRes.width = 0;
    gRes.height = 0;
    gRes.device = nil;
    fqRgbReleaseMpsCache();
}

static id<MTLTexture> makeRGBA32FPrivate(id<MTLDevice> device, NSUInteger w, NSUInteger h) {
    if (device == nil || w < 1 || h < 1)
        return nil;
    MTLTextureDescriptor* d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModePrivate;
    return [device newTextureWithDescriptor:d];
}

static id<MTLTexture> makeR32FPrivate(id<MTLDevice> device, NSUInteger w, NSUInteger h) {
    if (device == nil || w < 1 || h < 1)
        return nil;
    MTLTextureDescriptor* d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModePrivate;
    return [device newTextureWithDescriptor:d];
}

static bool fqRgbKernelsAllValid(void) {
    return gRgbDevice != nil && gKernels.decodeStridedRgbToL != nil && gKernels.presplitAccumDetail != nil &&
           gKernels.presplitFusedStrided != nil && gKernels.previewBandStrided != nil && gKernels.previewAccumStrided != nil;
}

static bool fqEnsureRgbKernels(id<MTLDevice> device) {
    if (device == nil)
        return false;
    if (gRgbDevice == device && fqRgbKernelsAllValid())
        return true;
    fqRgbReleaseKernels();
    gRgbDevice = device;
    const std::string libPathStr = fqMetallibPath();
    if (libPathStr.empty()) {
        fqRgbReleaseKernels();
        logFreqEqOnce(g_loggedFreqEqKernelCompile, "metal_freqeq_metallib_path_empty");
        return false;
    }
    NSString* libPath = [NSString stringWithUTF8String:libPathStr.c_str()];
    if (libPath == nil) {
        fqRgbReleaseKernels();
        logFreqEqOnce(g_loggedFreqEqKernelCompile, "metal_freqeq_metallib_nsstring_failed");
        return false;
    }
    NSError* err = nil;
    gRgbLibrary = [device newLibraryWithURL:[NSURL fileURLWithPath:libPath] error:&err];
    if (gRgbLibrary == nil) {
        fqRgbReleaseKernels();
        logFreqEqKernelErrorOnce(err, "metal_freqeq_metallib_load_failed");
        return false;
    }
    auto mk = [&](const char* name) -> id<MTLComputePipelineState> {
        id<MTLFunction> fn = [gRgbLibrary newFunctionWithName:[NSString stringWithUTF8String:name]];
        if (fn == nil)
            return nil;
        id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&err];
        [fn release];
        return pso;
    };
    gKernels.decodeStridedRgbToL = mk("k_decode_strided_rgb_to_l_tex");
    gKernels.presplitAccumDetail = mk("k_presplit_accum_detail_tex");
    gKernels.presplitFusedStrided = mk("k_presplit_fused_strided_tex");
    gKernels.previewBandStrided = mk("k_preview_band_presplit_strided");
    gKernels.previewAccumStrided = mk("k_preview_accum_strided");
    if (!fqRgbKernelsAllValid()) {
        fqRgbReleaseKernels();
        logFreqEqKernelErrorOnce(err, "metal_freqeq_rgb_pipeline_build_failed");
        return false;
    }
    [gRgbLibrary release];
    gRgbLibrary = nil;
    return true;
}

static bool fqEnsureResources(id<MTLDevice> device, int width, int height) {
    if (device == nil || width < 1 || height < 1)
        return false;
    const NSUInteger w = (NSUInteger)width;
    const NSUInteger h = (NSUInteger)height;
    if (gRes.device == device && gRes.width == w && gRes.height == h && gRes.originalLinear != nil && gRes.accDetail != nil)
        return true;
    fqRgbReleaseResources();
    gRes.device = device;
    gRes.width = w;
    gRes.height = h;
    gRes.originalLinear = makeRGBA32FPrivate(device, w, h);
    gRes.accDetail = makeR32FPrivate(device, w, h);
    return gRes.originalLinear != nil && gRes.accDetail != nil;
}

static NSUInteger fqPyramidDim(NSUInteger full, int levels) {
    NSUInteger v = full;
    for (int i = 0; i < levels; ++i)
        v = (v + 1u) / 2u;
    return std::max<NSUInteger>(v, 1u);
}

static bool fqEnsureMpsPresplit(id<MTLDevice> device, int width, int height, const float sigmas[kPresplitBandCount]) {
    if (device == nil || width < 1 || height < 1)
        return false;
    const NSUInteger w = (NSUInteger)width;
    const NSUInteger h = (NSUInteger)height;
    const bool sizeOk = gMps.device == device && gMps.width == w && gMps.height == h;

    if (!sizeOk) {
        fqRgbReleaseMpsCache();
        gMps.device = device;
        gMps.width = w;
        gMps.height = h;
        gMps.lSource = makeR32FPrivate(device, w, h);
        for (int i = 0; i < kPresplitBandCount; ++i)
            gMps.bandBlur[i] = makeR32FPrivate(device, w, h);
        gMps.pyramidSrc = makeR32FPrivate(device, fqPyramidDim(w, 1), fqPyramidDim(h, 1));
        gMps.pyramidBlur = makeR32FPrivate(device, fqPyramidDim(w, 1), fqPyramidDim(h, 1));
        gMps.bilinearScale = [[MPSImageBilinearScale alloc] initWithDevice:device];
        if (gMps.lSource == nil || gMps.bilinearScale == nil)
            return false;
        for (int i = 0; i < kPresplitBandCount; ++i) {
            if (gMps.bandBlur[i] == nil)
                return false;
        }
        if (gMps.pyramidSrc == nil || gMps.pyramidBlur == nil)
            return false;
    }

    for (int i = 0; i < kPresplitBandCount; ++i) {
        const float sigma = sigmas[i] < 0.1f ? 0.1f : sigmas[i];
        if (fabsf(gMps.sigma[i] - sigma) <= 1.0e-4f && gMps.blur[i] != nil)
            continue;
        fqReleaseIfNonNil(gMps.blur[i]);
        gMps.blur[i] = [[MPSImageGaussianBlur alloc] initWithDevice:device sigma:sigma];
        // mps default pads w/ zero; lab bands ring at edges unless you clamp
        gMps.blur[i].edgeMode = MPSImageEdgeModeClamp;
        gMps.sigma[i] = sigma;
        if (gMps.blur[i] == nil)
            return false;
    }
    return true;
}

static void dispatch2D(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> pso, int width, int height) {
    [enc setComputePipelineState:pso];
    const NSUInteger maxThreads = pso.maxTotalThreadsPerThreadgroup;
    const NSUInteger tew = pso.threadExecutionWidth;
    NSUInteger tx = tew > 0 ? tew : 16;
    if (tx > maxThreads)
        tx = maxThreads;
    NSUInteger ty = maxThreads / tx;
    if (ty == 0)
        ty = 1;
    if (ty > 16)
        ty = 16;
    [enc dispatchThreads:MTLSizeMake((NSUInteger)width, (NSUInteger)height, 1) threadsPerThreadgroup:MTLSizeMake(tx, ty, 1)];
}

static void fqBindPresplitBlurTextures(id<MTLComputeCommandEncoder> enc, int baseIndex) {
    for (int i = 0; i < kPresplitBandCount; ++i)
        [enc setTexture:gMps.bandBlur[i] atIndex:baseIndex + i];
}

static inline float mpsSigmaFromBlurAmount(float blurAmount) {
    return blurAmount < 0.1f ? 0.1f : blurAmount;
}

static void fqComputeBandSigmas(int width, int height, float baseBlur, float outSigmas[kPresplitBandCount]) {
    const float srcDiag = std::hypot((float)width, (float)height);
    const float resScale =
        (srcDiag > 1.0e-6f && kOpenTextureReferenceDiagonalPixels > 1.0e-6f)
            ? (srcDiag / kOpenTextureReferenceDiagonalPixels)
            : 1.0f;
    float blur = (0.4f * resScale) * baseBlur;
    for (int i = 0; i < kPresplitBandCount; ++i) {
        outSigmas[i] = mpsSigmaFromBlurAmount(blur);
        blur *= 2.0f;
    }
}

static PyramidPlan fqPyramidPlan(float sigma, int bandIndex) {
    const OpenTextureMtfPyramidPlan shared = openTextureMtfPyramidPlan(sigma, bandIndex);
    PyramidPlan plan{};
    plan.levels = shared.levels;
    plan.mpsSigma = shared.mpsSigma;
    return plan;
}

static MPSImageGaussianBlur* fqGetPyramidBlurOp(id<MTLDevice> device, float sigma) {
    for (int i = 0; i < kPyramidBlurOpSlots; ++i) {
        if (gPyramidBlurOps[i].op != nil && fabsf(gPyramidBlurOps[i].sigma - sigma) <= 1.0e-4f)
            return gPyramidBlurOps[i].op;
    }
    int slot = 0;
    for (int i = 0; i < kPyramidBlurOpSlots; ++i) {
        if (gPyramidBlurOps[i].op == nil) {
            slot = i;
            break;
        }
    }
    fqReleaseIfNonNil(gPyramidBlurOps[slot].op);
    gPyramidBlurOps[slot].op = [[MPSImageGaussianBlur alloc] initWithDevice:device sigma:sigma];
    gPyramidBlurOps[slot].op.edgeMode = MPSImageEdgeModeClamp;
    gPyramidBlurOps[slot].sigma = sigma;
    return gPyramidBlurOps[slot].op;
}

static void fqComputeBlurNeeded(const float eq[6], int displaySwitch, bool needBlur[kPresplitBandCount]) {
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

static bool fqEncodeSingleBandBlur(id<MTLCommandBuffer> cmd, id<MTLDevice> device, int bandIndex, float sigma) {
    const PyramidPlan plan = fqPyramidPlan(sigma, bandIndex);
    MPSImageGaussianBlur* pyramidOp = fqGetPyramidBlurOp(device, plan.mpsSigma);
    if (pyramidOp == nil)
        return false;
    const NSUInteger pw = fqPyramidDim(gMps.width, plan.levels);
    const NSUInteger ph = fqPyramidDim(gMps.height, plan.levels);
    if (gMps.pyramidSrc.width != pw || gMps.pyramidSrc.height != ph) {
        fqReleaseIfNonNil(gMps.pyramidSrc);
        fqReleaseIfNonNil(gMps.pyramidBlur);
        gMps.pyramidSrc = makeR32FPrivate(device, pw, ph);
        gMps.pyramidBlur = makeR32FPrivate(device, pw, ph);
        if (gMps.pyramidSrc == nil || gMps.pyramidBlur == nil)
            return false;
    }
    [gMps.bilinearScale encodeToCommandBuffer:cmd sourceTexture:gMps.lSource destinationTexture:gMps.pyramidSrc];
    [pyramidOp encodeToCommandBuffer:cmd sourceTexture:gMps.pyramidSrc destinationTexture:gMps.pyramidBlur];
    [gMps.bilinearScale encodeToCommandBuffer:cmd sourceTexture:gMps.pyramidBlur destinationTexture:gMps.bandBlur[bandIndex]];
    return true;
}

static bool fqEncodePresplitBlurs(id<MTLCommandBuffer> cmd, const float eq[6], int displaySwitch) {
    if (cmd == nil || gMps.lSource == nil)
        return false;
    bool needBlur[kPresplitBandCount];
    fqComputeBlurNeeded(eq, displaySwitch, needBlur);

    bool any = false;
    for (int i = 0; i < kPresplitBandCount; ++i) {
        if (!needBlur[i])
            continue;
        any = true;
        if (!fqEncodeSingleBandBlur(cmd, cmd.device, i, gMps.sigma[i]))
            return false;
    }
    if (!any && displaySwitch == 0) {
        if (!fqEncodeSingleBandBlur(cmd, cmd.device, 5, gMps.sigma[5]))
            return false;
    }
    return true;
}

static bool fqEncodeFreqEQBody(
    id<MTLCommandBuffer> cmd,
    id<MTLBuffer> srcStrided,
    size_t srcOffset,
    id<MTLBuffer> dstStrided,
    size_t dstOffset,
    const LSPOpenTextureHostParams& io,
    const float p_EQ[8],
    int p_Switch,
    int p_Grey,
    float lumaBlend,
    bool* outSkipUnpack) {
    if (outSkipUnpack != nullptr)
        *outSkipUnpack = false;

    const int width = io.width;
    const int height = io.height;
    float bandSigmas[kPresplitBandCount];
    fqComputeBandSigmas(width, height, p_EQ[6], bandSigmas);

    if (LSPOpenTextureFreqEQ_IsIdentity(p_EQ, p_Switch, 1.0f)) {
        const size_t rowBytes = static_cast<size_t>(io.dstRowFloats) * sizeof(float);
        const size_t packedRowBytes = static_cast<size_t>(width) * 4u * sizeof(float);
        const size_t bytes = static_cast<size_t>(height) * packedRowBytes;
        if (srcStrided.length < srcOffset + bytes || dstStrided.length < dstOffset + bytes)
            return false;
        if (srcOffset == dstOffset && srcStrided == dstStrided && rowBytes == packedRowBytes)
            return true;
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        if (blit == nil)
            return false;
        if (rowBytes == packedRowBytes) {
            [blit copyFromBuffer:srcStrided sourceOffset:srcOffset toBuffer:dstStrided destinationOffset:dstOffset size:bytes];
        } else {
            for (int y = 0; y < height; ++y) {
                const size_t so = srcOffset + static_cast<size_t>(y) * rowBytes;
                const size_t ddo = dstOffset + static_cast<size_t>(y) * rowBytes;
                [blit copyFromBuffer:srcStrided sourceOffset:so toBuffer:dstStrided destinationOffset:ddo size:packedRowBytes];
            }
        }
        [blit endEncoding];
        return true;
    }

    id<MTLDevice> device = cmd.device;
    if (!fqEnsureMpsPresplit(device, width, height, bandSigmas)) {
        logFreqEqOnce(g_loggedFreqEqMps, "metal_freqeq_presplit_mps_cache_failed");
        return false;
    }

    float eqBands[6];
    std::memcpy(eqBands, p_EQ, sizeof(float) * 6);

    {
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        if (enc == nil)
            return false;
        [enc setComputePipelineState:gKernels.decodeStridedRgbToL];
        [enc setBuffer:srcStrided offset:srcOffset atIndex:0];
        [enc setTexture:gRes.originalLinear atIndex:0];
        [enc setTexture:gMps.lSource atIndex:1];
        [enc setBytes:&io length:sizeof(io) atIndex:2];
        dispatch2D(enc, gKernels.decodeStridedRgbToL, width, height);
        [enc endEncoding];
    }

    if (!fqEncodePresplitBlurs(cmd, eqBands, p_Switch))
        return false;

    const bool previewBand = (p_Switch >= 1 && p_Switch <= 6);
    const bool previewAccum = (p_Switch == 7);

    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;

    if (previewBand) {
        const int band = p_Switch - 1;
        float eq = p_EQ[band];
        int grey = p_Grey ? 1 : 0;
        [enc setComputePipelineState:gKernels.previewBandStrided];
        [enc setTexture:gMps.lSource atIndex:0];
        fqBindPresplitBlurTextures(enc, 1);
        [enc setBuffer:dstStrided offset:dstOffset atIndex:0];
        [enc setBytes:&io length:sizeof(io) atIndex:1];
        [enc setBytes:&eq length:sizeof(float) atIndex:2];
        [enc setBytes:&band length:sizeof(int) atIndex:3];
        [enc setBytes:&grey length:sizeof(int) atIndex:4];
        dispatch2D(enc, gKernels.previewBandStrided, width, height);
        [enc endEncoding];
        if (outSkipUnpack != nullptr)
            *outSkipUnpack = true;
        return true;
    }

    if (previewAccum) {
        [enc setComputePipelineState:gKernels.presplitAccumDetail];
        [enc setTexture:gMps.lSource atIndex:0];
        fqBindPresplitBlurTextures(enc, 1);
        [enc setTexture:gRes.accDetail atIndex:7];
        int wi = width;
        int hi = height;
        [enc setBytes:&wi length:sizeof(int) atIndex:2];
        [enc setBytes:&hi length:sizeof(int) atIndex:3];
        [enc setBytes:eqBands length:sizeof(eqBands) atIndex:4];
        dispatch2D(enc, gKernels.presplitAccumDetail, width, height);

        int grey = p_Grey ? 1 : 0;
        [enc setComputePipelineState:gKernels.previewAccumStrided];
        [enc setTexture:gRes.accDetail atIndex:0];
        [enc setBuffer:dstStrided offset:dstOffset atIndex:0];
        [enc setBytes:&io length:sizeof(io) atIndex:1];
        [enc setBytes:&grey length:sizeof(int) atIndex:2];
        dispatch2D(enc, gKernels.previewAccumStrided, width, height);
        [enc endEncoding];
        if (outSkipUnpack != nullptr)
            *outSkipUnpack = true;
        return true;
    }

    float blendOrig = p_EQ[7];
    float lb = lumaBlend;
    [enc setComputePipelineState:gKernels.presplitFusedStrided];
    [enc setTexture:gMps.lSource atIndex:0];
    fqBindPresplitBlurTextures(enc, 1);
    [enc setTexture:gRes.originalLinear atIndex:7];
    [enc setBuffer:dstStrided offset:dstOffset atIndex:0];
    [enc setBytes:&io length:sizeof(io) atIndex:1];
    [enc setBytes:eqBands length:sizeof(eqBands) atIndex:2];
    [enc setBytes:&blendOrig length:sizeof(float) atIndex:3];
    [enc setBytes:&lb length:sizeof(float) atIndex:4];
    dispatch2D(enc, gKernels.presplitFusedStrided, width, height);
    [enc endEncoding];
    return true;
}

}

bool LSPOpenTextureFreqEQ_IsIdentity(const float eq[8], int displaySwitch, float globalBlend) {
    return openTextureMtfIsIdentity(eq, displaySwitch, globalBlend);
}

bool LSPOpenTextureFreqEQ_EncodeToCommandBuffer(
    id<MTLCommandBuffer> cmd,
    id<MTLBuffer> srcStrided,
    size_t srcOffset,
    id<MTLBuffer> dstStrided,
    size_t dstOffset,
    const LSPOpenTextureHostParams& io,
    const float eq[8],
    int displaySwitch,
    int grey,
    float lumaBlend,
    bool* outSkipUnpack) {
    if (cmd == nil || srcStrided == nil || dstStrided == nil) {
        logFreqEqOnce(g_loggedFreqEqNilArgs, "metal_freqeq_nil_cmd_or_packed_buffer");
        return false;
    }
    id<MTLDevice> device = cmd.device;
    if (device == nil) {
        logFreqEqOnce(g_loggedFreqEqDeviceNil, "metal_freqeq_nil_command_buffer_device");
        return false;
    }
    if (io.width < 1 || io.height < 1) {
        logFreqEqOnce(g_loggedFreqEqNilArgs, "metal_freqeq_invalid_dimensions");
        return false;
    }

    float eqCopy[8];
    std::memcpy(eqCopy, eq, sizeof(eqCopy));

    {
        std::lock_guard<std::mutex> lock(gFqCacheMutex);
        if (!fqEnsureRgbKernels(device)) {
            logFreqEqOnce(g_loggedFreqEqKernels, "metal_freqeq_ensure_rgb_kernels_failed");
            return false;
        }
        if (!fqEnsureResources(device, io.width, io.height)) {
            logFreqEqOnce(g_loggedFreqEqResources, "metal_freqeq_ensure_textures_failed");
            return false;
        }
    }

    if (!fqEncodeFreqEQBody(cmd, srcStrided, srcOffset, dstStrided, dstOffset, io, eqCopy, displaySwitch, grey, lumaBlend, outSkipUnpack)) {
        logFreqEqOnce(g_loggedFreqEqBody, "metal_freqeq_encode_body_failed");
        return false;
    }
    return true;
}
