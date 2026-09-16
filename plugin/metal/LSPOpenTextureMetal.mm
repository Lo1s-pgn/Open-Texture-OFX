#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

#include <atomic>
#include <algorithm>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <sstream>
#include <string>
#include <dlfcn.h>

#include "LSPOpenTextureLog.h"
#include "LSPOpenTextureMetal.h"
#include "LSPOpenTextureFreqEQBridge.h"
#include "LSPOpenTextureGlareBridge.h"
#include "../core/LSPOpenTextureMtfIdentity.h"
#include "../core/LSPOpenTextureTfMapping.h"
#include "../core/LSPOpenTextureGamut.h"
#include "../core/LSPOpenTextureConstants.h"
#include "../core/LSPOpenTextureMetalParams.h"
#include "../core/LSPOpenTextureEffectWindow.h"
#include "../core/LSPOpenTextureProfile.h"
#include "../core/LSPOpenTextureVanVliet.h"

@interface LSPOpenTextureMetalBundleAnchor : NSObject
@end
@implementation LSPOpenTextureMetalBundleAnchor
@end

namespace {

using OpenTextureMetalParams = LSPOpenTextureMetalParamsHost;

struct MPSCache {
    id<MTLTexture> texOut = nil;
    id<MTLTexture> pyramidSrc = nil;
    id<MTLTexture> pyramidBlurTex = nil;
    MPSImageGaussianBlur* blur = nil;
    MPSImageGaussianBlur* pyramidBlurOp = nil;
    MPSImageBilinearScale* bilinearScale = nil;
    NSUInteger width = 0;
    NSUInteger height = 0;
    float sigma = -1.0f;
    float pyramidSigma = -1.0f;
};

struct MtfPreMtfCache {
    id<MTLBuffer> buf = nil;
    NSUInteger byteCapacity = 0;
};

struct HalationScratchCache {
    id<MTLTexture> preprocessTex = nil;
    NSUInteger width = 0;
    NSUInteger height = 0;
};

struct MetalContext {
    id<MTLDevice> device = nil;
    id<MTLComputePipelineState> preprocessTexturePipeline = nil;
    id<MTLComputePipelineState> compositeTexture = nil;
    id<MTLComputePipelineState> regionCopy = nil;
    id<MTLComputePipelineState> globalBlend = nil;
    id<MTLComputePipelineState> windowEdgeReplicateTexture = nil;
    id<MTLComputePipelineState> windowEdgeReplicateStrided = nil;
    id<MTLComputePipelineState> windowBlackMask = nil;
    id<MTLComputePipelineState> windowBorder = nil;
    MPSCache mps;
    MtfPreMtfCache mtfPre;
    HalationScratchCache halationScratch;
    std::mutex initMutex;
    std::mutex mtfPostMutex;
};

MetalContext& context() {
    static MetalContext ctx;
    return ctx;
}

static std::string metallibPathFromNSBundle() {
    NSBundle* bundle = [NSBundle bundleForClass:[LSPOpenTextureMetalBundleAnchor class]];
    if (bundle == nil)
        return {};
    NSString* path = [bundle pathForResource:@"LSPOpenTextureMetal" ofType:@"metallib"];
    if (path == nil || path.length == 0)
        return {};
    return std::string([path fileSystemRepresentation]);
}

std::string moduleDirectory() {
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void*>(&context), &info) == 0 || info.dli_fname == nullptr)
        return std::string();
    std::filesystem::path p(info.dli_fname);
    return p.parent_path().string();
}

std::string metallibPath() {
    const std::string fromBundle = metallibPathFromNSBundle();
    if (!fromBundle.empty()) {
        NSString* nsPath = [NSString stringWithUTF8String:fromBundle.c_str()];
        if (nsPath != nil && [[NSFileManager defaultManager] fileExistsAtPath:nsPath])
            return fromBundle;
    }
    const std::filesystem::path macosDir(moduleDirectory());
    if (macosDir.empty())
        return std::string();
    return (macosDir.parent_path() / "Resources" / "LSPOpenTextureMetal.metallib").string();
}

std::atomic<bool> g_loggedMetalInitPath{false};
std::atomic<bool> g_loggedMetalInitLibrary{false};
std::atomic<bool> g_loggedMetalInitPso{false};
std::atomic<bool> g_loggedPixelNotBuffer{false};
std::atomic<bool> g_loggedBufferSpan{false};
std::atomic<bool> g_loggedPackedRowStride{false};
std::atomic<bool> g_loggedCmdBuf{false};
std::atomic<bool> g_loggedMtfPackNil{false};
std::atomic<bool> g_loggedRenderInit{false};
std::atomic<bool> g_loggedRenderGlarePost{false};

static void logMetalOnce(std::atomic<bool>& flag, const std::string& message) {
    if (flag.exchange(true))
        return;
    LSPOpenTextureLog::writeErrorLine(message);
}

static bool shouldSyncCmdBuffer(void) {
#ifdef DEBUG
    return true;
#else
    const char* env = std::getenv("OPEN_TEXTURE_METAL_SYNC");
    return env != nullptr && env[0] == '1';
#endif
}

static bool waitCmdBuffer(id<MTLCommandBuffer> cmd) {
    if (cmd == nil)
        return false;
    [cmd waitUntilCompleted];
    if (cmd.status != MTLCommandBufferStatusError)
        return true;
    if (!g_loggedCmdBuf.exchange(true)) {
        NSError* err = cmd.error;
        std::string msg = "metal_command_buffer_error";
        if (err != nil && err.localizedDescription != nil) {
            const char* utf = err.localizedDescription.UTF8String;
            if (utf != nullptr)
                msg.append(" ").append(utf);
        }
        LSPOpenTextureLog::writeErrorLine(msg);
    }
    return false;
}

static bool commitCmdBuffer(id<MTLCommandBuffer> cmd) {
    if (cmd == nil)
        return false;
    [cmd commit];
    if (shouldSyncCmdBuffer())
        return waitCmdBuffer(cmd);
    return true;
}

static void deferredReleaseOnCmd(id<MTLCommandBuffer> cmd, id obj) {
    if (obj == nil)
        return;
    if (cmd == nil) {
        [obj release];
        return;
    }
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) {
        [obj release];
    }];
}

static id<MTLTexture> makeBlurRGBATexture(id<MTLDevice> device, NSUInteger width, NSUInteger height) {
    if (device == nil || width < 1 || height < 1)
        return nil;
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:width height:height mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModePrivate;
    return [device newTextureWithDescriptor:d];
}

static void releaseMtfPreCache(MetalContext& ctx) {
    [ctx.mtfPre.buf release];
    ctx.mtfPre.buf = nil;
    ctx.mtfPre.byteCapacity = 0;
}

static void releaseHalationScratchCache(MetalContext& ctx, id<MTLCommandBuffer> cmd) {
    deferredReleaseOnCmd(cmd, ctx.halationScratch.preprocessTex);
    ctx.halationScratch.preprocessTex = nil;
    ctx.halationScratch.width = 0;
    ctx.halationScratch.height = 0;
}

static bool ensureHalationScratch(MetalContext& ctx, id<MTLDevice> dev, int width, int height, id<MTLCommandBuffer> cmd) {
    if (dev == nil || width <= 0 || height <= 0)
        return false;
    const NSUInteger w = (NSUInteger)width;
    const NSUInteger h = (NSUInteger)height;
    if (ctx.halationScratch.preprocessTex != nil && ctx.halationScratch.width == w && ctx.halationScratch.height == h)
        return true;
    id<MTLTexture> old = ctx.halationScratch.preprocessTex;
    ctx.halationScratch.preprocessTex = makeBlurRGBATexture(dev, w, h);
    if (ctx.halationScratch.preprocessTex == nil) {
        ctx.halationScratch.width = 0;
        ctx.halationScratch.height = 0;
        return false;
    }
    ctx.halationScratch.width = w;
    ctx.halationScratch.height = h;
    deferredReleaseOnCmd(cmd, old);
    return true;
}

static bool ensureMtfPreBuffer(MetalContext& ctx, id<MTLDevice> dev, NSUInteger regionBytes) {
    if (ctx.mtfPre.buf != nil && ctx.mtfPre.byteCapacity >= regionBytes)
        return true;
    [ctx.mtfPre.buf release];
    ctx.mtfPre.buf = [dev newBufferWithLength:regionBytes options:MTLResourceStorageModePrivate];
    ctx.mtfPre.byteCapacity = ctx.mtfPre.buf != nil ? regionBytes : 0;
    return ctx.mtfPre.buf != nil;
}

static void releaseIfNonNil(id o) {
    if (o != nil)
        [o release];
}

static void releaseMetalPipelinesAndMPS(MetalContext& ctx) {
    releaseIfNonNil(ctx.preprocessTexturePipeline);
    releaseIfNonNil(ctx.compositeTexture);
    releaseIfNonNil(ctx.regionCopy);
    releaseIfNonNil(ctx.globalBlend);
    releaseIfNonNil(ctx.windowEdgeReplicateTexture);
    releaseIfNonNil(ctx.windowEdgeReplicateStrided);
    releaseIfNonNil(ctx.windowBlackMask);
    releaseIfNonNil(ctx.windowBorder);
    ctx.preprocessTexturePipeline = nil;
    ctx.compositeTexture = nil;
    ctx.regionCopy = nil;
    ctx.globalBlend = nil;
    ctx.windowEdgeReplicateTexture = nil;
    ctx.windowEdgeReplicateStrided = nil;
    ctx.windowBlackMask = nil;
    ctx.windowBorder = nil;
    releaseIfNonNil(ctx.mps.texOut);
    releaseIfNonNil(ctx.mps.pyramidSrc);
    releaseIfNonNil(ctx.mps.pyramidBlurTex);
    releaseIfNonNil(ctx.mps.blur);
    releaseIfNonNil(ctx.mps.pyramidBlurOp);
    releaseIfNonNil(ctx.mps.bilinearScale);
    ctx.mps.texOut = nil;
    ctx.mps.pyramidSrc = nil;
    ctx.mps.pyramidBlurTex = nil;
    ctx.mps.blur = nil;
    ctx.mps.pyramidBlurOp = nil;
    ctx.mps.bilinearScale = nil;
    ctx.mps.width = 0;
    ctx.mps.height = 0;
    ctx.mps.sigma = -1.0f;
    ctx.mps.pyramidSigma = -1.0f;
}

bool initialize(id<MTLCommandQueue> hostQueue) {
    if (hostQueue == nil)
        return false;
    auto& ctx = context();
    std::lock_guard<std::mutex> lock(ctx.initMutex);
    id<MTLDevice> hostDevice = hostQueue.device;
    if (hostDevice == nil)
        return false;
    if (ctx.preprocessTexturePipeline != nil && ctx.compositeTexture != nil && ctx.device == hostDevice)
        return true;

    if (ctx.device != nil && ctx.device != hostDevice) {
        std::lock_guard<std::mutex> mtfLock(ctx.mtfPostMutex);
        releaseMtfPreCache(ctx);
        releaseHalationScratchCache(ctx, nil);
    }

    releaseMetalPipelinesAndMPS(ctx);
    ctx.device = hostDevice;

    const std::string libPathStr = metallibPath();
    if (libPathStr.empty()) {
        logMetalOnce(g_loggedMetalInitPath, "metal_init_metallib_path_empty");
        return false;
    }
    NSString* libPath = [NSString stringWithUTF8String:libPathStr.c_str()];
    if (libPath == nil) {
        logMetalOnce(g_loggedMetalInitPath, "metal_init_metallib_nsstring_failed");
        return false;
    }

    NSError* error = nil;
    id<MTLLibrary> library = [ctx.device newLibraryWithURL:[NSURL fileURLWithPath:libPath] error:&error];
    if (library == nil) {
        std::ostringstream o;
        o << "metal_init_metallib_load_failed path=" << libPathStr;
        if (error != nil && error.localizedDescription != nil && error.localizedDescription.UTF8String != nullptr)
            o << " err=" << error.localizedDescription.UTF8String;
        logMetalOnce(g_loggedMetalInitLibrary, o.str());
        return false;
    }

    auto mk = [&](const char* name) -> id<MTLComputePipelineState> {
        id<MTLFunction> fn = [library newFunctionWithName:[NSString stringWithUTF8String:name]];
        if (fn == nil)
            return nil;
        id<MTLComputePipelineState> pso = [ctx.device newComputePipelineStateWithFunction:fn error:&error];
        [fn release];
        return pso;
    };

    ctx.preprocessTexturePipeline = mk("LSPOpenTexturePreprocessTextureKernel");
    ctx.compositeTexture = mk("LSPOpenTextureCompositeTextureKernel");
    ctx.regionCopy = mk("LSPOpenTextureRegionCopyKernel");
    ctx.globalBlend = mk("LSPOpenTextureGlobalBlendKernel");
    ctx.windowEdgeReplicateTexture = mk("LSPOpenTextureEffectWindowEdgeReplicateTextureKernel");
    ctx.windowEdgeReplicateStrided = mk("LSPOpenTextureEffectWindowEdgeReplicateStridedKernel");
    ctx.windowBlackMask = mk("LSPOpenTextureEffectWindowBlackMaskKernel");
    ctx.windowBorder = mk("LSPOpenTextureEffectWindowBorderKernel");
    [library release];

    const bool coreOk = ctx.preprocessTexturePipeline != nil && ctx.compositeTexture != nil && ctx.regionCopy != nil &&
        ctx.globalBlend != nil && ctx.windowEdgeReplicateTexture != nil && ctx.windowEdgeReplicateStrided != nil &&
        ctx.windowBlackMask != nil && ctx.windowBorder != nil;
    if (!coreOk) {
        std::ostringstream o;
        o << "metal_init_missing_pso preprocessTex=" << (ctx.preprocessTexturePipeline != nil ? 1 : 0)
          << " compositeTex=" << (ctx.compositeTexture != nil ? 1 : 0) << " regionCopy=" << (ctx.regionCopy != nil ? 1 : 0)
          << " globalBlend=" << (ctx.globalBlend != nil ? 1 : 0);
        if (error != nil && error.localizedDescription != nil && error.localizedDescription.UTF8String != nullptr)
            o << " err=" << error.localizedDescription.UTF8String;
        logMetalOnce(g_loggedMetalInitPso, o.str());
        releaseMetalPipelinesAndMPS(ctx);
        return false;
    }
    return true;
}

void dispatch2D(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> pso, int width, int height) {
    [enc setComputePipelineState:pso];
    const NSUInteger maxThreads = pso.maxTotalThreadsPerThreadgroup;
    const NSUInteger tew = pso.threadExecutionWidth;
    NSUInteger tx = tew > 0 ? tew : 16;
    if (tx > maxThreads) tx = maxThreads;
    NSUInteger ty = maxThreads / tx;
    if (ty == 0) ty = 1;
    if (ty > 16) ty = 16;
    [enc dispatchThreads:MTLSizeMake((NSUInteger)width, (NSUInteger)height, 1) threadsPerThreadgroup:MTLSizeMake(tx, ty, 1)];
}

static bool encodeRegionCopy(
    id<MTLCommandBuffer> cmd,
    id<MTLBuffer> srcBuffer,
    size_t srcOffset,
    id<MTLBuffer> dstBuffer,
    size_t dstOffset,
    const OpenTextureMetalParams& io) {
    auto& ctx = context();
    if (ctx.regionCopy == nil || cmd == nil)
        return false;
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;
    [enc setBuffer:srcBuffer offset:srcOffset atIndex:0];
    [enc setBuffer:dstBuffer offset:dstOffset atIndex:1];
    [enc setBytes:&io length:sizeof(OpenTextureMetalParams) atIndex:2];
    dispatch2D(enc, ctx.regionCopy, io.width, io.height);
    [enc endEncoding];
    return true;
}

static bool encodeGlobalBlend(
    id<MTLCommandBuffer> cmd,
    id<MTLBuffer> srcBuffer,
    size_t srcOffset,
    id<MTLBuffer> dstBuffer,
    size_t dstOffset,
    const OpenTextureMetalParams& io,
    float mixEffect) {
    auto& ctx = context();
    if (ctx.globalBlend == nil || cmd == nil)
        return false;
    float g = mixEffect;
    if (g < 0.0f)
        g = 0.0f;
    else if (g > 1.0f)
        g = 1.0f;
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;
    [enc setBuffer:srcBuffer offset:srcOffset atIndex:0];
    [enc setBuffer:dstBuffer offset:dstOffset atIndex:1];
    [enc setBytes:&io length:sizeof(OpenTextureMetalParams) atIndex:2];
    [enc setBytes:&g length:sizeof(float) atIndex:3];
    dispatch2D(enc, ctx.globalBlend, io.width, io.height);
    [enc endEncoding];
    return true;
}

static bool encodeWindowEdgeReplicateStrided(id<MTLCommandBuffer> cmd, id<MTLBuffer> buf, size_t offset, const OpenTextureMetalParams& io) {
    if (!io.effectWindowEnabled || buf == nil)
        return true;
    auto& ctx = context();
    if (ctx.windowEdgeReplicateStrided == nil || cmd == nil)
        return false;
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;
    [enc setBuffer:buf offset:offset atIndex:0];
    [enc setBytes:&io length:sizeof(OpenTextureMetalParams) atIndex:1];
    dispatch2D(enc, ctx.windowEdgeReplicateStrided, io.width, io.height);
    [enc endEncoding];
    return true;
}

static bool encodeWindowBlackMask(id<MTLCommandBuffer> cmd, id<MTLBuffer> dstBuffer, size_t dstOffset, const OpenTextureMetalParams& io) {
    if (!io.effectWindowEnabled || dstBuffer == nil)
        return true;
    auto& ctx = context();
    if (ctx.windowBlackMask == nil || cmd == nil)
        return false;
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;
    [enc setBuffer:dstBuffer offset:dstOffset atIndex:0];
    [enc setBytes:&io length:sizeof(OpenTextureMetalParams) atIndex:1];
    dispatch2D(enc, ctx.windowBlackMask, io.width, io.height);
    [enc endEncoding];
    return true;
}

static bool encodeWindowBorder(id<MTLCommandBuffer> cmd, id<MTLBuffer> dstBuffer, size_t dstOffset, const OpenTextureMetalParams& io) {
    if (!io.effectWindowEnabled || !io.effectWindowShowBorder || dstBuffer == nil)
        return true;
    auto& ctx = context();
    if (ctx.windowBorder == nil || cmd == nil)
        return false;
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;
    [enc setBuffer:dstBuffer offset:dstOffset atIndex:0];
    [enc setBytes:&io length:sizeof(OpenTextureMetalParams) atIndex:1];
    dispatch2D(enc, ctx.windowBorder, io.width, io.height);
    [enc endEncoding];
    return true;
}

static bool encodeFinishRenderWithWindowMask(
    id<MTLCommandBuffer> cmd,
    id<MTLBuffer> dstBuffer,
    size_t dstOffset,
    const OpenTextureMetalParams& io) {
    if (!encodeWindowBlackMask(cmd, dstBuffer, dstOffset, io))
        return false;
    return encodeWindowBorder(cmd, dstBuffer, dstOffset, io);
}

static bool encodeFinishRender(
    id<MTLCommandBuffer> cmd,
    id<MTLBuffer> dstBuffer,
    size_t dstOffset,
    const OpenTextureMetalParams& io) {
    return encodeFinishRenderWithWindowMask(cmd, dstBuffer, dstOffset, io);
}

static bool encodeWindowEdgeReplicateTexture(id<MTLCommandBuffer> cmd, id<MTLTexture> tex, const OpenTextureMetalParams& io) {
    auto& ctx = context();
    if (ctx.windowEdgeReplicateTexture == nil || cmd == nil || tex == nil)
        return false;
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;
    [enc setTexture:tex atIndex:0];
    [enc setBytes:&io length:sizeof(OpenTextureMetalParams) atIndex:0];
    dispatch2D(enc, ctx.windowEdgeReplicateTexture, io.width, io.height);
    [enc endEncoding];
    return true;
}

static bool encodeHalationBlur(id<MTLCommandBuffer> cmd, MetalContext& ctx, id<MTLDevice> dev, int width, int height, float spread) {
    OPEN_TEXTURE_PROFILE_STAGE("halation");
    if (spread < 1.0e-6f) {
        const NSUInteger w = (NSUInteger)width;
        const NSUInteger h = (NSUInteger)height;
        if (ctx.mps.texOut == nil || ctx.mps.width != w || ctx.mps.height != h)
            ctx.mps.texOut = makeBlurRGBATexture(dev, w, h);
        if (ctx.mps.texOut == nil)
            return false;
        ctx.mps.width = w;
        ctx.mps.height = h;
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        if (blit == nil)
            return false;
        [blit copyFromTexture:ctx.halationScratch.preprocessTex
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(w, h, 1)
                    toTexture:ctx.mps.texOut
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        return true;
    }
    const float sigma = LSPOpenTextureTfMapping::mpsSigmaFromSpread(spread);
    const NSUInteger w = (NSUInteger)width;
    const NSUInteger h = (NSUInteger)height;
    if (ctx.mps.width != w || ctx.mps.height != h) {
        releaseIfNonNil(ctx.mps.texOut);
        releaseIfNonNil(ctx.mps.pyramidSrc);
        releaseIfNonNil(ctx.mps.pyramidBlurTex);
        ctx.mps.texOut = nil;
        ctx.mps.pyramidSrc = nil;
        ctx.mps.pyramidBlurTex = nil;
        ctx.mps.width = w;
        ctx.mps.height = h;
    }
    if (ctx.mps.texOut == nil)
        ctx.mps.texOut = makeBlurRGBATexture(dev, w, h);
    if (ctx.mps.bilinearScale == nil)
        ctx.mps.bilinearScale = [[MPSImageBilinearScale alloc] initWithDevice:dev];
    if (ctx.mps.blur == nil || fabsf(ctx.mps.sigma - sigma) > 1.0e-4f) {
        releaseIfNonNil(ctx.mps.blur);
        ctx.mps.blur = [[MPSImageGaussianBlur alloc] initWithDevice:dev sigma:sigma];
        ctx.mps.sigma = sigma;
    }
    if (ctx.mps.texOut == nil || ctx.mps.blur == nil || ctx.mps.bilinearScale == nil)
        return false;

    const bool usePyramid = openTextureUsePyramidBlur(sigma);
    if (!usePyramid) {
        [ctx.mps.blur encodeToCommandBuffer:cmd sourceTexture:ctx.halationScratch.preprocessTex destinationTexture:ctx.mps.texOut];
        return true;
    }

    const float pyramidSigma = sigma * 0.5f;
    const NSUInteger pw = std::max<NSUInteger>((w + 1u) / 2u, 1u);
    const NSUInteger ph = std::max<NSUInteger>((h + 1u) / 2u, 1u);
    if (ctx.mps.pyramidSrc == nil || ctx.mps.pyramidSrc.width != pw || ctx.mps.pyramidSrc.height != ph)
        ctx.mps.pyramidSrc = makeBlurRGBATexture(dev, pw, ph);
    if (ctx.mps.pyramidBlurTex == nil || ctx.mps.pyramidBlurTex.width != pw || ctx.mps.pyramidBlurTex.height != ph)
        ctx.mps.pyramidBlurTex = makeBlurRGBATexture(dev, pw, ph);
    if (ctx.mps.pyramidBlurOp == nil || fabsf(ctx.mps.pyramidSigma - pyramidSigma) > 1.0e-4f) {
        releaseIfNonNil(ctx.mps.pyramidBlurOp);
        ctx.mps.pyramidBlurOp = [[MPSImageGaussianBlur alloc] initWithDevice:dev sigma:pyramidSigma];
        ctx.mps.pyramidSigma = pyramidSigma;
    }
    if (ctx.mps.pyramidSrc == nil || ctx.mps.pyramidBlurTex == nil || ctx.mps.pyramidBlurOp == nil)
        return false;
    [ctx.mps.bilinearScale encodeToCommandBuffer:cmd sourceTexture:ctx.halationScratch.preprocessTex destinationTexture:ctx.mps.pyramidSrc];
    [ctx.mps.pyramidBlurOp encodeToCommandBuffer:cmd sourceTexture:ctx.mps.pyramidSrc destinationTexture:ctx.mps.pyramidBlurTex];
    [ctx.mps.bilinearScale encodeToCommandBuffer:cmd sourceTexture:ctx.mps.pyramidBlurTex destinationTexture:ctx.mps.texOut];
    return true;
}

static bool encodeMtfPost(
    id<MTLCommandBuffer> cmd,
    id<MTLDevice> dev,
    id<MTLBuffer> dstBuffer,
    size_t dstOffset,
    const OpenTextureMetalParams& io,
    const float mtfEq[8],
    int mtfDisplay,
    int mtfGrey,
    float mtfLumaBlend,
    float mtfGlobalBlend) {
    OPEN_TEXTURE_PROFILE_STAGE("mtf");
    auto& ctx = context();
    std::lock_guard<std::mutex> mtfLock(ctx.mtfPostMutex);
    if (cmd == nil) {
        logMetalOnce(g_loggedMtfPackNil, "metal_mtf_nil_cmd");
        return false;
    }
    const float mg = (mtfGlobalBlend < 0.0f) ? 0.0f : ((mtfGlobalBlend > 1.0f) ? 1.0f : mtfGlobalBlend);
    if (mg <= 1.0e-5f)
        return true;
    if (openTextureMtfIsIdentity(mtfEq, mtfDisplay, mg))
        return true;
    const int w = io.width;
    const int h = io.height;
    if (w <= 0 || h <= 0 || dev == nil)
        return false;
    if (!encodeWindowEdgeReplicateStrided(cmd, dstBuffer, dstOffset, io))
        return false;
    const size_t dstRowBytes = static_cast<size_t>(io.dstRowFloats) * sizeof(float);
    const size_t regionBytes = static_cast<size_t>(h) * dstRowBytes;
    const bool needPre = mg < 1.0f - 1.0e-5f;
    if (needPre) {
        if (!ensureMtfPreBuffer(ctx, dev, static_cast<NSUInteger>(regionBytes)))
            return false;
        if (!encodeRegionCopy(cmd, dstBuffer, dstOffset, ctx.mtfPre.buf, 0, io))
            return false;
    }

    float eqCopy[8];
    std::memcpy(eqCopy, mtfEq, sizeof(eqCopy));
    bool skipUnpack = false;
    if (!LSPOpenTextureFreqEQ_EncodeToCommandBuffer(cmd, dstBuffer, dstOffset, dstBuffer, dstOffset, io, eqCopy, mtfDisplay, mtfGrey, mtfLumaBlend, &skipUnpack))
        return false;
    (void)skipUnpack;

    if (needPre)
        return encodeGlobalBlend(cmd, ctx.mtfPre.buf, 0, dstBuffer, dstOffset, io, mg);
    return true;
}

static bool encodeGlarePost(
    id<MTLCommandBuffer> cmd,
    id<MTLDevice> hostDevice,
    id<MTLBuffer> dstBuffer,
    size_t dstOffset,
    const OpenTextureMetalParams& io,
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
    int glareDisplay) {
    OPEN_TEXTURE_PROFILE_STAGE("glare");
    const float eps = 1.0e-5f;
    if (!glareEnable || (glareDisplay == 0 && (glareGlobalBlend <= eps || glareStrength <= eps)))
        return true;
    auto& ctx = context();
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
    if (!LSPOpenTextureGlare_EncodeToCommandBuffer(
            cmd,
            hostDevice,
            dstBuffer,
            dstOffset,
            io,
            glare,
            glareGlobalBlend,
            ctx.windowEdgeReplicateTexture,
            ctx.globalBlend)) {
        logMetalOnce(g_loggedRenderGlarePost, "metal_glare_post_failed");
        return false;
    }
    return true;
}

}

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
    void* metalCommandQueue) {
    if (srcMetalBuffer == nullptr || dstMetalBuffer == nullptr || metalCommandQueue == nullptr || width <= 0 || height <= 0)
        return false;
    id<MTLCommandQueue> hostQueue = (id<MTLCommandQueue>)metalCommandQueue;
    if (!initialize(hostQueue)) {
        logMetalOnce(g_loggedRenderInit, "metal_render_initialize_failed");
        return false;
    }

    id srcObj = (__bridge id)srcMetalBuffer;
    id dstObj = (__bridge id)dstMetalBuffer;
    if (![srcObj conformsToProtocol:@protocol(MTLBuffer)] || ![dstObj conformsToProtocol:@protocol(MTLBuffer)]) {
        logMetalOnce(g_loggedPixelNotBuffer, "metal_pixel_data_not_mtl_buffer_protocol");
        return false;
    }
    id<MTLBuffer> srcBuffer = (id<MTLBuffer>)srcObj;
    id<MTLBuffer> dstBuffer = (id<MTLBuffer>)dstObj;

    const size_t packedRowBytes = static_cast<size_t>(width) * 4u * sizeof(float);
    size_t srb = srcRowBytes == 0 ? packedRowBytes : srcRowBytes;
    size_t drb = dstRowBytes == 0 ? packedRowBytes : dstRowBytes;
    if (srb < packedRowBytes || drb < packedRowBytes || srcPixelCol < 0 || srcPixelRow < 0 || dstPixelCol < 0 || dstPixelRow < 0)
        return false;

    auto offsetFor = [](size_t rb, int col, int row) -> size_t {
        return static_cast<size_t>(row) * rb + static_cast<size_t>(col) * 4u * sizeof(float);
    };
    auto spanFor = [packedRowBytes](size_t rb, int h) -> size_t {
        if (h <= 0)
            return 0u;
        return static_cast<size_t>(h - 1) * rb + packedRowBytes;
    };

    size_t srcOffset = offsetFor(srb, srcPixelCol, srcPixelRow);
    size_t dstOffset = offsetFor(drb, dstPixelCol, dstPixelRow);
    size_t spanSrc = spanFor(srb, height);
    size_t spanDst = spanFor(drb, height);
    if (srcBuffer.length < srcOffset + spanSrc || dstBuffer.length < dstOffset + spanDst) {
        const size_t spanTight = static_cast<size_t>(height) * packedRowBytes;
        const size_t srcOffTight = offsetFor(packedRowBytes, srcPixelCol, srcPixelRow);
        const size_t dstOffTight = offsetFor(packedRowBytes, dstPixelCol, dstPixelRow);
        if (srcBuffer.length >= srcOffTight + spanTight && dstBuffer.length >= dstOffTight + spanTight) {
            srb = packedRowBytes;
            drb = packedRowBytes;
            srcOffset = srcOffTight;
            dstOffset = dstOffTight;
            spanSrc = spanTight;
            spanDst = spanTight;
            logMetalOnce(g_loggedPackedRowStride, "metal_buffer_stride_using_packed_rows");
        } else {
            if (!g_loggedBufferSpan.exchange(true)) {
                std::ostringstream o;
                o << "metal_buffer_span_fail srcLen=" << static_cast<unsigned long>(srcBuffer.length)
                  << " dstLen=" << static_cast<unsigned long>(dstBuffer.length) << " needSrc="
                  << static_cast<unsigned long>(srcOffset + spanSrc) << " needDst="
                  << static_cast<unsigned long>(dstOffset + spanDst) << " tightNeedSrc="
                  << static_cast<unsigned long>(srcOffTight + spanTight) << " tightNeedDst="
                  << static_cast<unsigned long>(dstOffTight + spanTight) << " w=" << width << " h=" << height
                  << " host_srb=" << srcRowBytes << " host_drb=" << dstRowBytes;
                LSPOpenTextureLog::writeErrorLine(o.str());
            }
            return false;
        }
    }

    auto& ctx = context();
    const LSPOpenTextureTfMapping::ResolvedTf tf = LSPOpenTextureTfMapping::resolveTfParams(intensity, hue, saturation);

    OpenTextureMetalParams p{};
    p.distribution = highlightDistribution;
    p.inputTransferFunction = transferFunction;
    p.showDistribution = showDistribution ? 1 : 0;
    openTextureFillWorkingGamutParams(inputGamut, p);
    p.width = width;
    p.height = height;
    p.srcRowFloats = static_cast<int>(srb / sizeof(float));
    p.dstRowFloats = static_cast<int>(drb / sizeof(float));
    p.exposureLostLin = tf.exposureLostLin;
    p.greenExposureLostLin = tf.greenLin;
    p.blueExposureLostLin = tf.blueLin;
    std::memcpy(p.invMatrix, tf.invMatrix, sizeof(p.invMatrix));
    {
        const LSPOpenTextureEffectWindowGeo geo =
            computeOpenTextureEffectWindowGeo(width, height, effectWindowAspect, effectWindowVertical);
        fillOpenTextureMetalEffectWindow(p, geo, effectWindowEnabled, effectWindowShowBorder);
    }

    OpenTextureMetalParams ph = p;

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

    id<MTLCommandBuffer> cmd = [hostQueue commandBuffer];
    if (cmd == nil)
        return false;

    OPEN_TEXTURE_PROFILE_FRAME();

    id<MTLDevice> hostDevice = hostQueue.device;

    const bool halationBypass = !halationEnable || hg <= eps;
    if (halationBypass) {
        if (!encodeRegionCopy(cmd, srcBuffer, srcOffset, dstBuffer, dstOffset, p))
            return false;
        if (mtfEnable && mg > eps) {
            if (!encodeMtfPost(cmd, hostDevice, dstBuffer, dstOffset, p, mtfEq, mtfDisplay, mtfGrey, mtfLumaBlend, mg))
                return false;
        }
        if (!encodeGlarePost(cmd, hostDevice, dstBuffer, dstOffset, p, glareEnable, glareGlobalBlend, glareThreshold, glareSmoothness, glareClampHighlights, glareMaxHighlights, glareStrength, glareSaturation, glareTemperature, glareExposure, glareSpread, glareDisplay))
            return false;
        if (!encodeFinishRender(cmd, dstBuffer, dstOffset, p))
            return false;
        return commitCmdBuffer(cmd);
    }

    id<MTLBuffer> halSrcBuf = srcBuffer;
    size_t halSrcOffset = srcOffset;
    const bool useMtfFirst = (opOrder == 1) && mtfEnable && (mg > eps);
    if (useMtfFirst) {
        if (!encodeRegionCopy(cmd, srcBuffer, srcOffset, dstBuffer, dstOffset, p))
            return false;
        if (!encodeMtfPost(cmd, hostDevice, dstBuffer, dstOffset, p, mtfEq, mtfDisplay, mtfGrey, mtfLumaBlend, mg))
            return false;
        halSrcBuf = dstBuffer;
        halSrcOffset = dstOffset;
        ph = p;
    }

    if ((spread < 1.0e-6f && !showDistribution) || ctx.preprocessTexturePipeline == nil || ctx.compositeTexture == nil) {
        if (!encodeRegionCopy(cmd, halSrcBuf, halSrcOffset, dstBuffer, dstOffset, ph))
            return false;
        if (hg < 1.0f - eps) {
            if (!encodeGlobalBlend(cmd, srcBuffer, srcOffset, dstBuffer, dstOffset, ph, hg))
                return false;
        }
        if (!useMtfFirst && mtfEnable && mg > eps) {
            if (!encodeMtfPost(cmd, hostDevice, dstBuffer, dstOffset, p, mtfEq, mtfDisplay, mtfGrey, mtfLumaBlend, mg))
                return false;
        }
        if (!encodeGlarePost(cmd, hostDevice, dstBuffer, dstOffset, p, glareEnable, glareGlobalBlend, glareThreshold, glareSmoothness, glareClampHighlights, glareMaxHighlights, glareStrength, glareSaturation, glareTemperature, glareExposure, glareSpread, glareDisplay))
            return false;
        if (!encodeFinishRender(cmd, dstBuffer, dstOffset, p))
            return false;
        return commitCmdBuffer(cmd);
    }

    if (!ensureHalationScratch(ctx, hostDevice, width, height, cmd))
        return false;

    {
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        if (enc == nil)
            return false;
        [enc setBuffer:halSrcBuf offset:halSrcOffset atIndex:0];
        [enc setTexture:ctx.halationScratch.preprocessTex atIndex:0];
        [enc setBytes:&ph length:sizeof(OpenTextureMetalParams) atIndex:2];
        dispatch2D(enc, ctx.preprocessTexturePipeline, width, height);
        [enc endEncoding];
    }

    if (!encodeWindowEdgeReplicateTexture(cmd, ctx.halationScratch.preprocessTex, ph))
        return false;

    if (!encodeHalationBlur(cmd, ctx, hostDevice, width, height, spread))
        return false;

    {
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        if (enc == nil)
            return false;
        [enc setBuffer:halSrcBuf offset:halSrcOffset atIndex:0];
        [enc setTexture:ctx.mps.texOut atIndex:0];
        [enc setBuffer:dstBuffer offset:dstOffset atIndex:2];
        [enc setBytes:&ph length:sizeof(OpenTextureMetalParams) atIndex:3];
        dispatch2D(enc, ctx.compositeTexture, width, height);
        [enc endEncoding];
    }

    if (hg < 1.0f - eps) {
        if (!encodeGlobalBlend(cmd, srcBuffer, srcOffset, dstBuffer, dstOffset, ph, hg))
            return false;
    }
    if (!useMtfFirst && mtfEnable && mg > eps) {
        if (!encodeMtfPost(cmd, hostDevice, dstBuffer, dstOffset, p, mtfEq, mtfDisplay, mtfGrey, mtfLumaBlend, mg))
            return false;
    }
    if (!encodeGlarePost(cmd, hostDevice, dstBuffer, dstOffset, p, glareEnable, glareGlobalBlend, glareThreshold, glareSmoothness, glareClampHighlights, glareMaxHighlights, glareStrength, glareSaturation, glareTemperature, glareExposure, glareSpread, glareDisplay))
        return false;
    if (!encodeFinishRender(cmd, dstBuffer, dstOffset, p))
        return false;
    return commitCmdBuffer(cmd);
}

}
