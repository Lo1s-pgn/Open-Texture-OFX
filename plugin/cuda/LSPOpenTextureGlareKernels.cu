#include "LSPOpenTextureCudaCommon.cuh"
#include "LSPOpenTextureGlareCudaParams.h"
#include "../metal/LSPOpenTextureGlareParams.h"

#include <algorithm>
#include <cuda_runtime.h>

namespace {

constexpr int kGlareDisplayRender = 0;
constexpr int kGlareDisplaySource = 1;
constexpr int kGlareDisplayDiffusion = 2;
constexpr int kGlareQualityHigh = 0;
constexpr int kGlareQualityMedium = 1;
constexpr int kGlareQualityLow = 2;

__device__ __forceinline__ float3 otReadPackedRGB(const float* buf, int w, int x, int y) {
    const int i = (y * w + x) * 4;
    return make_float3(buf[i], buf[i + 1], buf[i + 2]);
}

__device__ __forceinline__ void otWritePackedRGB(float* buf, int w, int x, int y, float3 rgb) {
    const int i = (y * w + x) * 4;
    buf[i] = rgb.x;
    buf[i + 1] = rgb.y;
    buf[i + 2] = rgb.z;
    buf[i + 3] = 1.0f;
}

__device__ __forceinline__ float3 otSamplePackedBilinear(const float* buf, int sw, int sh, float fx, float fy) {
    const float cx = otClampf(fx, 0.0f, static_cast<float>(sw - 1));
    const float cy = otClampf(fy, 0.0f, static_cast<float>(sh - 1));
    const int x0 = static_cast<int>(floorf(cx));
    const int y0 = static_cast<int>(floorf(cy));
    const int x1 = min(x0 + 1, sw - 1);
    const int y1 = min(y0 + 1, sh - 1);
    const float tx = cx - static_cast<float>(x0);
    const float ty = cy - static_cast<float>(y0);
    const float3 c00 = otReadPackedRGB(buf, sw, x0, y0);
    const float3 c10 = otReadPackedRGB(buf, sw, x1, y0);
    const float3 c01 = otReadPackedRGB(buf, sw, x0, y1);
    const float3 c11 = otReadPackedRGB(buf, sw, x1, y1);
    const float3 c0 = make_float3(c00.x * (1.0f - tx) + c10.x * tx, c00.y * (1.0f - tx) + c10.y * tx, c00.z * (1.0f - tx) + c10.z * tx);
    const float3 c1 = make_float3(c01.x * (1.0f - tx) + c11.x * tx, c01.y * (1.0f - tx) + c11.y * tx, c01.z * (1.0f - tx) + c11.z * tx);
    return make_float3(c0.x * (1.0f - ty) + c1.x * ty, c0.y * (1.0f - ty) + c1.y * ty, c0.z * (1.0f - ty) + c1.z * ty);
}

__device__ void otGlareRgbToHsv(float3 rgb, float& h, float& s, float& v) {
    const float cmax = fmaxf(rgb.x, fmaxf(rgb.y, rgb.z));
    const float cmin = fminf(rgb.x, fminf(rgb.y, rgb.z));
    const float delta = cmax - cmin;
    v = cmax;
    if (delta < 1.0e-8f) {
        h = 0.0f;
        s = 0.0f;
        return;
    }
    s = delta / cmax;
    if (cmax == rgb.x)
        h = (rgb.y - rgb.z) / delta + (rgb.y < rgb.z ? 6.0f : 0.0f);
    else if (cmax == rgb.y)
        h = (rgb.z - rgb.x) / delta + 2.0f;
    else
        h = (rgb.x - rgb.y) / delta + 4.0f;
    h /= 6.0f;
}

__device__ float3 otGlareHsvToRgb(float h, float s, float v) {
    if (s < 1.0e-8f)
        return make_float3(v, v, v);
    h = h - floorf(h);
    const float c = v * s;
    const float x = c * (1.0f - fabsf(fmodf(h * 6.0f, 2.0f) - 1.0f));
    const float m = v - c;
    float3 rgb = make_float3(0.0f, 0.0f, 0.0f);
    const float hh = h * 6.0f;
    if (hh < 1.0f)
        rgb = make_float3(c, x, 0.0f);
    else if (hh < 2.0f)
        rgb = make_float3(x, c, 0.0f);
    else if (hh < 3.0f)
        rgb = make_float3(0.0f, c, x);
    else if (hh < 4.0f)
        rgb = make_float3(0.0f, x, c);
    else if (hh < 5.0f)
        rgb = make_float3(x, 0.0f, c);
    else
        rgb = make_float3(c, 0.0f, x);
    return make_float3(rgb.x + m, rgb.y + m, rgb.z + m);
}

__device__ float otGlareExtractHighlightV(float v, float minL, float maxL, float smoothness, int clampEnabled) {
    float src = fmaxf(v, 0.0f);
    if (clampEnabled != 0)
        src = fminf(src, maxL);
    const float knee = otClampf(smoothness, 0.0f, 1.0f) * fmaxf(minL, 1.0e-3f);
    const float lo = fmaxf(minL - knee, 0.0f);
    if (knee <= 1.0e-6f)
        return fmaxf(src - minL, 0.0f);
    if (src <= lo)
        return 0.0f;
    if (src < minL) {
        const float d = src - lo;
        return (d * d) / (2.0f * knee);
    }
    return src - minL + 0.5f * knee;
}

__device__ float otGlareLog1p(float x) {
    return logf(1.0f + fmaxf(x, 0.0f));
}

__device__ float otGlareHighlightAmount(float3 rgbLin, const OpenTextureGlareParamsCuda& gp) {
    float h, s, v;
    otGlareRgbToHsv(make_float3(fmaxf(rgbLin.x, 0.0f), fmaxf(rgbLin.y, 0.0f), fmaxf(rgbLin.z, 0.0f)), h, s, v);
    return otGlareExtractHighlightV(v, gp.threshold, gp.maxBrightness, gp.smoothness, gp.clampEnabled);
}

__device__ float otGlareSmoothstep(float edge0, float edge1, float x) {
    const float t = otClampf((x - edge0) / fmaxf(edge1 - edge0, 1.0e-6f), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

__device__ float otGlareCoreWeight(float highlightAmt, const OpenTextureGlareParamsCuda& gp) {
    if (highlightAmt <= 1.0e-6f)
        return 0.0f;
    const float exposure = gp.exposure;
    const float lowShift = 1.0f - otClampf(exposure, 0.0f, 1.0f);
    const bool unclamped = gp.maxBrightness > gp.threshold + 100.0f;
    float headroom = fmaxf(gp.maxBrightness - gp.threshold, 0.0f);
    if (unclamped) {
        headroom = fmaxf(gp.threshold * 0.35f + gp.smoothness * 0.5f + 0.15f, 0.35f);
        headroom *= (5.0f + lowShift * 5.0f);
    } else {
        headroom = fmaxf(headroom, gp.smoothness * 0.25f + 0.08f);
    }
    const float knee = fmaxf(headroom * (0.25f + lowShift * 0.5f), gp.smoothness * 0.12f + 0.04f);
    const float srcSoft = otGlareLog1p(highlightAmt / knee);
    const float highSoft = otGlareLog1p(headroom / knee);
    float core = otGlareSmoothstep(0.0f, fmaxf(highSoft, 1.0e-4f), srcSoft);
    core = powf(core, 1.0f + lowShift * 3.0f);
    return core;
}

__device__ float3 otGlareApplyExposureShift(float3 bloomDelta, float3 inputLin, const OpenTextureGlareParamsCuda& gp) {
    if (fabsf(gp.exposure - 1.0f) < 1.0e-5f)
        return bloomDelta;
    const float highlightAmt = otGlareHighlightAmount(inputLin, gp);
    const float core = otGlareCoreWeight(highlightAmt, gp);
    const float scale = (1.0f - core) + gp.exposure * core;
    return make_float3(bloomDelta.x * scale, bloomDelta.y * scale, bloomDelta.z * scale);
}

__global__ void otGlareDecodeStridedToPacked(const float* __restrict__ srcStrided, float* __restrict__ rgbLinPacked,
                                             OpenTextureCudaParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    const int si = y * p.dstRowFloats + x * 4;
    const float3 enc = make_float3(otSanitizeFinite(srcStrided[si], 0.0f), otSanitizeFinite(srcStrided[si + 1], 0.0f),
                                   otSanitizeFinite(srcStrided[si + 2], 0.0f));
    const float3 lin = otHostToWorking(enc, p);
    otWritePackedRGB(rgbLinPacked, p.width, x, y, lin);
}

__global__ void otGlareHighlights(const float* __restrict__ inputPacked, float* __restrict__ outputPacked, OpenTextureGlareParamsCuda gp,
                                  OpenTextureCudaParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= gp.highlightsWidth || y >= gp.highlightsHeight)
        return;

    float3 color = make_float3(0.0f, 0.0f, 0.0f);
    if (gp.quality == kGlareQualityHigh) {
        const float fx = (static_cast<float>(x) + 0.5f) * static_cast<float>(p.width) / static_cast<float>(gp.highlightsWidth) - 0.5f;
        const float fy = (static_cast<float>(y) + 0.5f) * static_cast<float>(p.height) / static_cast<float>(gp.highlightsHeight) - 0.5f;
        color = otSamplePackedBilinear(inputPacked, p.width, p.height, fx, fy);
    } else if (gp.quality == kGlareQualityMedium) {
        const float fx = (static_cast<float>(x) * 2.0f + 1.0f) / static_cast<float>(p.width) - 0.5f;
        const float fy = (static_cast<float>(y) * 2.0f + 1.0f) / static_cast<float>(p.height) - 0.5f;
        color = otSamplePackedBilinear(inputPacked, p.width, p.height, fx, fy);
    } else {
        const float llx = (static_cast<float>(x) * 4.0f + 1.0f) / static_cast<float>(p.width) - 0.5f;
        const float lly = (static_cast<float>(y) * 4.0f + 1.0f) / static_cast<float>(p.height) - 0.5f;
        const float lrx = (static_cast<float>(x) * 4.0f + 3.0f) / static_cast<float>(p.width) - 0.5f;
        const float lry = (static_cast<float>(y) * 4.0f + 1.0f) / static_cast<float>(p.height) - 0.5f;
        const float ulx = (static_cast<float>(x) * 4.0f + 1.0f) / static_cast<float>(p.width) - 0.5f;
        const float uly = (static_cast<float>(y) * 4.0f + 3.0f) / static_cast<float>(p.height) - 0.5f;
        const float urx = (static_cast<float>(x) * 4.0f + 3.0f) / static_cast<float>(p.width) - 0.5f;
        const float ury = (static_cast<float>(y) * 4.0f + 3.0f) / static_cast<float>(p.height) - 0.5f;
        const float3 ul = otSamplePackedBilinear(inputPacked, p.width, p.height, ulx, uly);
        const float3 ur = otSamplePackedBilinear(inputPacked, p.width, p.height, urx, ury);
        const float3 ll = otSamplePackedBilinear(inputPacked, p.width, p.height, llx, lly);
        const float3 lr = otSamplePackedBilinear(inputPacked, p.width, p.height, lrx, lry);
        color = make_float3((ul.x + ur.x + ll.x + lr.x) * 0.25f, (ul.y + ur.y + ll.y + lr.y) * 0.25f, (ul.z + ur.z + ll.z + lr.z) * 0.25f);
    }

    float h, s, v;
    otGlareRgbToHsv(color, h, s, v);
    v = otGlareExtractHighlightV(v, gp.threshold, gp.maxBrightness, gp.smoothness, gp.clampEnabled);
    const float3 outRgb = otGlareHsvToRgb(h, s, v);
    otWritePackedRGB(outputPacked, gp.highlightsWidth, x, y, outRgb);
}

__global__ void otGlareCopyPacked(int w, int h, const float* __restrict__ src, float* __restrict__ dst) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h)
        return;
    const int si = (y * w + x) * 4;
    const int di = si;
    dst[di] = src[si];
    dst[di + 1] = src[si + 1];
    dst[di + 2] = src[si + 2];
    dst[di + 3] = src[si + 3];
}

__global__ void otGlareLerpPacked(int w, int h, const float* __restrict__ a, const float* __restrict__ b, float* __restrict__ dst,
                                  float blend) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h)
        return;
    const float t = otClampf(blend, 0.0f, 1.0f);
    const int i = (y * w + x) * 4;
    dst[i] = a[i] * (1.0f - t) + b[i] * t;
    dst[i + 1] = a[i + 1] * (1.0f - t) + b[i + 1] * t;
    dst[i + 2] = a[i + 2] * (1.0f - t) + b[i + 2] * t;
    dst[i + 3] = 1.0f;
}

__global__ void otGlareBloomUp(int ow, int oh, int iw, int ih, const float* __restrict__ inputPacked, float* __restrict__ outputPacked) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= ow || y >= oh)
        return;

    const float cx = (static_cast<float>(x) + 0.5f) / static_cast<float>(ow);
    const float cy = (static_cast<float>(y) + 0.5f) / static_cast<float>(oh);
    const float px = 1.0f / static_cast<float>(ow);
    const float py = 1.0f / static_cast<float>(oh);

    auto sampleAt = [&](float dx, float dy) -> float3 {
        const float fx = (cx + dx * px) * static_cast<float>(iw) - 0.5f;
        const float fy = (cy + dy * py) * static_cast<float>(ih) - 0.5f;
        return otSamplePackedBilinear(inputPacked, iw, ih, fx, fy);
    };

    float3 upsampled = sampleAt(0.0f, 0.0f);
    upsampled = make_float3(upsampled.x * (4.0f / 16.0f), upsampled.y * (4.0f / 16.0f), upsampled.z * (4.0f / 16.0f));
    const float3 n0 = sampleAt(-1.0f, 0.0f);
    const float3 n1 = sampleAt(0.0f, 1.0f);
    const float3 n2 = sampleAt(1.0f, 0.0f);
    const float3 n3 = sampleAt(0.0f, -1.0f);
    const float3 c0 = sampleAt(-1.0f, -1.0f);
    const float3 c1 = sampleAt(1.0f, -1.0f);
    const float3 c2 = sampleAt(-1.0f, 1.0f);
    const float3 c3 = sampleAt(1.0f, 1.0f);
    upsampled.x += (2.0f / 16.0f) * (n0.x + n1.x + n2.x + n3.x) + (1.0f / 16.0f) * (c0.x + c1.x + c2.x + c3.x);
    upsampled.y += (2.0f / 16.0f) * (n0.y + n1.y + n2.y + n3.y) + (1.0f / 16.0f) * (c0.y + c1.y + c2.y + c3.y);
    upsampled.z += (2.0f / 16.0f) * (n0.z + n1.z + n2.z + n3.z) + (1.0f / 16.0f) * (c0.z + c1.z + c2.z + c3.z);

    const float3 base = otReadPackedRGB(outputPacked, ow, x, y);
    otWritePackedRGB(outputPacked, ow, x, y, make_float3(base.x + upsampled.x, base.y + upsampled.y, base.z + upsampled.z));
}

__global__ void otGlareHalfResUp(int ow, int oh, int inW, int inH, const float* __restrict__ inputPacked, float* __restrict__ outputPacked) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= ow || y >= oh)
        return;

    const float2 coord = make_float2((static_cast<float>(x) + 0.5f) / static_cast<float>(ow),
                                     (static_cast<float>(y) + 0.5f) / static_cast<float>(oh));
    const float px = 1.0f / static_cast<float>(inW);
    const float py = 1.0f / static_cast<float>(inH);

    auto sample = [&](float dx, float dy) -> float3 {
        const float fx = (coord.x + dx * px) * static_cast<float>(inW) - 0.5f;
        const float fy = (coord.y + dy * py) * static_cast<float>(inH) - 0.5f;
        return otSamplePackedBilinear(inputPacked, inW, inH, fx, fy);
    };

    float3 up = make_float3(0.0f, 0.0f, 0.0f);
    up = make_float3(up.x + (4.0f / 16.0f) * sample(0.0f, 0.0f).x, up.y + (4.0f / 16.0f) * sample(0.0f, 0.0f).y,
                     up.z + (4.0f / 16.0f) * sample(0.0f, 0.0f).z);
    const float3 s1 = sample(-1.0f, 0.0f);
    const float3 s2 = sample(1.0f, 0.0f);
    const float3 s3 = sample(0.0f, -1.0f);
    const float3 s4 = sample(0.0f, 1.0f);
    const float3 s5 = sample(-1.0f, -1.0f);
    const float3 s6 = sample(1.0f, -1.0f);
    const float3 s7 = sample(-1.0f, 1.0f);
    const float3 s8 = sample(1.0f, 1.0f);
    up.x += (2.0f / 16.0f) * (s1.x + s2.x + s3.x + s4.x) + (1.0f / 16.0f) * (s5.x + s6.x + s7.x + s8.x);
    up.y += (2.0f / 16.0f) * (s1.y + s2.y + s3.y + s4.y) + (1.0f / 16.0f) * (s5.y + s6.y + s7.y + s8.y);
    up.z += (2.0f / 16.0f) * (s1.z + s2.z + s3.z + s4.z) + (1.0f / 16.0f) * (s5.z + s6.z + s7.z + s8.z);
    otWritePackedRGB(outputPacked, ow, x, y, up);
}

__global__ void otGlareMixEncode(const float* __restrict__ glarePacked, int glareW, int glareH, const float* __restrict__ baseStrided,
                                 float* __restrict__ dstStrided, OpenTextureGlareParamsCuda gp, OpenTextureCudaParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;

    const int si = y * p.dstRowFloats + x * 4;
    const float3 enc = make_float3(otSanitizeFinite(baseStrided[si], 0.0f), otSanitizeFinite(baseStrided[si + 1], 0.0f),
                                   otSanitizeFinite(baseStrided[si + 2], 0.0f));
    const float alpha = otSanitizeFinite(baseStrided[si + 3], 1.0f);
    const float3 inputLin = make_float3(fmaxf(otHostToWorking(enc, p).x, 0.0f), fmaxf(otHostToWorking(enc, p).y, 0.0f),
                                        fmaxf(otHostToWorking(enc, p).z, 0.0f));

    float3 glareRgb;
    if (glareW == p.width && glareH == p.height)
        glareRgb = otReadPackedRGB(glarePacked, glareW, x, y);
    else {
        const float fx = (static_cast<float>(x) + 0.5f) * static_cast<float>(glareW) / static_cast<float>(p.width) - 0.5f;
        const float fy = (static_cast<float>(y) + 0.5f) * static_cast<float>(glareH) / static_cast<float>(p.height) - 0.5f;
        glareRgb = otSamplePackedBilinear(glarePacked, glareW, glareH, fx, fy);
    }

    if (gp.displayMode == kGlareDisplaySource) {
        const float3 outEnc = otWorkingToHost(make_float3(fmaxf(glareRgb.x, 0.0f), fmaxf(glareRgb.y, 0.0f), fmaxf(glareRgb.z, 0.0f)), p);
        dstStrided[si] = outEnc.x;
        dstStrided[si + 1] = outEnc.y;
        dstStrided[si + 2] = outEnc.z;
        dstStrided[si + 3] = alpha;
        return;
    }

    const float lum = glareRgb.x * 0.2126f + glareRgb.y * 0.7152f + glareRgb.z * 0.0722f;
    float3 chroma = make_float3(glareRgb.x - lum, glareRgb.y - lum, glareRgb.z - lum);
    glareRgb = make_float3(lum + chroma.x * gp.saturation, lum + chroma.y * gp.saturation, lum + chroma.z * gp.saturation);

    const float warm = (gp.temperature - 0.5f) * 2.0f;
    const float3 tempGain = make_float3(1.0f + 0.35f * warm, 1.0f, 1.0f - 0.35f * warm);
    glareRgb = make_float3(glareRgb.x * tempGain.x, glareRgb.y * tempGain.y, glareRgb.z * tempGain.z);
    glareRgb = make_float3(glareRgb.x * gp.glareAmount, glareRgb.y * gp.glareAmount, glareRgb.z * gp.glareAmount);

    if (gp.displayMode == kGlareDisplayRender)
        glareRgb = otGlareApplyExposureShift(glareRgb, inputLin, gp);

    if (gp.displayMode == kGlareDisplayDiffusion) {
        const float3 outEnc = otWorkingToHost(make_float3(fmaxf(glareRgb.x, 0.0f), fmaxf(glareRgb.y, 0.0f), fmaxf(glareRgb.z, 0.0f)), p);
        dstStrided[si] = outEnc.x;
        dstStrided[si + 1] = outEnc.y;
        dstStrided[si + 2] = outEnc.z;
        dstStrided[si + 3] = alpha;
        return;
    }

    const float3 combined = make_float3(inputLin.x + glareRgb.x, inputLin.y + glareRgb.y, inputLin.z + glareRgb.z);
    const float3 outEnc = otWorkingToHost(combined, p);
    dstStrided[si] = outEnc.x;
    dstStrided[si + 1] = outEnc.y;
    dstStrided[si + 2] = outEnc.z;
    dstStrided[si + 3] = alpha;
}

static dim3 otGrid2D(int w, int h) {
    return dim3(static_cast<unsigned>((w + 15) / 16), static_cast<unsigned>((h + 15) / 16), 1u);
}

static dim3 otBlock2D() {
    return dim3(16, 16, 1);
}

}

cudaError_t otLaunchGlareDecodeStridedToPacked(const float* srcStrided, float* rgbLinPacked, OpenTextureCudaParams p, cudaStream_t stream) {
    otGlareDecodeStridedToPacked<<<otGrid2D(p.width, p.height), otBlock2D(), 0, stream>>>(srcStrided, rgbLinPacked, p);
    return cudaGetLastError();
}

cudaError_t otLaunchGlareHighlights(const float* inputPacked, float* outputPacked, const OpenTextureGlareParamsCuda& gp,
                                    OpenTextureCudaParams p, cudaStream_t stream) {
    otGlareHighlights<<<otGrid2D(gp.highlightsWidth, gp.highlightsHeight), otBlock2D(), 0, stream>>>(inputPacked, outputPacked, gp, p);
    return cudaGetLastError();
}

cudaError_t otLaunchGlareCopyPacked(int w, int h, const float* src, float* dst, cudaStream_t stream) {
    otGlareCopyPacked<<<otGrid2D(w, h), otBlock2D(), 0, stream>>>(w, h, src, dst);
    return cudaGetLastError();
}

cudaError_t otLaunchGlareLerpPacked(int w, int h, const float* a, const float* b, float* dst, float blend, cudaStream_t stream) {
    otGlareLerpPacked<<<otGrid2D(w, h), otBlock2D(), 0, stream>>>(w, h, a, b, dst, blend);
    return cudaGetLastError();
}

cudaError_t otLaunchGlareBloomUp(int ow, int oh, int iw, int ih, const float* inputPacked, float* outputPacked, cudaStream_t stream) {
    otGlareBloomUp<<<otGrid2D(ow, oh), otBlock2D(), 0, stream>>>(ow, oh, iw, ih, inputPacked, outputPacked);
    return cudaGetLastError();
}

cudaError_t otLaunchGlareHalfResUp(int ow, int oh, int inW, int inH, const float* inputPacked, float* outputPacked, cudaStream_t stream) {
    otGlareHalfResUp<<<otGrid2D(ow, oh), otBlock2D(), 0, stream>>>(ow, oh, inW, inH, inputPacked, outputPacked);
    return cudaGetLastError();
}

cudaError_t otLaunchGlareMixEncode(const float* glarePacked, int glareW, int glareH, int frameW, int frameH, const float* baseStrided,
                                   float* dstStrided, const OpenTextureGlareParamsCuda& gp, OpenTextureCudaParams p, cudaStream_t stream) {
    (void)frameW;
    (void)frameH;
    otGlareMixEncode<<<otGrid2D(p.width, p.height), otBlock2D(), 0, stream>>>(glarePacked, glareW, glareH, baseStrided, dstStrided, gp, p);
    return cudaGetLastError();
}

extern cudaError_t otLaunchBilinearDownscaleRGBA(int sw, int sh, int dw, int dh, const float* src, float* dst, cudaStream_t stream);
