#include "LSPOpenTextureCudaCommon.cuh"

#include <cuda_runtime.h>

__global__ void otPreprocessPackedKernel(const float* __restrict__ src, float* __restrict__ pre, OpenTextureCudaParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    const int iSrc = y * p.srcRowFloats + x * 4;
    const int iPre = (y * p.width + x) * 4;
    const float3 inRgb = make_float3(otSanitizeFinite(src[iSrc], 0.0f), otSanitizeFinite(src[iSrc + 1], 0.0f),
                                     otSanitizeFinite(src[iSrc + 2], 0.0f));
    const float gamma = otClampf(p.distribution, 0.6f, 1.0f);
    const float wp = otWhitepointForTf(p.workingTransferFunction);
    float3 lin = otHostToWorking(inRgb, p);
    lin = otScaleLinearForBlurDistribution(lin, gamma, wp, p.cieLumaCoeffs);
    pre[iPre] = lin.x;
    pre[iPre + 1] = lin.y;
    pre[iPre + 2] = lin.z;
    pre[iPre + 3] = 1.0f;
}

__global__ void otCompositePackedKernel(const float* __restrict__ src, const float* __restrict__ blurred, float* __restrict__ dst,
                                        OpenTextureCudaParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    const int iSrc = y * p.srcRowFloats + x * 4;
    const int iBlur = (y * p.width + x) * 4;
    const int iDst = y * p.dstRowFloats + x * 4;
    const float3 inRgb = make_float3(otSanitizeFinite(src[iSrc], 0.0f), otSanitizeFinite(src[iSrc + 1], 0.0f),
                                     otSanitizeFinite(src[iSrc + 2], 0.0f));
    const float srcA = otSanitizeFinite(src[iSrc + 3], 1.0f);
    const float3 blurRgb = make_float3(otSanitizeFinite(blurred[iBlur], 0.0f), otSanitizeFinite(blurred[iBlur + 1], 0.0f),
                                       otSanitizeFinite(blurred[iBlur + 2], 0.0f));
    const float3 outRgb = otComposeTfHalation(inRgb, blurRgb, p);
    dst[iDst] = otSanitizeFinite(outRgb.x, inRgb.x);
    dst[iDst + 1] = otSanitizeFinite(outRgb.y, inRgb.y);
    dst[iDst + 2] = otSanitizeFinite(outRgb.z, inRgb.z);
    dst[iDst + 3] = srcA;
}

__global__ void otRegionCopyKernel(const float* __restrict__ src, float* __restrict__ dst, OpenTextureCudaParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    const int si = y * p.srcRowFloats + x * 4;
    const int di = y * p.dstRowFloats + x * 4;
    dst[di] = otSanitizeFinite(src[si], 0.0f);
    dst[di + 1] = otSanitizeFinite(src[si + 1], 0.0f);
    dst[di + 2] = otSanitizeFinite(src[si + 2], 0.0f);
    dst[di + 3] = otSanitizeFinite(src[si + 3], 1.0f);
}

__global__ void otGlobalBlendKernel(const float* __restrict__ src, float* __restrict__ dst, OpenTextureCudaParams p, float mixEffect) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    const int si = y * p.srcRowFloats + x * 4;
    const int di = y * p.dstRowFloats + x * 4;
    const float g = otClampf(mixEffect, 0.0f, 1.0f);
    const float om = 1.0f - g;
    if (p.showDistribution != 0) {
        dst[di] = g * otSanitizeFinite(dst[di], 0.0f);
        dst[di + 1] = g * otSanitizeFinite(dst[di + 1], 0.0f);
        dst[di + 2] = g * otSanitizeFinite(dst[di + 2], 0.0f);
        dst[di + 3] = otSanitizeFinite(src[si + 3], 1.0f);
        return;
    }
    for (int c = 0; c < 4; ++c) {
        const float s = otSanitizeFinite(src[si + c], c == 3 ? 1.0f : 0.0f);
        const float d = otSanitizeFinite(dst[di + c], s);
        dst[di + c] = om * s + g * d;
    }
}

__global__ void otWindowEdgeReplicateDenseKernel(float* __restrict__ buf, OpenTextureCudaParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    if (p.effectWindowEnabled == 0 || otHalationInEffectWindow(x, y, p))
        return;
    const int x1 = static_cast<int>(floorf(p.effectWindowLeft));
    const int y1 = static_cast<int>(floorf(p.effectWindowTop));
    int x2 = static_cast<int>(ceilf(p.effectWindowLeft + p.effectWindowWidth));
    int y2 = static_cast<int>(ceilf(p.effectWindowTop + p.effectWindowHeight));
    x2 = max(x1 + 1, min(x2, p.width));
    y2 = max(y1 + 1, min(y2, p.height));
    const int cx = otHalationClampWindowCoord(x, x1, x2);
    const int cy = otHalationClampWindowCoord(y, y1, y2);
    const int di = (y * p.width + x) * 4;
    const int si = (cy * p.width + cx) * 4;
    buf[di] = buf[si];
    buf[di + 1] = buf[si + 1];
    buf[di + 2] = buf[si + 2];
    buf[di + 3] = buf[si + 3];
}

__global__ void otWindowEdgeReplicateStridedKernel(float* __restrict__ buf, OpenTextureCudaParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    if (p.effectWindowEnabled == 0 || otHalationInEffectWindow(x, y, p))
        return;
    const int x1 = static_cast<int>(floorf(p.effectWindowLeft));
    const int y1 = static_cast<int>(floorf(p.effectWindowTop));
    int x2 = static_cast<int>(ceilf(p.effectWindowLeft + p.effectWindowWidth));
    int y2 = static_cast<int>(ceilf(p.effectWindowTop + p.effectWindowHeight));
    x2 = max(x1 + 1, min(x2, p.width));
    y2 = max(y1 + 1, min(y2, p.height));
    const int cx = otHalationClampWindowCoord(x, x1, x2);
    const int cy = otHalationClampWindowCoord(y, y1, y2);
    const int di = y * p.dstRowFloats + x * 4;
    const int si = cy * p.dstRowFloats + cx * 4;
    buf[di] = buf[si];
    buf[di + 1] = buf[si + 1];
    buf[di + 2] = buf[si + 2];
    buf[di + 3] = buf[si + 3];
}

__global__ void otWindowBlackMaskKernel(float* __restrict__ dst, OpenTextureCudaParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    if (p.effectWindowEnabled == 0 || otHalationInEffectWindow(x, y, p))
        return;
    const int di = y * p.dstRowFloats + x * 4;
    dst[di] = 0.0f;
    dst[di + 1] = 0.0f;
    dst[di + 2] = 0.0f;
}

__global__ void otWindowBorderKernel(float* __restrict__ dst, OpenTextureCudaParams p) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= p.width || y >= p.height)
        return;
    if (p.effectWindowEnabled == 0 || p.effectWindowShowBorder == 0)
        return;
    if (!otHalationEffectWindowPixelOnBorder(x, y, p, 4.0f))
        return;
    const int di = y * p.dstRowFloats + x * 4;
    dst[di] = 0.5f;
    dst[di + 1] = 0.0f;
    dst[di + 2] = 0.0f;
}


cudaError_t otLaunchPreprocessPacked(const float* src, float* pre, const OpenTextureCudaParams& p, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otPreprocessPackedKernel<<<grid, block, 0, stream>>>(src, pre, p);
    return cudaGetLastError();
}

cudaError_t otLaunchCompositePacked(const float* src, const float* blurred, float* dst, const OpenTextureCudaParams& p,
                                    cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otCompositePackedKernel<<<grid, block, 0, stream>>>(src, blurred, dst, p);
    return cudaGetLastError();
}

cudaError_t otLaunchRegionCopy(const float* src, float* dst, const OpenTextureCudaParams& p, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otRegionCopyKernel<<<grid, block, 0, stream>>>(src, dst, p);
    return cudaGetLastError();
}

cudaError_t otLaunchGlobalBlend(const float* src, float* dst, const OpenTextureCudaParams& p, float mixEffect, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otGlobalBlendKernel<<<grid, block, 0, stream>>>(src, dst, p, mixEffect);
    return cudaGetLastError();
}

cudaError_t otLaunchWindowEdgeReplicateDense(float* buf, const OpenTextureCudaParams& p, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otWindowEdgeReplicateDenseKernel<<<grid, block, 0, stream>>>(buf, p);
    return cudaGetLastError();
}

cudaError_t otLaunchWindowEdgeReplicateStrided(float* buf, const OpenTextureCudaParams& p, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otWindowEdgeReplicateStridedKernel<<<grid, block, 0, stream>>>(buf, p);
    return cudaGetLastError();
}

cudaError_t otLaunchWindowBlackMask(float* dst, const OpenTextureCudaParams& p, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otWindowBlackMaskKernel<<<grid, block, 0, stream>>>(dst, p);
    return cudaGetLastError();
}

cudaError_t otLaunchWindowBorder(float* dst, const OpenTextureCudaParams& p, cudaStream_t stream) {
    const dim3 block(16, 16, 1);
    const dim3 grid(static_cast<unsigned>((p.width + 15) / 16), static_cast<unsigned>((p.height + 15) / 16), 1u);
    otWindowBorderKernel<<<grid, block, 0, stream>>>(dst, p);
    return cudaGetLastError();
}
