#pragma once

#include <cuda_runtime.h>

#include "LSPOpenTextureCudaCommon.cuh"
#include "LSPOpenTextureGlareCudaParams.h"

cudaError_t otLaunchPreprocessPacked(const float* src, float* pre, const OpenTextureCudaParams& p, cudaStream_t stream);
cudaError_t otLaunchCompositePacked(const float* src, const float* blurred, float* dst, const OpenTextureCudaParams& p, cudaStream_t stream);
cudaError_t otLaunchRegionCopy(const float* src, float* dst, const OpenTextureCudaParams& p, cudaStream_t stream);
cudaError_t otLaunchGlobalBlend(const float* src, float* dst, const OpenTextureCudaParams& p, float mixEffect, cudaStream_t stream);
cudaError_t otLaunchWindowEdgeReplicateDense(float* buf, const OpenTextureCudaParams& p, cudaStream_t stream);
cudaError_t otLaunchWindowEdgeReplicateStrided(float* buf, const OpenTextureCudaParams& p, cudaStream_t stream);
cudaError_t otLaunchWindowBlackMask(float* dst, const OpenTextureCudaParams& p, cudaStream_t stream);
cudaError_t otLaunchWindowBorder(float* dst, const OpenTextureCudaParams& p, cudaStream_t stream);

cudaError_t blurRGBA_VanVliet(float* dst, const float* src, int width, int height, float sigma, float* scratchA, float* scratchB,
                              float* pyramidSrc, float* pyramidBlur, cudaStream_t stream);
cudaError_t blurScalar_VanVliet(float* dst, const float* src, int width, int height, float sigma, float* scratchA, float* scratchB,
                                float* pyramidSrc, float* pyramidBlur, int pyramidLevels, cudaStream_t stream);

cudaError_t otLaunchBilinearDownscaleRGBA(int sw, int sh, int dw, int dh, const float* src, float* dst, cudaStream_t stream);
cudaError_t otLaunchBilinearUpscaleRGBA(int sw, int sh, int dw, int dh, const float* src, float* dst, cudaStream_t stream);

cudaError_t otLaunchGlareDecodeStridedToPacked(const float* srcStrided, float* rgbLinPacked, OpenTextureCudaParams p, cudaStream_t stream);
cudaError_t otLaunchGlareHighlights(const float* inputPacked, float* outputPacked, const OpenTextureGlareParamsCuda& gp,
                                    OpenTextureCudaParams p, cudaStream_t stream);
cudaError_t otLaunchGlareCopyPacked(int w, int h, const float* src, float* dst, cudaStream_t stream);
cudaError_t otLaunchGlareLerpPacked(int w, int h, const float* a, const float* b, float* dst, float blend, cudaStream_t stream);
cudaError_t otLaunchGlareBloomUp(int ow, int oh, int iw, int ih, const float* inputPacked, float* outputPacked, cudaStream_t stream);
cudaError_t otLaunchGlareHalfResUp(int ow, int oh, int inW, int inH, const float* inputPacked, float* outputPacked, cudaStream_t stream);
cudaError_t otLaunchGlareMixEncode(const float* glarePacked, int glareW, int glareH, int frameW, int frameH, const float* baseStrided,
                                   float* dstStrided, const OpenTextureGlareParamsCuda& gp, OpenTextureCudaParams p, cudaStream_t stream);

cudaError_t otLaunchDecodeStridedRgbToL(const float* srcStrided, float* rgbLinPacked, float* lSource,
                                        const OpenTextureCudaParams& p, cudaStream_t stream);
cudaError_t otLaunchPresplitFusedStrided(const float* lOrig, const float* blur0, const float* blur1, const float* blur2,
                                         const float* blur3, const float* blur4, const float* blur5, const float* rgbLinPacked,
                                         float* dstStrided, const OpenTextureCudaParams& p, const float* eqDev,
                                         float blendTowardOriginal, float lumaBlend, cudaStream_t stream);
cudaError_t otLaunchPresplitAccumDetail(const float* lOrig, const float* blur0, const float* blur1, const float* blur2,
                                        const float* blur3, const float* blur4, const float* blur5, float* acc, int width, int height,
                                        const float* eqDev, cudaStream_t stream);
cudaError_t otLaunchPreviewBandPresplitStrided(const float* lOrig, const float* blur0, const float* blur1, const float* blur2,
                                               const float* blur3, const float* blur4, const float* blur5, float* dstStrided,
                                               const OpenTextureCudaParams& p, float eq, int band, int greyBG, cudaStream_t stream);
cudaError_t otLaunchPreviewAccumStrided(const float* acc, float* dstStrided, const OpenTextureCudaParams& p, int greyBG, cudaStream_t stream);
