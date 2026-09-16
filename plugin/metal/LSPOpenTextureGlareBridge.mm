#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

#include "LSPOpenTextureGlareBridge.h"
#include "LSPOpenTextureGlareParams.h"
#include "../core/LSPOpenTextureGlareMapping.h"
#include "../core/LSPOpenTextureMetalParams.h"
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
#include <vector>

@interface LSPOpenTextureGlareBundleAnchor : NSObject
@end
@implementation LSPOpenTextureGlareBundleAnchor
@end

namespace {

static std::atomic<bool> g_loggedGlareInit{false};
static std::atomic<bool> g_loggedGlareEncode{false};

static void logGlareOnce(std::atomic<bool>& flag, const std::string& message) {
    if (flag.exchange(true))
        return;
    LSPOpenTextureLog::writeErrorLine(message);
}

static std::string glareMetallibPathFromBundle(void) {
    NSBundle* bundle = [NSBundle bundleForClass:[LSPOpenTextureGlareBundleAnchor class]];
    if (bundle == nil)
        return {};
    NSString* path = [bundle pathForResource:@"LSPOpenTextureMetal" ofType:@"metallib"];
    if (path == nil || path.length == 0)
        return {};
    return std::string([path fileSystemRepresentation]);
}

static std::string glareModuleDirectory(void) {
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void*>(&glareMetallibPathFromBundle), &info) == 0 || info.dli_fname == nullptr)
        return std::string();
    std::filesystem::path p(info.dli_fname);
    return p.parent_path().string();
}

static std::string glareMetallibPath(void) {
    const std::string fromBundle = glareMetallibPathFromBundle();
    if (!fromBundle.empty()) {
        NSString* nsPath = [NSString stringWithUTF8String:fromBundle.c_str()];
        if (nsPath != nil && [[NSFileManager defaultManager] fileExistsAtPath:nsPath])
            return fromBundle;
    }
    const std::filesystem::path macosDir(glareModuleDirectory());
    if (macosDir.empty())
        return std::string();
    return (macosDir.parent_path() / "Resources" / "LSPOpenTextureMetal.metallib").string();
}

struct GlareMpsCache {
    MPSImageBilinearScale* bilinearScale = nil;
    MPSImageGaussianBlur* levelBlur = nil;
    id<MTLTexture> blurTmp = nil;
    int blurTmpW = 0;
    int blurTmpH = 0;
    float sigma = -1.0f;
};

struct GlareKernelPSOs {
    id<MTLComputePipelineState> decodeToLin = nil;
    id<MTLComputePipelineState> highlights = nil;
    id<MTLComputePipelineState> highlightsFloat = nil;
    id<MTLComputePipelineState> bloomUp = nil;
    id<MTLComputePipelineState> copyTex = nil;
    id<MTLComputePipelineState> lerpTex = nil;
    id<MTLComputePipelineState> halfResUp = nil;
    id<MTLComputePipelineState> mixEncode = nil;
};

struct GlareScratchCache {
    id<MTLDevice> device = nil;
    int width = 0;
    int height = 0;
    int highlightsW = 0;
    int highlightsH = 0;
    int chainLength = 0;
    id<MTLTexture> rgbLinFull = nil;
    id<MTLTexture> highlights = nil;
    id<MTLTexture> bloomStaging = nil;
    id<MTLTexture> bloomPrimaryStore = nil;
    id<MTLTexture> bloomUpscaleHalf = nil;
    id<MTLTexture> highlightsFullRes = nil;
    std::vector<id<MTLTexture>> bloomChain;
    id<MTLBuffer> preBuffer = nil;
    NSUInteger preCapacity = 0;
};

std::mutex gGlareMutex;
GlareKernelPSOs gGlareKernels;
GlareMpsCache gGlareMps;
id<MTLLibrary> gGlareLibrary = nil;
id<MTLDevice> gGlareDevice = nil;
GlareScratchCache gGlareScratch;

static void glareReleaseIfNonNil(id obj) {
    if (obj != nil)
        [obj release];
}

static void glareReleaseScratchTextures(GlareScratchCache& cache) {
    glareReleaseIfNonNil(cache.rgbLinFull);
    cache.rgbLinFull = nil;
    glareReleaseIfNonNil(cache.highlights);
    cache.highlights = nil;
    glareReleaseIfNonNil(cache.bloomStaging);
    cache.bloomStaging = nil;
    glareReleaseIfNonNil(cache.bloomPrimaryStore);
    cache.bloomPrimaryStore = nil;
    glareReleaseIfNonNil(cache.bloomUpscaleHalf);
    cache.bloomUpscaleHalf = nil;
    glareReleaseIfNonNil(cache.highlightsFullRes);
    cache.highlightsFullRes = nil;
    for (id<MTLTexture> tex : cache.bloomChain)
        glareReleaseIfNonNil(tex);
    cache.bloomChain.clear();
}

static void glareReleaseMps(void) {
    glareReleaseIfNonNil(gGlareMps.bilinearScale);
    gGlareMps.bilinearScale = nil;
    glareReleaseIfNonNil(gGlareMps.levelBlur);
    gGlareMps.levelBlur = nil;
    glareReleaseIfNonNil(gGlareMps.blurTmp);
    gGlareMps.blurTmp = nil;
    gGlareMps.blurTmpW = 0;
    gGlareMps.blurTmpH = 0;
    gGlareMps.sigma = -1.0f;
}

static void glareReleaseKernels(void) {
    glareReleaseMps();
    glareReleaseIfNonNil(gGlareKernels.decodeToLin);
    glareReleaseIfNonNil(gGlareKernels.highlights);
    glareReleaseIfNonNil(gGlareKernels.highlightsFloat);
    glareReleaseIfNonNil(gGlareKernels.bloomUp);
    glareReleaseIfNonNil(gGlareKernels.copyTex);
    glareReleaseIfNonNil(gGlareKernels.lerpTex);
    glareReleaseIfNonNil(gGlareKernels.halfResUp);
    glareReleaseIfNonNil(gGlareKernels.mixEncode);
    glareReleaseIfNonNil(gGlareLibrary);
    gGlareLibrary = nil;
    gGlareKernels = GlareKernelPSOs{};
    gGlareDevice = nil;
}

static id<MTLTexture> makeBlurRGBATexture(id<MTLDevice> dev, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                    width:w
                                                                                   height:h
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    desc.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:desc];
}

static id<MTLTexture> makeRGBA32FTexture(id<MTLDevice> dev, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                    width:w
                                                                                   height:h
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    desc.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:desc];
}

static bool glareInitializeKernels(id<MTLDevice> device) {
    if (gGlareKernels.mixEncode != nil && gGlareDevice == device)
        return true;
    std::lock_guard<std::mutex> lock(gGlareMutex);
    if (gGlareKernels.mixEncode != nil && gGlareDevice == device)
        return true;

    glareReleaseKernels();
    glareReleaseScratchTextures(gGlareScratch);
    gGlareScratch = GlareScratchCache{};

    const std::string libPath = glareMetallibPath();
    if (libPath.empty()) {
        logGlareOnce(g_loggedGlareInit, "glare_metallib_path_empty");
        return false;
    }
    NSString* nsPath = [NSString stringWithUTF8String:libPath.c_str()];
    if (nsPath == nil) {
        logGlareOnce(g_loggedGlareInit, "glare_metallib_nsstring_failed");
        return false;
    }
    NSError* err = nil;
    id<MTLLibrary> lib = [device newLibraryWithFile:nsPath error:&err];
    if (lib == nil) {
        std::ostringstream o;
        o << "glare_metallib_load_failed";
        if (err != nil && err.localizedDescription != nil)
            o << " " << err.localizedDescription.UTF8String;
        logGlareOnce(g_loggedGlareInit, o.str());
        return false;
    }

    auto mk = [&](const char* name) -> id<MTLComputePipelineState> {
        NSString* fnName = [NSString stringWithUTF8String:name];
        id<MTLFunction> fn = [lib newFunctionWithName:fnName];
        if (fn == nil)
            return nil;
        NSError* psoErr = nil;
        id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&psoErr];
        [fn release];
        if (pso == nil && psoErr != nil) {
            std::ostringstream o;
            o << "glare_pso_failed " << name;
            if (psoErr.localizedDescription != nil)
                o << " " << psoErr.localizedDescription.UTF8String;
            logGlareOnce(g_loggedGlareInit, o.str());
        }
        return pso;
    };

    gGlareKernels.decodeToLin = mk("k_glare_decode_to_lin_tex");
    gGlareKernels.highlights = mk("k_glare_highlights");
    gGlareKernels.highlightsFloat = mk("k_glare_highlights");
    gGlareKernels.bloomUp = mk("k_glare_bloom_up");
    gGlareKernels.copyTex = mk("k_glare_copy_tex");
    gGlareKernels.lerpTex = mk("k_glare_lerp_tex");
    gGlareKernels.halfResUp = mk("k_glare_half_res_up");
    gGlareKernels.mixEncode = mk("k_glare_mix_encode");

    const bool ok = gGlareKernels.decodeToLin != nil && gGlareKernels.highlights != nil && gGlareKernels.highlightsFloat != nil &&
                    gGlareKernels.bloomUp != nil && gGlareKernels.copyTex != nil && gGlareKernels.lerpTex != nil &&
                    gGlareKernels.halfResUp != nil && gGlareKernels.mixEncode != nil;
    if (!ok) {
        glareReleaseKernels();
        logGlareOnce(g_loggedGlareInit, "glare_init_missing_pso");
        return false;
    }

    gGlareLibrary = lib;
    gGlareDevice = device;
    return true;
}

static void glareDispatch2D(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> pso, int width, int height) {
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
    [enc dispatchThreads:MTLSizeMake((NSUInteger)width, (NSUInteger)height, 1)
      threadsPerThreadgroup:MTLSizeMake(tx, ty, 1)];
}

static bool ensureGlareScratch(
    id<MTLDevice> device,
    int width,
    int height,
    int highlightsW,
    int highlightsH,
    int chainLength) {
    if (gGlareScratch.device != device || gGlareScratch.width != width || gGlareScratch.height != height ||
        gGlareScratch.highlightsW != highlightsW || gGlareScratch.highlightsH != highlightsH ||
        gGlareScratch.chainLength != chainLength) {
        glareReleaseScratchTextures(gGlareScratch);
        gGlareScratch.device = device;
        gGlareScratch.width = width;
        gGlareScratch.height = height;
        gGlareScratch.highlightsW = highlightsW;
        gGlareScratch.highlightsH = highlightsH;
        gGlareScratch.chainLength = chainLength;
    }

    if (gGlareScratch.rgbLinFull == nil)
        gGlareScratch.rgbLinFull = makeRGBA32FTexture(device, (NSUInteger)width, (NSUInteger)height);
    if (gGlareScratch.highlights == nil)
        gGlareScratch.highlights = makeBlurRGBATexture(device, (NSUInteger)highlightsW, (NSUInteger)highlightsH);
    if (gGlareScratch.bloomStaging == nil)
        gGlareScratch.bloomStaging = makeBlurRGBATexture(device, (NSUInteger)highlightsW, (NSUInteger)highlightsH);
    if (gGlareScratch.bloomPrimaryStore == nil)
        gGlareScratch.bloomPrimaryStore = makeBlurRGBATexture(device, (NSUInteger)highlightsW, (NSUInteger)highlightsH);
    const int halfW = std::max(1, highlightsW * 2);
    const int halfH = std::max(1, highlightsH * 2);
    if (gGlareScratch.bloomUpscaleHalf == nil ||
        (int)gGlareScratch.bloomUpscaleHalf.width < halfW ||
        (int)gGlareScratch.bloomUpscaleHalf.height < halfH) {
        glareReleaseIfNonNil(gGlareScratch.bloomUpscaleHalf);
        gGlareScratch.bloomUpscaleHalf = makeBlurRGBATexture(device, (NSUInteger)halfW, (NSUInteger)halfH);
    }

    const int needed = chainLength > 0 ? chainLength : 1;
    if (static_cast<int>(gGlareScratch.bloomChain.size()) != needed) {
        for (id<MTLTexture> tex : gGlareScratch.bloomChain)
            glareReleaseIfNonNil(tex);
        gGlareScratch.bloomChain.clear();
        gGlareScratch.bloomChain.resize((size_t)needed, nil);
    }

    int w = highlightsW;
    int h = highlightsH;
    for (int i = 0; i < needed; ++i) {
        if (gGlareScratch.bloomChain[(size_t)i] == nil ||
            (int)gGlareScratch.bloomChain[(size_t)i].width != w ||
            (int)gGlareScratch.bloomChain[(size_t)i].height != h) {
            glareReleaseIfNonNil(gGlareScratch.bloomChain[(size_t)i]);
            gGlareScratch.bloomChain[(size_t)i] = makeBlurRGBATexture(device, (NSUInteger)w, (NSUInteger)h);
        }
        w = std::max(1, w / 2);
        h = std::max(1, h / 2);
    }

    return gGlareScratch.rgbLinFull != nil && gGlareScratch.highlights != nil &&
           gGlareScratch.bloomStaging != nil && gGlareScratch.bloomPrimaryStore != nil &&
           gGlareScratch.bloomUpscaleHalf != nil;
}

static bool ensureGlareHighlightsFullRes(id<MTLDevice> device, int width, int height) {
    if (gGlareScratch.highlightsFullRes != nil && (int)gGlareScratch.highlightsFullRes.width == width &&
        (int)gGlareScratch.highlightsFullRes.height == height)
        return true;
    glareReleaseIfNonNil(gGlareScratch.highlightsFullRes);
    gGlareScratch.highlightsFullRes = makeRGBA32FTexture(device, (NSUInteger)width, (NSUInteger)height);
    return gGlareScratch.highlightsFullRes != nil;
}

static bool encodeGlareCopyTexture(
    id<MTLCommandBuffer> cmd,
    id<MTLTexture> src,
    id<MTLTexture> dst,
    int width,
    int height) {
    if (src == nil || dst == nil || gGlareKernels.copyTex == nil)
        return false;
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;
    [enc setTexture:src atIndex:0];
    [enc setTexture:dst atIndex:1];
    glareDispatch2D(enc, gGlareKernels.copyTex, width, height);
    [enc endEncoding];
    return true;
}

static bool encodeGlareHalfResUp(
    id<MTLCommandBuffer> cmd,
    id<MTLTexture> src,
    id<MTLTexture> dst,
    int inW,
    int inH,
    int outW,
    int outH) {
    if (gGlareKernels.halfResUp == nil || src == nil || dst == nil || inW <= 0 || inH <= 0 ||
        outW <= 0 || outH <= 0)
        return false;
    const int texW = (int)dst.width;
    const int texH = (int)dst.height;
    const int dispatchW = std::min(outW, texW);
    const int dispatchH = std::min(outH, texH);
    if (dispatchW <= 0 || dispatchH <= 0)
        return false;
    const int inSize[2] = {inW, inH};
    const int outSize[2] = {dispatchW, dispatchH};
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;
    [enc setTexture:src atIndex:0];
    [enc setTexture:dst atIndex:1];
    [enc setBytes:inSize length:sizeof(inSize) atIndex:0];
    [enc setBytes:outSize length:sizeof(outSize) atIndex:1];
    glareDispatch2D(enc, gGlareKernels.halfResUp, dispatchW, dispatchH);
    [enc endEncoding];
    return true;
}

static bool encodeGlareUpscaleToFull(
    id<MTLCommandBuffer> cmd,
    id<MTLTexture> src,
    int srcW,
    int srcH,
    id<MTLTexture> dst,
    int dstW,
    int dstH) {
    if (src == nil || dst == nil || srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0)
        return false;
    if (srcW == dstW && srcH == dstH)
        return encodeGlareCopyTexture(cmd, src, dst, dstW, dstH);

    id<MTLTexture> cur = src;
    int curW = srcW;
    int curH = srcH;
    while (curW < dstW || curH < dstH) {
        const int nextW = std::min(dstW, curW * 2);
        const int nextH = std::min(dstH, curH * 2);
        const bool finalPass = (nextW >= dstW && nextH >= dstH);
        id<MTLTexture> next = finalPass ? dst : gGlareScratch.bloomUpscaleHalf;
        if (!encodeGlareHalfResUp(cmd, cur, next, curW, curH, nextW, nextH))
            return false;
        cur = next;
        curW = nextW;
        curH = nextH;
    }
    return true;
}

static bool ensureGlareMps(id<MTLDevice> device, int blurW, int blurH, float sigma) {
    if (gGlareMps.bilinearScale == nil)
        gGlareMps.bilinearScale = [[MPSImageBilinearScale alloc] initWithDevice:device];
    if (gGlareMps.levelBlur == nil || fabsf(gGlareMps.sigma - sigma) > 1.0e-4f) {
        glareReleaseIfNonNil(gGlareMps.levelBlur);
        gGlareMps.levelBlur = [[MPSImageGaussianBlur alloc] initWithDevice:device sigma:sigma];
        gGlareMps.sigma = sigma;
    }
    if (gGlareMps.blurTmp == nil || gGlareMps.blurTmpW != blurW || gGlareMps.blurTmpH != blurH) {
        glareReleaseIfNonNil(gGlareMps.blurTmp);
        gGlareMps.blurTmp = makeBlurRGBATexture(device, (NSUInteger)blurW, (NSUInteger)blurH);
        gGlareMps.blurTmpW = blurW;
        gGlareMps.blurTmpH = blurH;
    }
    return gGlareMps.bilinearScale != nil && gGlareMps.levelBlur != nil && gGlareMps.blurTmp != nil;
}

static bool encodeGlareBloomChain(
    id<MTLCommandBuffer> cmd,
    id<MTLDevice> device,
    id<MTLTexture> highlights,
    int hiW,
    int hiH,
    int chainLength,
    float blurSigma,
    id<MTLTexture>& outBloom) {
    if (chainLength < 1) {
        outBloom = highlights;
        return true;
    }
    if (!ensureGlareMps(device, hiW, hiH, blurSigma))
        return false;

    if (chainLength == 1) {
        {
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            if (enc == nil)
                return false;
            [enc setTexture:highlights atIndex:0];
            [enc setTexture:gGlareScratch.bloomChain[0] atIndex:1];
            glareDispatch2D(enc, gGlareKernels.copyTex, hiW, hiH);
            [enc endEncoding];
        }
        [gGlareMps.levelBlur encodeToCommandBuffer:cmd sourceTexture:gGlareScratch.bloomChain[0] destinationTexture:gGlareMps.blurTmp];
        id<MTLTexture> chainOut = gGlareScratch.bloomChain[0];
        gGlareScratch.bloomChain[0] = gGlareMps.blurTmp;
        gGlareMps.blurTmp = chainOut;
        gGlareMps.blurTmpW = hiW;
        gGlareMps.blurTmpH = hiH;
        outBloom = gGlareScratch.bloomChain[0];
        return true;
    }

    {
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        if (enc == nil)
            return false;
        [enc setTexture:highlights atIndex:0];
        [enc setTexture:gGlareScratch.bloomChain[0] atIndex:1];
        glareDispatch2D(enc, gGlareKernels.copyTex, hiW, hiH);
        [enc endEncoding];
    }

    int srcW = hiW;
    int srcH = hiH;
    const int passes = chainLength - 1;
    // pyramid swaps reuse textures; size blurTmp to the logical level or dims drift
    std::vector<int> levelW((size_t)chainLength, 0);
    std::vector<int> levelH((size_t)chainLength, 0);
    levelW[0] = hiW;
    levelH[0] = hiH;
    for (int i = 0; i < passes; ++i) {
        const int dstW = std::max(1, srcW / 2);
        const int dstH = std::max(1, srcH / 2);
        levelW[(size_t)(i + 1)] = dstW;
        levelH[(size_t)(i + 1)] = dstH;
        id<MTLTexture> srcTex = gGlareScratch.bloomChain[(size_t)i];
        id<MTLTexture> dstTex = gGlareScratch.bloomChain[(size_t)(i + 1)];
        if ((int)dstTex.width != dstW || (int)dstTex.height != dstH) {
            glareReleaseIfNonNil(dstTex);
            gGlareScratch.bloomChain[(size_t)(i + 1)] = makeBlurRGBATexture(device, (NSUInteger)dstW, (NSUInteger)dstH);
            dstTex = gGlareScratch.bloomChain[(size_t)(i + 1)];
            if (dstTex == nil)
                return false;
        }
        if (srcW == dstW && srcH == dstH) {
            if (!encodeGlareCopyTexture(cmd, srcTex, dstTex, dstW, dstH))
                return false;
        } else {
            [gGlareMps.bilinearScale encodeToCommandBuffer:cmd sourceTexture:srcTex destinationTexture:dstTex];
        }
        if (!ensureGlareMps(device, dstW, dstH, blurSigma))
            return false;
        [gGlareMps.levelBlur encodeToCommandBuffer:cmd sourceTexture:dstTex destinationTexture:gGlareMps.blurTmp];
        id<MTLTexture> chainOut = gGlareScratch.bloomChain[(size_t)(i + 1)];
        gGlareScratch.bloomChain[(size_t)(i + 1)] = gGlareMps.blurTmp;
        gGlareMps.blurTmp = chainOut;
        gGlareMps.blurTmpW = (int)chainOut.width;
        gGlareMps.blurTmpH = (int)chainOut.height;
        srcW = dstW;
        srcH = dstH;
    }

    for (int i = 0; i < passes; ++i) {
        const int upIdx = passes - 1 - i;
        const int outIdx = upIdx;
        const int inIdx = upIdx + 1;
        id<MTLTexture> inputTex = gGlareScratch.bloomChain[(size_t)inIdx];
        id<MTLTexture> outputTex = gGlareScratch.bloomChain[(size_t)outIdx];
        const int ow = levelW[(size_t)outIdx];
        const int oh = levelH[(size_t)outIdx];
        const int iw = levelW[(size_t)inIdx];
        const int ih = levelH[(size_t)inIdx];
        if (ow <= 0 || oh <= 0 || iw <= 0 || ih <= 0)
            return false;
        if ((int)outputTex.width != ow || (int)outputTex.height != oh ||
            (int)inputTex.width != iw || (int)inputTex.height != ih)
            return false;
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        if (enc == nil)
            return false;
        [enc setTexture:inputTex atIndex:0];
        [enc setTexture:outputTex atIndex:1];
        glareDispatch2D(enc, gGlareKernels.bloomUp, ow, oh);
        [enc endEncoding];
    }

    outBloom = gGlareScratch.bloomChain[0];
    return true;
}

static bool encodeGlareLerpTextures(
    id<MTLCommandBuffer> cmd,
    id<MTLTexture> a,
    id<MTLTexture> b,
    id<MTLTexture> dst,
    float blend,
    int width,
    int height) {
    if (gGlareKernels.lerpTex == nil || a == nil || b == nil || dst == nil)
        return false;
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;
    [enc setTexture:a atIndex:0];
    [enc setTexture:b atIndex:1];
    [enc setTexture:dst atIndex:2];
    [enc setBytes:&blend length:sizeof(float) atIndex:0];
    glareDispatch2D(enc, gGlareKernels.lerpTex, width, height);
    [enc endEncoding];
    return true;
}

static bool ensureGlarePreBuffer(id<MTLDevice> device, NSUInteger byteCapacity) {
    if (gGlareScratch.preBuffer != nil && gGlareScratch.preCapacity >= byteCapacity)
        return true;
    glareReleaseIfNonNil(gGlareScratch.preBuffer);
    gGlareScratch.preBuffer = [device newBufferWithLength:byteCapacity options:MTLResourceStorageModePrivate];
    gGlareScratch.preCapacity = gGlareScratch.preBuffer != nil ? byteCapacity : 0;
    return gGlareScratch.preBuffer != nil;
}

static bool encodeWindowEdgeReplicateTexture(
    id<MTLCommandBuffer> cmd,
    id<MTLTexture> tex,
    id<MTLComputePipelineState> pso,
    const LSPOpenTextureMetalParamsHost& io) {
    if (!io.effectWindowEnabled || tex == nil || pso == nil)
        return true;
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;
    [enc setTexture:tex atIndex:0];
    [enc setBytes:&io length:sizeof(LSPOpenTextureMetalParamsHost) atIndex:0];
    glareDispatch2D(enc, pso, io.width, io.height);
    [enc endEncoding];
    return true;
}

static bool encodeGlobalBlendExternal(
    id<MTLCommandBuffer> cmd,
    id<MTLBuffer> src,
    size_t srcOffset,
    id<MTLBuffer> dst,
    size_t dstOffset,
    id<MTLComputePipelineState> globalBlendPso,
    const LSPOpenTextureMetalParamsHost& io,
    float mixEffect) {
    if (globalBlendPso == nil || cmd == nil)
        return false;
    float g = mixEffect;
    if (g < 0.0f)
        g = 0.0f;
    else if (g > 1.0f)
        g = 1.0f;
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (enc == nil)
        return false;
    [enc setBuffer:src offset:srcOffset atIndex:0];
    [enc setBuffer:dst offset:dstOffset atIndex:1];
    [enc setBytes:&io length:sizeof(LSPOpenTextureMetalParamsHost) atIndex:2];
    [enc setBytes:&g length:sizeof(float) atIndex:3];
    glareDispatch2D(enc, globalBlendPso, io.width, io.height);
    [enc endEncoding];
    return true;
}

}

bool LSPOpenTextureGlare_EncodeToCommandBuffer(
    id<MTLCommandBuffer> cmd,
    id<MTLDevice> device,
    id<MTLBuffer> dstStrided,
    size_t dstOffset,
    const LSPOpenTextureMetalParamsHost& io,
    const LSPOpenTextureGlareParamsHost& glare,
    float globalBlend,
    id<MTLComputePipelineState> windowEdgeReplicateTexturePso,
    id<MTLComputePipelineState> globalBlendPso) {
    if (cmd == nil || device == nil || dstStrided == nil || io.width <= 0 || io.height <= 0)
        return false;
    if (!glareInitializeKernels(device)) {
        logGlareOnce(g_loggedGlareEncode, "glare_encode_kernels_unavailable");
        return false;
    }

    const int chainPrimary = glare.chainLength;
    const int chainAlt = glare.chainLengthAlt;
    const float chainBlend = glare.chainBlend;
    const int hiW = glare.highlightsWidth;
    const int hiH = glare.highlightsHeight;
    if (hiW <= 0 || hiH <= 0)
        return false;
    const int scratchChain = std::max({chainPrimary, chainAlt, 1});
    if (!ensureGlareScratch(device, io.width, io.height, hiW, hiH, scratchChain)) {
        logGlareOnce(g_loggedGlareEncode, "glare_encode_scratch_unavailable");
        return false;
    }

    const bool needPre = glare.displayMode == LSPOpenTextureGlareMapping::kGlareDisplayRender && globalBlend < 1.0f - 1.0e-5f;
    const size_t regionBytes = static_cast<size_t>(io.height) * static_cast<size_t>(io.dstRowFloats) * sizeof(float);
    if (needPre) {
        if (!ensureGlarePreBuffer(device, (NSUInteger)regionBytes))
            return false;
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        if (blit == nil)
            return false;
        [blit copyFromBuffer:dstStrided sourceOffset:dstOffset toBuffer:gGlareScratch.preBuffer destinationOffset:0 size:regionBytes];
        [blit endEncoding];
    }

    {
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        if (enc == nil)
            return false;
        [enc setBuffer:dstStrided offset:dstOffset atIndex:0];
        [enc setTexture:gGlareScratch.rgbLinFull atIndex:0];
        [enc setBytes:&io length:sizeof(LSPOpenTextureMetalParamsHost) atIndex:2];
        glareDispatch2D(enc, gGlareKernels.decodeToLin, io.width, io.height);
        [enc endEncoding];
    }

    if (!encodeWindowEdgeReplicateTexture(cmd, gGlareScratch.rgbLinFull, windowEdgeReplicateTexturePso, io))
        return false;

    const bool sourceOverlay = glare.displayMode == LSPOpenTextureGlareMapping::kGlareDisplaySource;
    id<MTLTexture> bloomResult = gGlareScratch.highlights;
    id<MTLTexture> glareFullRes = bloomResult;

    if (sourceOverlay) {
        if (!ensureGlareHighlightsFullRes(device, io.width, io.height)) {
            logGlareOnce(g_loggedGlareEncode, "glare_encode_source_fullres_unavailable");
            return false;
        }
        LSPOpenTextureGlareParamsHost glareFull = glare;
        glareFull.quality = 0;
        glareFull.qualityFactor = 1;
        glareFull.highlightsWidth = io.width;
        glareFull.highlightsHeight = io.height;

        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        if (enc == nil)
            return false;
        [enc setTexture:gGlareScratch.rgbLinFull atIndex:0];
        [enc setTexture:gGlareScratch.highlightsFullRes atIndex:1];
        [enc setBytes:&glareFull length:sizeof(LSPOpenTextureGlareParamsHost) atIndex:0];
        [enc setBytes:&io length:sizeof(LSPOpenTextureMetalParamsHost) atIndex:1];
        glareDispatch2D(enc, gGlareKernels.highlightsFloat, io.width, io.height);
        [enc endEncoding];

        glareFullRes = gGlareScratch.highlightsFullRes;
    } else {
        {
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            if (enc == nil)
                return false;
            [enc setTexture:gGlareScratch.rgbLinFull atIndex:0];
            [enc setTexture:gGlareScratch.highlights atIndex:1];
            [enc setBytes:&glare length:sizeof(LSPOpenTextureGlareParamsHost) atIndex:0];
            [enc setBytes:&io length:sizeof(LSPOpenTextureMetalParamsHost) atIndex:1];
            glareDispatch2D(enc, gGlareKernels.highlights, hiW, hiH);
            [enc endEncoding];
        }

        if (chainPrimary >= 1) {
            const float blurSigma = glare.bloomBlurSigma;
            const float blendEps = 1.0e-4f;
            const bool needBlend = chainAlt > chainPrimary && chainBlend > blendEps;
            if (needBlend) {
                id<MTLTexture> primaryChain = nil;
                if (!encodeGlareBloomChain(cmd, device, gGlareScratch.highlights, hiW, hiH, chainPrimary, blurSigma, primaryChain))
                    return false;
                if (!encodeGlareCopyTexture(cmd, primaryChain, gGlareScratch.bloomPrimaryStore, hiW, hiH))
                    return false;
                id<MTLTexture> bloomAlt = nil;
                if (!encodeGlareBloomChain(cmd, device, gGlareScratch.highlights, hiW, hiH, chainAlt, blurSigma, bloomAlt))
                    return false;
                if (!encodeGlareLerpTextures(cmd, gGlareScratch.bloomPrimaryStore, bloomAlt, gGlareScratch.bloomStaging, chainBlend, hiW, hiH))
                    return false;
                bloomResult = gGlareScratch.bloomStaging;
            } else {
                if (!encodeGlareBloomChain(cmd, device, gGlareScratch.highlights, hiW, hiH, chainPrimary, blurSigma, bloomResult))
                    return false;
            }
        }

        glareFullRes = bloomResult;
        const int bloomW = (int)glareFullRes.width;
        const int bloomH = (int)glareFullRes.height;
        if (bloomW < io.width || bloomH < io.height) {
            if (!encodeGlareUpscaleToFull(cmd, bloomResult, bloomW, bloomH, gGlareScratch.rgbLinFull, io.width, io.height))
                return false;
            glareFullRes = gGlareScratch.rgbLinFull;
        }
    }

    {
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        if (enc == nil)
            return false;
        [enc setTexture:glareFullRes atIndex:0];
        [enc setBuffer:dstStrided offset:dstOffset atIndex:0];
        [enc setBuffer:dstStrided offset:dstOffset atIndex:1];
        [enc setBytes:&glare length:sizeof(LSPOpenTextureGlareParamsHost) atIndex:2];
        [enc setBytes:&io length:sizeof(LSPOpenTextureMetalParamsHost) atIndex:3];
        glareDispatch2D(enc, gGlareKernels.mixEncode, io.width, io.height);
        [enc endEncoding];
    }

    if (needPre && glare.displayMode == LSPOpenTextureGlareMapping::kGlareDisplayRender) {
        if (!encodeGlobalBlendExternal(cmd, gGlareScratch.preBuffer, 0, dstStrided, dstOffset, globalBlendPso, io, globalBlend))
            return false;
    }

    return true;
}
