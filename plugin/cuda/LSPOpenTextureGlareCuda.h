#pragma once

#include <cuda_runtime.h>

#include "../core/LSPOpenTextureHostParams.h"
#include "../core/LSPOpenTextureGlareParams.h"

namespace LSPOpenTextureGlareCuda {

bool EncodeCuda(
    float* dstStrided,
    const LSPOpenTextureHostParams& io,
    const LSPOpenTextureGlareParamsHost& glare,
    float globalBlend,
    cudaStream_t stream);

}
