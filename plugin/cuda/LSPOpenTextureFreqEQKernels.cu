#include "LSPOpenTextureCudaCommon.cuh"

#include <cuda_runtime.h>

namespace {

constexpr float kMaxLinearRgb = 65504.0f;
constexpr float kLabThresh = 0.008856f;
constexpr float kLabThreshInv = 0.206893f;
constexpr float kLab7787 = 7.787f;
constexpr float kLab16_116 = 0.137931034f;

// MTF lab treats working rgb as rec709; no gamut convert (paul dore / baldavenger path)
constexpr float kLabXn = 0.412453f + 0.357580f + 0.180423f;
constexpr float kLabYn = 0.212671f + 0.715160f + 0.072169f;
constexpr float kLabZn = 0.019334f + 0.119193f + 0.950227f;

__device__ __forceinline__ float otLabF(float x) {
    return (x >= kLabThresh) ? powf(x, 1.0f / 3.0f) : (kLab7787 * x + kLab16_116);
}

__device__ __forceinline__ float otLabFi(float x) {
    return (x >= kLabThreshInv) ? (x * x * x) : ((x - kLab16_116) / kLab7787);
}

__device__ __forceinline__ float3 otRgbToXyz709(float3 c) {
    return make_float3(0.4124564f * c.x + 0.3575761f * c.y + 0.1804375f * c.z,
                       0.2126729f * c.x + 0.7151522f * c.y + 0.0721750f * c.z,
                       0.0193339f * c.x + 0.1191920f * c.y + 0.9503041f * c.z);
}

__device__ __forceinline__ float3 otXyzToRgb709(float3 xyz) {
    return make_float3(3.2404542f * xyz.x + -1.5371385f * xyz.y + -0.4985314f * xyz.z,
                       -0.9692660f * xyz.x + 1.8760108f * xyz.y + 0.0415560f * xyz.z,
                       0.0556434f * xyz.x + -0.2040259f * xyz.y + 1.0572252f * xyz.z);
}

__device__ __forceinline__ float otRgbToLabL709(float3 c) {
    const float yy = otRgbToXyz709(c).y;
    const float fy = otLabF(yy / kLabYn);
    const float l = (116.0f * fy - 16.0f) * 0.01f;
    return isfinite(l) ? l : 0.0f;
}

__device__ __forceinline__ float otSmoothstep(float edge0, float edge1, float x) {
    const float t = otClampf((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

__device__ __forceinline__ float otMix(float a, float b, float t) {
    return a + (b - a) * t;
}

__device__ __forceinline__ float3 otMix3(float3 a, float3 b, float t) {
    return make_float3(otMix(a.x, b.x, t), otMix(a.y, b.y, t), otMix(a.z, b.z, t));
}

__device__ __forceinline__ float otPresplitBandDetail(float lOrig, float b0, float b1, float b2, float b3, float b4, float b5, int band) {
    if (band == 0)
        return lOrig - b0;
    if (band == 1)
        return b0 - b1;
    if (band == 2)
        return b1 - b2;
    if (band == 3)
        return b2 - b3;
    if (band == 4)
        return b3 - b4;
    return b4 - b5;
}

__device__ __forceinline__ float otPresplitWeightedDetail(float lOrig, float b0, float b1, float b2, float b3, float b4, float b5,
                                                        const float* eq) {
    float acc = 0.0f;
    acc += eq[0] * (lOrig - b0);
    acc += eq[1] * (b0 - b1);
    acc += eq[2] * (b1 - b2);
    acc += eq[3] * (b2 - b3);
    acc += eq[4] * (b3 - b4);
    acc += eq[5] * (b4 - b5);
    return acc;
}

}

__global__ void otDecodeStridedRgbToLBuf(const float* __restrict__ srcStrided, float* __restrict__ rgbLinPacked, float* __restrict__ lSource,
                                         OpenTextureCudaParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    const int si = y * p.dstRowFloats + x * 4;
    const float3 enc = make_float3(otSanitizeFinite(srcStrided[si], 0.0f), otSanitizeFinite(srcStrided[si + 1], 0.0f),
                                   otSanitizeFinite(srcStrided[si + 2], 0.0f));
    const float a = otSanitizeFinite(srcStrided[si + 3], 1.0f);
    const float3 c = otHostToWorking(enc, p);
    const int di = (y * p.width + x) * 4;
    rgbLinPacked[di] = c.x;
    rgbLinPacked[di + 1] = c.y;
    rgbLinPacked[di + 2] = c.z;
    rgbLinPacked[di + 3] = a;
    lSource[y * p.width + x] = otRgbToLabL709(c);
}

__global__ void otPresplitFusedStridedBuf(const float* __restrict__ lOrig, const float* __restrict__ blur0, const float* __restrict__ blur1,
                                          const float* __restrict__ blur2, const float* __restrict__ blur3, const float* __restrict__ blur4,
                                          const float* __restrict__ blur5, const float* __restrict__ rgbLinPacked, float* __restrict__ dstStrided,
                                          OpenTextureCudaParams p, const float* __restrict__ eq, float blendTowardOriginal, float lumaBlend) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    const int i = y * p.width + x;
    const float lNorm0 = lOrig[i];
    const float b0 = blur0[i];
    const float b1 = blur1[i];
    const float b2 = blur2[i];
    const float b3 = blur3[i];
    const float b4 = blur4[i];
    const float b5 = blur5[i];
    const float lNorm1 = b5 + otPresplitWeightedDetail(lNorm0, b0, b1, b2, b3, b4, b5, eq);

    const int di = i * 4;
    const float3 px = make_float3(rgbLinPacked[di], rgbLinPacked[di + 1], rgbLinPacked[di + 2]);
    const float pa = rgbLinPacked[di + 3];

    const float3 xyz = otRgbToXyz709(px);
    const float fx = otLabF(xyz.x / kLabXn);
    const float fy = otLabF(xyz.y / kLabYn);
    const float fz = otLabF(xyz.z / kLabZn);
    const float aLab = 500.0f * (fx - fy);
    const float bLab = 200.0f * (fy - fz);
    float l0 = lNorm0 * 100.0f;
    float l1 = lNorm1 * 100.0f;
    if (!isfinite(l0))
        l0 = 116.0f * fy - 16.0f;
    if (!isfinite(l1))
        l1 = l0;
    float t = otClampf(blendTowardOriginal, 0.0f, 1.0f);
    float l = l1 * (1.0f - t) + l0 * t;
    if (!isfinite(l))
        l = l0;

    const float cy = (l + 16.0f) / 116.0f;
    const float cx = aLab / 500.0f + cy;
    const float cz = cy - bLab / 200.0f;
    const float3 xyzLab = make_float3(kLabXn * otLabFi(cx), kLabYn * otLabFi(cy), kLabZn * otLabFi(cz));
    float3 rgbLab = otXyzToRgb709(xyzLab);

    // lumaBlend 0 = scale rec709 Y only; 1 = full lab reconstruct (defualt path in ui)
    float lb = otClampf(lumaBlend, 0.0f, 1.0f);
    const float y1 = kLabYn * otLabFi(cy);
    const float yAbs = fabsf(xyz.y);
    float yScale = (yAbs > 1.0e-6f) ? (y1 / xyz.y) : 1.0f;
    yScale = otMix(1.0f, yScale, otSmoothstep(0.0f, 1.0e-4f, yAbs));
    const float3 rgbXy = make_float3(px.x * yScale, px.y * yScale, px.z * yScale);
    float3 rgb = otMix3(rgbXy, rgbLab, lb);
    rgb.x = fminf(rgb.x, kMaxLinearRgb);
    rgb.y = fminf(rgb.y, kMaxLinearRgb);
    rgb.z = fminf(rgb.z, kMaxLinearRgb);
    if (!isfinite(rgb.x) || !isfinite(rgb.y) || !isfinite(rgb.z))
        rgb = px;
    const float3 outEnc = otWorkingToHost(rgb, p);
    const int so = y * p.dstRowFloats + x * 4;
    dstStrided[so] = otSanitizeFinite(outEnc.x, 0.0f);
    dstStrided[so + 1] = otSanitizeFinite(outEnc.y, 0.0f);
    dstStrided[so + 2] = otSanitizeFinite(outEnc.z, 0.0f);
    dstStrided[so + 3] = pa;
}

__global__ void otPresplitAccumDetailBuf(const float* __restrict__ lOrig, const float* __restrict__ blur0, const float* __restrict__ blur1,
                                         const float* __restrict__ blur2, const float* __restrict__ blur3, const float* __restrict__ blur4,
                                         const float* __restrict__ blur5, float* __restrict__ acc, int width, int height,
                                         const float* __restrict__ eq) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= width || y >= height)
        return;
    const int i = y * width + x;
    acc[i] = otPresplitWeightedDetail(lOrig[i], blur0[i], blur1[i], blur2[i], blur3[i], blur4[i], blur5[i], eq);
}

__global__ void otPreviewBandPresplitStridedBuf(const float* __restrict__ lOrig, const float* __restrict__ blur0,
                                                const float* __restrict__ blur1, const float* __restrict__ blur2,
                                                const float* __restrict__ blur3, const float* __restrict__ blur4,
                                                const float* __restrict__ blur5, float* __restrict__ dstStrided, OpenTextureCudaParams p,
                                                float eq, int band, int greyBG) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    const int i = y * p.width + x;
    const float d = eq * otPresplitBandDetail(lOrig[i], blur0[i], blur1[i], blur2[i], blur3[i], blur4[i], blur5[i], band);
    const float base = (greyBG != 0) ? 0.5f : 0.0f;
    const float enc = d + base;
    const int so = y * p.dstRowFloats + x * 4;
    dstStrided[so] = enc;
    dstStrided[so + 1] = enc;
    dstStrided[so + 2] = enc;
    dstStrided[so + 3] = 1.0f;
}

__global__ void otPreviewAccumStridedBuf(const float* __restrict__ acc, float* __restrict__ dstStrided, OpenTextureCudaParams p, int greyBG) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    const float a = acc[y * p.width + x];
    const float base = (greyBG != 0) ? 0.5f : 0.0f;
    const float enc = a + base;
    const int so = y * p.dstRowFloats + x * 4;
    dstStrided[so] = enc;
    dstStrided[so + 1] = enc;
    dstStrided[so + 2] = enc;
    dstStrided[so + 3] = 1.0f;
}

cudaError_t otLaunchDecodeStridedRgbToL(const float* srcStrided, float* rgbLinPacked, float* lSource, const OpenTextureCudaParams& p,
                                        cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otDecodeStridedRgbToLBuf<<<grid, block, 0, stream>>>(srcStrided, rgbLinPacked, lSource, p);
    return cudaGetLastError();
}

cudaError_t otLaunchPresplitFusedStrided(const float* lOrig, const float* blur0, const float* blur1, const float* blur2, const float* blur3,
                                         const float* blur4, const float* blur5, const float* rgbLinPacked, float* dstStrided,
                                         const OpenTextureCudaParams& p, const float* eqDev, float blendTowardOriginal, float lumaBlend,
                                         cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otPresplitFusedStridedBuf<<<grid, block, 0, stream>>>(lOrig, blur0, blur1, blur2, blur3, blur4, blur5, rgbLinPacked, dstStrided, p,
                                                          eqDev, blendTowardOriginal, lumaBlend);
    return cudaGetLastError();
}

cudaError_t otLaunchPresplitAccumDetail(const float* lOrig, const float* blur0, const float* blur1, const float* blur2, const float* blur3,
                                        const float* blur4, const float* blur5, float* acc, int width, int height, const float* eqDev,
                                        cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((width + 15) / 16), static_cast<unsigned>((height + 15) / 16), 1u);
    otPresplitAccumDetailBuf<<<grid, block, 0, stream>>>(lOrig, blur0, blur1, blur2, blur3, blur4, blur5, acc, width, height, eqDev);
    return cudaGetLastError();
}

cudaError_t otLaunchPreviewBandPresplitStrided(const float* lOrig, const float* blur0, const float* blur1, const float* blur2,
                                               const float* blur3, const float* blur4, const float* blur5, float* dstStrided,
                                               const OpenTextureCudaParams& p, float eq, int band, int greyBG, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otPreviewBandPresplitStridedBuf<<<grid, block, 0, stream>>>(lOrig, blur0, blur1, blur2, blur3, blur4, blur5, dstStrided, p, eq, band,
                                                                  greyBG);
    return cudaGetLastError();
}

cudaError_t otLaunchPreviewAccumStrided(const float* acc, float* dstStrided, const OpenTextureCudaParams& p, int greyBG, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otPreviewAccumStridedBuf<<<grid, block, 0, stream>>>(acc, dstStrided, p, greyBG);
    return cudaGetLastError();
}
