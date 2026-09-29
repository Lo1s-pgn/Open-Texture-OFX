#pragma once

#import <Metal/Metal.h>

#include <cstddef>

struct LSPOpenTextureHostParams;
struct LSPOpenTextureGlareParamsHost;

bool LSPOpenTextureGlare_EncodeToCommandBuffer(
    id<MTLCommandBuffer> cmd,
    id<MTLDevice> device,
    id<MTLBuffer> dstStrided,
    size_t dstOffset,
    const LSPOpenTextureHostParams& io,
    const LSPOpenTextureGlareParamsHost& glare,
    float globalBlend,
    id<MTLComputePipelineState> windowEdgeReplicateTexturePso,
    id<MTLComputePipelineState> globalBlendPso);
