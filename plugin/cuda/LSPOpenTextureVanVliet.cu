#include "LSPOpenTextureCudaCommon.cuh"

#include <cuda_runtime.h>

__constant__ float g_openTextureVanVlietCoeffs[4];

namespace {

constexpr int kVanVlietWarmup = 128;

__device__ __forceinline__ float3 otSampleRGBA(const float* buf, int width, int x) {
    const int idx = x * 4;
    return make_float3(buf[idx], buf[idx + 1], buf[idx + 2]);
}

}

__global__ void otHorizontalVanVlietRGBA(int width, int height, const float* __restrict__ input, float* __restrict__ output) {
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (y >= height)
        return;

    const float B = g_openTextureVanVlietCoeffs[0];
    const float f1 = g_openTextureVanVlietCoeffs[1];
    const float f2 = g_openTextureVanVlietCoeffs[2];
    const float f3 = g_openTextureVanVlietCoeffs[3];

    const int base = y * width * 4;
    float3 edge0 = otSampleRGBA(input + base, width, 0);
    float3 s0 = edge0;
    float3 s1 = edge0;
    float3 s2 = edge0;

    const int fwW = (kVanVlietWarmup < width - 1) ? kVanVlietWarmup : (width - 1);
    for (int k = fwW; k >= 1; --k) {
        const int mi = base + ((k < width - 1) ? k : (width - 1)) * 4;
        const float3 wv = make_float3(input[mi], input[mi + 1], input[mi + 2]);
        float3 wo = make_float3(B * wv.x + f1 * s0.x + f2 * s1.x + f3 * s2.x, B * wv.y + f1 * s0.y + f2 * s1.y + f3 * s2.y,
                                B * wv.z + f1 * s0.z + f2 * s1.z + f3 * s2.z);
        wo.x = fmaxf(wo.x, 0.0f);
        wo.y = fmaxf(wo.y, 0.0f);
        wo.z = fmaxf(wo.z, 0.0f);
        s2 = s1;
        s1 = s0;
        s0 = wo;
    }
    for (int x = 0; x < width; ++x) {
        const int idx = base + x * 4;
        const float3 inVal = make_float3(input[idx], input[idx + 1], input[idx + 2]);
        float3 outVal = make_float3(B * inVal.x + f1 * s0.x + f2 * s1.x + f3 * s2.x, B * inVal.y + f1 * s0.y + f2 * s1.y + f3 * s2.y,
                                    B * inVal.z + f1 * s0.z + f2 * s1.z + f3 * s2.z);
        outVal.x = fmaxf(outVal.x, 0.0f);
        outVal.y = fmaxf(outVal.y, 0.0f);
        outVal.z = fmaxf(outVal.z, 0.0f);
        output[idx] = outVal.x;
        output[idx + 1] = outVal.y;
        output[idx + 2] = outVal.z;
        output[idx + 3] = 1.0f;
        s2 = s1;
        s1 = s0;
        s0 = outVal;
    }

    const int ri = base + (width - 1) * 4;
    float3 edgeR = make_float3(output[ri], output[ri + 1], output[ri + 2]);
    s0 = edgeR;
    s1 = edgeR;
    s2 = edgeR;
    const int bwW = (kVanVlietWarmup < width - 1) ? kVanVlietWarmup : (width - 1);
    for (int k = bwW; k >= 1; --k) {
        const int mi = base + ((width - k) > 0 ? (width - k) : 0) * 4;
        const float3 wv = make_float3(output[mi], output[mi + 1], output[mi + 2]);
        float3 wo = make_float3(B * wv.x + f1 * s0.x + f2 * s1.x + f3 * s2.x, B * wv.y + f1 * s0.y + f2 * s1.y + f3 * s2.y,
                                B * wv.z + f1 * s0.z + f2 * s1.z + f3 * s2.z);
        wo.x = fmaxf(wo.x, 0.0f);
        wo.y = fmaxf(wo.y, 0.0f);
        wo.z = fmaxf(wo.z, 0.0f);
        s2 = s1;
        s1 = s0;
        s0 = wo;
    }
    for (int x = width - 1; x >= 0; --x) {
        const int idx = base + x * 4;
        const float3 cur = make_float3(output[idx], output[idx + 1], output[idx + 2]);
        float3 outVal = make_float3(B * cur.x + f1 * s0.x + f2 * s1.x + f3 * s2.x, B * cur.y + f1 * s0.y + f2 * s1.y + f3 * s2.y,
                                    B * cur.z + f1 * s0.z + f2 * s1.z + f3 * s2.z);
        outVal.x = fmaxf(outVal.x, 0.0f);
        outVal.y = fmaxf(outVal.y, 0.0f);
        outVal.z = fmaxf(outVal.z, 0.0f);
        output[idx] = outVal.x;
        output[idx + 1] = outVal.y;
        output[idx + 2] = outVal.z;
        s2 = s1;
        s1 = s0;
        s0 = outVal;
    }
}

__global__ void otVerticalVanVlietRGBA(int width, int height, const float* __restrict__ input, float* __restrict__ output) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    if (x >= width)
        return;

    const float B = g_openTextureVanVlietCoeffs[0];
    const float f1 = g_openTextureVanVlietCoeffs[1];
    const float f2 = g_openTextureVanVlietCoeffs[2];
    const float f3 = g_openTextureVanVlietCoeffs[3];

    const float edge0r = input[x * 4];
    const float edge0g = input[x * 4 + 1];
    const float edge0b = input[x * 4 + 2];
    float s0r = edge0r, s1r = edge0r, s2r = edge0r;
    float s0g = edge0g, s1g = edge0g, s2g = edge0g;
    float s0b = edge0b, s1b = edge0b, s2b = edge0b;

    const int fwW = (kVanVlietWarmup < height - 1) ? kVanVlietWarmup : (height - 1);
    for (int k = fwW; k >= 1; --k) {
        const int mi = ((k < height - 1 ? k : height - 1) * width + x) * 4;
        const float wvr = input[mi];
        const float wvg = input[mi + 1];
        const float wvb = input[mi + 2];
        const float wor = fmaxf(B * wvr + f1 * s0r + f2 * s1r + f3 * s2r, 0.0f);
        const float wog = fmaxf(B * wvg + f1 * s0g + f2 * s1g + f3 * s2g, 0.0f);
        const float wob = fmaxf(B * wvb + f1 * s0b + f2 * s1b + f3 * s2b, 0.0f);
        s2r = s1r;
        s1r = s0r;
        s0r = wor;
        s2g = s1g;
        s1g = s0g;
        s0g = wog;
        s2b = s1b;
        s1b = s0b;
        s0b = wob;
    }
    for (int y = 0; y < height; ++y) {
        const int idx = (y * width + x) * 4;
        const float ir = input[idx];
        const float ig = input[idx + 1];
        const float ib = input[idx + 2];
        const float orv = fmaxf(B * ir + f1 * s0r + f2 * s1r + f3 * s2r, 0.0f);
        const float og = fmaxf(B * ig + f1 * s0g + f2 * s1g + f3 * s2g, 0.0f);
        const float ob = fmaxf(B * ib + f1 * s0b + f2 * s1b + f3 * s2b, 0.0f);
        output[idx] = orv;
        output[idx + 1] = og;
        output[idx + 2] = ob;
        output[idx + 3] = 1.0f;
        s2r = s1r;
        s1r = s0r;
        s0r = orv;
        s2g = s1g;
        s1g = s0g;
        s0g = og;
        s2b = s1b;
        s1b = s0b;
        s0b = ob;
    }

    const int lastIdx = ((height - 1) * width + x) * 4;
    s0r = output[lastIdx];
    s1r = s0r;
    s2r = s0r;
    s0g = output[lastIdx + 1];
    s1g = s0g;
    s2g = s0g;
    s0b = output[lastIdx + 2];
    s1b = s0b;
    s2b = s0b;
    const int bwW = (kVanVlietWarmup < height - 1) ? kVanVlietWarmup : (height - 1);
    for (int k = bwW; k >= 1; --k) {
        const int mi = (((height - k) > 0 ? (height - k) : 0) * width + x) * 4;
        const float wvr = output[mi];
        const float wvg = output[mi + 1];
        const float wvb = output[mi + 2];
        const float wor = fmaxf(B * wvr + f1 * s0r + f2 * s1r + f3 * s2r, 0.0f);
        const float wog = fmaxf(B * wvg + f1 * s0g + f2 * s1g + f3 * s2g, 0.0f);
        const float wob = fmaxf(B * wvb + f1 * s0b + f2 * s1b + f3 * s2b, 0.0f);
        s2r = s1r;
        s1r = s0r;
        s0r = wor;
        s2g = s1g;
        s1g = s0g;
        s0g = wog;
        s2b = s1b;
        s1b = s0b;
        s0b = wob;
    }
    for (int y = height - 1; y >= 0; --y) {
        const int idx = (y * width + x) * 4;
        const float cr = output[idx];
        const float cg = output[idx + 1];
        const float cb = output[idx + 2];
        const float orv = fmaxf(B * cr + f1 * s0r + f2 * s1r + f3 * s2r, 0.0f);
        const float og = fmaxf(B * cg + f1 * s0g + f2 * s1g + f3 * s2g, 0.0f);
        const float ob = fmaxf(B * cb + f1 * s0b + f2 * s1b + f3 * s2b, 0.0f);
        output[idx] = orv;
        output[idx + 1] = og;
        output[idx + 2] = ob;
        s2r = s1r;
        s1r = s0r;
        s0r = orv;
        s2g = s1g;
        s1g = s0g;
        s0g = og;
        s2b = s1b;
        s1b = s0b;
        s0b = ob;
    }
}

__global__ void otHorizontalVanVlietScalar(int width, int height, const float* __restrict__ input, float* __restrict__ output) {
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (y >= height)
        return;

    const float B = g_openTextureVanVlietCoeffs[0];
    const float f1 = g_openTextureVanVlietCoeffs[1];
    const float f2 = g_openTextureVanVlietCoeffs[2];
    const float f3 = g_openTextureVanVlietCoeffs[3];

    const int base = y * width;
    float edge0 = input[base];
    float s0 = edge0;
    float s1 = edge0;
    float s2 = edge0;

    const int fwW = (kVanVlietWarmup < width - 1) ? kVanVlietWarmup : (width - 1);
    for (int k = fwW; k >= 1; --k) {
        const int mi = base + ((k < width - 1) ? k : (width - 1));
        const float wv = input[mi];
        float wo = fmaxf(B * wv + f1 * s0 + f2 * s1 + f3 * s2, 0.0f);
        s2 = s1;
        s1 = s0;
        s0 = wo;
    }
    for (int x = 0; x < width; ++x) {
        const int idx = base + x;
        const float inVal = input[idx];
        float outVal = fmaxf(B * inVal + f1 * s0 + f2 * s1 + f3 * s2, 0.0f);
        output[idx] = outVal;
        s2 = s1;
        s1 = s0;
        s0 = outVal;
    }

    const int ri = base + (width - 1);
    float edgeR = output[ri];
    s0 = edgeR;
    s1 = edgeR;
    s2 = edgeR;
    const int bwW = (kVanVlietWarmup < width - 1) ? kVanVlietWarmup : (width - 1);
    for (int k = bwW; k >= 1; --k) {
        const int mi = base + ((width - k) > 0 ? (width - k) : 0);
        const float wv = output[mi];
        float wo = fmaxf(B * wv + f1 * s0 + f2 * s1 + f3 * s2, 0.0f);
        s2 = s1;
        s1 = s0;
        s0 = wo;
    }
    for (int x = width - 1; x >= 0; --x) {
        const int idx = base + x;
        const float cur = output[idx];
        float outVal = fmaxf(B * cur + f1 * s0 + f2 * s1 + f3 * s2, 0.0f);
        output[idx] = outVal;
        s2 = s1;
        s1 = s0;
        s0 = outVal;
    }
}

__global__ void otVerticalVanVlietScalar(int width, int height, const float* __restrict__ input, float* __restrict__ output) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    if (x >= width)
        return;

    const float B = g_openTextureVanVlietCoeffs[0];
    const float f1 = g_openTextureVanVlietCoeffs[1];
    const float f2 = g_openTextureVanVlietCoeffs[2];
    const float f3 = g_openTextureVanVlietCoeffs[3];

    float s0 = input[x];
    float s1 = s0;
    float s2 = s0;

    const int fwW = (kVanVlietWarmup < height - 1) ? kVanVlietWarmup : (height - 1);
    for (int k = fwW; k >= 1; --k) {
        const int mi = (k < height - 1 ? k : height - 1) * width + x;
        const float wv = input[mi];
        float wo = fmaxf(B * wv + f1 * s0 + f2 * s1 + f3 * s2, 0.0f);
        s2 = s1;
        s1 = s0;
        s0 = wo;
    }
    for (int y = 0; y < height; ++y) {
        const int idx = y * width + x;
        const float inVal = input[idx];
        float outVal = fmaxf(B * inVal + f1 * s0 + f2 * s1 + f3 * s2, 0.0f);
        output[idx] = outVal;
        s2 = s1;
        s1 = s0;
        s0 = outVal;
    }

    const int lastIdx = (height - 1) * width + x;
    s0 = output[lastIdx];
    s1 = s0;
    s2 = s0;
    const int bwW = (kVanVlietWarmup < height - 1) ? kVanVlietWarmup : (height - 1);
    for (int k = bwW; k >= 1; --k) {
        const int mi = ((height - k) > 0 ? (height - k) : 0) * width + x;
        const float wv = output[mi];
        float wo = fmaxf(B * wv + f1 * s0 + f2 * s1 + f3 * s2, 0.0f);
        s2 = s1;
        s1 = s0;
        s0 = wo;
    }
    for (int y = height - 1; y >= 0; --y) {
        const int idx = y * width + x;
        const float cur = output[idx];
        float outVal = fmaxf(B * cur + f1 * s0 + f2 * s1 + f3 * s2, 0.0f);
        output[idx] = outVal;
        s2 = s1;
        s1 = s0;
        s0 = outVal;
    }
}

cudaError_t otUploadVanVlietCoeffs(const float coeffs[4], cudaStream_t stream) {
    return cudaMemcpyToSymbolAsync(g_openTextureVanVlietCoeffs, coeffs, sizeof(float) * 4, 0, cudaMemcpyHostToDevice, stream);
}

cudaError_t otLaunchHorizontalVanVlietRGBA(int width, int height, const float* input, float* output, cudaStream_t stream) {
    const dim3 block(1, 256, 1);
    const dim3 grid(1u, static_cast<unsigned>((height + 255) / 256), 1u);
    otHorizontalVanVlietRGBA<<<grid, block, 0, stream>>>(width, height, input, output);
    return cudaGetLastError();
}

cudaError_t otLaunchVerticalVanVlietRGBA(int width, int height, const float* input, float* output, cudaStream_t stream) {
    const dim3 block(256, 1, 1);
    const dim3 grid(static_cast<unsigned>((width + 255) / 256), 1u, 1u);
    otVerticalVanVlietRGBA<<<grid, block, 0, stream>>>(width, height, input, output);
    return cudaGetLastError();
}

cudaError_t otLaunchHorizontalVanVlietScalar(int width, int height, const float* input, float* output, cudaStream_t stream) {
    const dim3 block(1, 256, 1);
    const dim3 grid(1u, static_cast<unsigned>((height + 255) / 256), 1u);
    otHorizontalVanVlietScalar<<<grid, block, 0, stream>>>(width, height, input, output);
    return cudaGetLastError();
}

cudaError_t otLaunchVerticalVanVlietScalar(int width, int height, const float* input, float* output, cudaStream_t stream) {
    const dim3 block(256, 1, 1);
    const dim3 grid(static_cast<unsigned>((width + 255) / 256), 1u, 1u);
    otVerticalVanVlietScalar<<<grid, block, 0, stream>>>(width, height, input, output);
    return cudaGetLastError();
}
