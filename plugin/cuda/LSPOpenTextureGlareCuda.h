#pragma once

#include <cuda_runtime.h>

#include "../core/LSPOpenTextureMetalParams.h"
#include "../metal/LSPOpenTextureGlareParams.h"

namespace LSPOpenTextureGlareCuda {

bool EncodeCuda(
    float* dstStrided,
    const LSPOpenTextureMetalParamsHost& io,
    const LSPOpenTextureGlareParamsHost& glare,
    float globalBlend,
    cudaStream_t stream);

}
