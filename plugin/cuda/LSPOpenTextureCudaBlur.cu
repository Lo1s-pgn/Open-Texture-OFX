#include "LSPOpenTextureCudaCommon.cuh"
#include "../core/LSPOpenTextureVanVliet.h"
#include "../core/LSPOpenTextureTextureFormats.h"

#include <algorithm>
#include <cuda_runtime.h>

extern cudaError_t otUploadVanVlietCoeffs(const float coeffs[4], cudaStream_t stream);
extern cudaError_t otLaunchHorizontalVanVlietRGBA(int width, int height, const float* input, float* output, cudaStream_t stream);
extern cudaError_t otLaunchVerticalVanVlietRGBA(int width, int height, const float* input, float* output, cudaStream_t stream);
extern cudaError_t otLaunchHorizontalVanVlietScalar(int width, int height, const float* input, float* output, cudaStream_t stream);
extern cudaError_t otLaunchVerticalVanVlietScalar(int width, int height, const float* input, float* output, cudaStream_t stream);

namespace {

__device__ __forceinline__ float3 otBilinearSampleRGBA(const float* buf, int sw, int sh, float fx, float fy) {
    const float cx = otClampf(fx, 0.0f, static_cast<float>(sw - 1));
    const float cy = otClampf(fy, 0.0f, static_cast<float>(sh - 1));
    const int x0 = static_cast<int>(floorf(cx));
    const int y0 = static_cast<int>(floorf(cy));
    const int x1 = min(x0 + 1, sw - 1);
    const int y1 = min(y0 + 1, sh - 1);
    const float tx = cx - static_cast<float>(x0);
    const float ty = cy - static_cast<float>(y0);
    const int i00 = (y0 * sw + x0) * 4;
    const int i10 = (y0 * sw + x1) * 4;
    const int i01 = (y1 * sw + x0) * 4;
    const int i11 = (y1 * sw + x1) * 4;
    const float3 c00 = make_float3(buf[i00], buf[i00 + 1], buf[i00 + 2]);
    const float3 c10 = make_float3(buf[i10], buf[i10 + 1], buf[i10 + 2]);
    const float3 c01 = make_float3(buf[i01], buf[i01 + 1], buf[i01 + 2]);
    const float3 c11 = make_float3(buf[i11], buf[i11 + 1], buf[i11 + 2]);
    const float3 c0 = make_float3(c00.x * (1.0f - tx) + c10.x * tx, c00.y * (1.0f - tx) + c10.y * tx, c00.z * (1.0f - tx) + c10.z * tx);
    const float3 c1 = make_float3(c01.x * (1.0f - tx) + c11.x * tx, c01.y * (1.0f - tx) + c11.y * tx, c01.z * (1.0f - tx) + c11.z * tx);
    return make_float3(c0.x * (1.0f - ty) + c1.x * ty, c0.y * (1.0f - ty) + c1.y * ty, c0.z * (1.0f - ty) + c1.z * ty);
}

__global__ void otBilinearDownscaleRGBA(int sw, int sh, int dw, int dh, const float* __restrict__ src, float* __restrict__ dst) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= dw || y >= dh)
        return;
    const float fx = ((static_cast<float>(x) + 0.5f) * static_cast<float>(sw) / static_cast<float>(dw)) - 0.5f;
    const float fy = ((static_cast<float>(y) + 0.5f) * static_cast<float>(sh) / static_cast<float>(dh)) - 0.5f;
    const float3 c = otBilinearSampleRGBA(src, sw, sh, fx, fy);
    const int di = (y * dw + x) * 4;
    dst[di] = c.x;
    dst[di + 1] = c.y;
    dst[di + 2] = c.z;
    dst[di + 3] = 1.0f;
}

__global__ void otBilinearUpscaleRGBA(int sw, int sh, int dw, int dh, const float* __restrict__ src, float* __restrict__ dst) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= dw || y >= dh)
        return;
    const float fx = ((static_cast<float>(x) + 0.5f) * static_cast<float>(sw) / static_cast<float>(dw)) - 0.5f;
    const float fy = ((static_cast<float>(y) + 0.5f) * static_cast<float>(sh) / static_cast<float>(dh)) - 0.5f;
    const float3 c = otBilinearSampleRGBA(src, sw, sh, fx, fy);
    const int di = (y * dw + x) * 4;
    dst[di] = c.x;
    dst[di + 1] = c.y;
    dst[di + 2] = c.z;
    dst[di + 3] = 1.0f;
}

__global__ void otBilinearDownscaleScalar(int sw, int sh, int dw, int dh, const float* __restrict__ src, float* __restrict__ dst) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= dw || y >= dh)
        return;
    const float fx = ((static_cast<float>(x) + 0.5f) * static_cast<float>(sw) / static_cast<float>(dw)) - 0.5f;
    const float fy = ((static_cast<float>(y) + 0.5f) * static_cast<float>(sh) / static_cast<float>(dh)) - 0.5f;
    const float cx = otClampf(fx, 0.0f, static_cast<float>(sw - 1));
    const float cy = otClampf(fy, 0.0f, static_cast<float>(sh - 1));
    const int x0 = static_cast<int>(floorf(cx));
    const int y0 = static_cast<int>(floorf(cy));
    const int x1 = min(x0 + 1, sw - 1);
    const int y1 = min(y0 + 1, sh - 1);
    const float tx = cx - static_cast<float>(x0);
    const float ty = cy - static_cast<float>(y0);
    const float c00 = src[y0 * sw + x0];
    const float c10 = src[y0 * sw + x1];
    const float c01 = src[y1 * sw + x0];
    const float c11 = src[y1 * sw + x1];
    const float c0 = c00 * (1.0f - tx) + c10 * tx;
    const float c1 = c01 * (1.0f - tx) + c11 * tx;
    dst[y * dw + x] = c0 * (1.0f - ty) + c1 * ty;
}

__global__ void otBilinearUpscaleScalar(int sw, int sh, int dw, int dh, const float* __restrict__ src, float* __restrict__ dst) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= dw || y >= dh)
        return;
    const float fx = ((static_cast<float>(x) + 0.5f) * static_cast<float>(sw) / static_cast<float>(dw)) - 0.5f;
    const float fy = ((static_cast<float>(y) + 0.5f) * static_cast<float>(sh) / static_cast<float>(dh)) - 0.5f;
    const float cx = otClampf(fx, 0.0f, static_cast<float>(sw - 1));
    const float cy = otClampf(fy, 0.0f, static_cast<float>(sh - 1));
    const int x0 = static_cast<int>(floorf(cx));
    const int y0 = static_cast<int>(floorf(cy));
    const int x1 = min(x0 + 1, sw - 1);
    const int y1 = min(y0 + 1, sh - 1);
    const float tx = cx - static_cast<float>(x0);
    const float ty = cy - static_cast<float>(y0);
    const float c00 = src[y0 * sw + x0];
    const float c10 = src[y0 * sw + x1];
    const float c01 = src[y1 * sw + x0];
    const float c11 = src[y1 * sw + x1];
    const float c0 = c00 * (1.0f - tx) + c10 * tx;
    const float c1 = c01 * (1.0f - tx) + c11 * tx;
    dst[y * dw + x] = c0 * (1.0f - ty) + c1 * ty;
}

cudaError_t otVanVlietBlurRGBAInternal(int width, int height, float mpsSigma, const float* src, float* dst, float* scratchA,
                                       float* scratchB, cudaStream_t stream) {
    (void)scratchB;
    const int radius = vanVlietRadiusFromMpsSigma(mpsSigma);
    float coeffs[4];
    fillVanVlietCoeffsFromRadius(radius, coeffs);
    OT_CUDA_CHECK(otUploadVanVlietCoeffs(coeffs, stream));
    OT_CUDA_CHECK(otLaunchHorizontalVanVlietRGBA(width, height, src, scratchA, stream));
    OT_CUDA_CHECK(otLaunchVerticalVanVlietRGBA(width, height, scratchA, dst, stream));
    return cudaSuccess;
}

cudaError_t otVanVlietBlurScalarInternal(int width, int height, float mpsSigma, const float* src, float* dst, float* scratchA,
                                         float* scratchB, cudaStream_t stream) {
    (void)scratchB;
    const int radius = vanVlietRadiusFromMpsSigma(mpsSigma);
    float coeffs[4];
    fillVanVlietCoeffsFromRadius(radius, coeffs);
    OT_CUDA_CHECK(otUploadVanVlietCoeffs(coeffs, stream));
    OT_CUDA_CHECK(otLaunchHorizontalVanVlietScalar(width, height, src, scratchA, stream));
    OT_CUDA_CHECK(otLaunchVerticalVanVlietScalar(width, height, scratchA, dst, stream));
    return cudaSuccess;
}

}

cudaError_t otLaunchBilinearDownscaleRGBA(int sw, int sh, int dw, int dh, const float* src, float* dst, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((dw + 15) / 16), static_cast<unsigned>((dh + 15) / 16), 1u);
    otBilinearDownscaleRGBA<<<grid, block, 0, stream>>>(sw, sh, dw, dh, src, dst);
    return cudaGetLastError();
}

cudaError_t otLaunchBilinearUpscaleRGBA(int sw, int sh, int dw, int dh, const float* src, float* dst, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((dw + 15) / 16), static_cast<unsigned>((dh + 15) / 16), 1u);
    otBilinearUpscaleRGBA<<<grid, block, 0, stream>>>(sw, sh, dw, dh, src, dst);
    return cudaGetLastError();
}

cudaError_t otLaunchBilinearDownscaleScalar(int sw, int sh, int dw, int dh, const float* src, float* dst, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((dw + 15) / 16), static_cast<unsigned>((dh + 15) / 16), 1u);
    otBilinearDownscaleScalar<<<grid, block, 0, stream>>>(sw, sh, dw, dh, src, dst);
    return cudaGetLastError();
}

cudaError_t otLaunchBilinearUpscaleScalar(int sw, int sh, int dw, int dh, const float* src, float* dst, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((dw + 15) / 16), static_cast<unsigned>((dh + 15) / 16), 1u);
    otBilinearUpscaleScalar<<<grid, block, 0, stream>>>(sw, sh, dw, dh, src, dst);
    return cudaGetLastError();
}

cudaError_t blurRGBA_VanVliet(float* dst, const float* src, int width, int height, float sigma, float* scratchA, float* scratchB,
                              float* pyramidSrc, float* pyramidBlur, cudaStream_t stream) {
    if (!dst || !src || width <= 0 || height <= 0 || !scratchA || !scratchB)
        return cudaErrorInvalidValue;
    const float mpsSigma = sigma < 0.1f ? 0.1f : sigma;
    if (!openTextureUsePyramidBlur(mpsSigma))
        return otVanVlietBlurRGBAInternal(width, height, mpsSigma, src, dst, scratchA, scratchB, stream);

    const int pw = std::max((width + 1) / 2, 1);
    const int ph = std::max((height + 1) / 2, 1);
    if (!pyramidSrc || !pyramidBlur)
        return cudaErrorInvalidValue;
    const float pyramidSigma = mpsSigma * 0.5f;
    OT_CUDA_CHECK(otLaunchBilinearDownscaleRGBA(width, height, pw, ph, src, pyramidSrc, stream));
    OT_CUDA_CHECK(otVanVlietBlurRGBAInternal(pw, ph, pyramidSigma, pyramidSrc, pyramidBlur, scratchA, scratchB, stream));
    OT_CUDA_CHECK(otLaunchBilinearUpscaleRGBA(pw, ph, width, height, pyramidBlur, dst, stream));
    return cudaSuccess;
}

cudaError_t blurScalar_VanVliet(float* dst, const float* src, int width, int height, float sigma, float* scratchA, float* scratchB,
                                float* pyramidSrc, float* pyramidBlur, int pyramidLevels, cudaStream_t stream) {
    if (!dst || !src || width <= 0 || height <= 0 || !scratchA || !scratchB)
        return cudaErrorInvalidValue;
    const float mpsSigma = sigma < 0.1f ? 0.1f : sigma;
    if (pyramidLevels <= 0)
        return otVanVlietBlurScalarInternal(width, height, mpsSigma, src, dst, scratchA, scratchB, stream);
    if (!pyramidSrc || !pyramidBlur)
        return cudaErrorInvalidValue;

    int pw = width;
    int ph = height;
    float blurSigma = mpsSigma;
    for (int i = 0; i < pyramidLevels; ++i) {
        pw = std::max((pw + 1) / 2, 1);
        ph = std::max((ph + 1) / 2, 1);
        blurSigma *= 0.5f;
    }

    OT_CUDA_CHECK(otLaunchBilinearDownscaleScalar(width, height, pw, ph, src, pyramidSrc, stream));
    OT_CUDA_CHECK(otVanVlietBlurScalarInternal(pw, ph, blurSigma, pyramidSrc, pyramidBlur, scratchA, scratchB, stream));
    OT_CUDA_CHECK(otLaunchBilinearUpscaleScalar(pw, ph, width, height, pyramidBlur, dst, stream));
    return cudaSuccess;
}
