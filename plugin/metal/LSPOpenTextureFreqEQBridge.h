#pragma once

#import <Metal/Metal.h>

#include <cstddef>

struct LSPOpenTextureMetalParamsHost;

bool LSPOpenTextureFreqEQ_IsIdentity(const float eq[8], int displaySwitch, float globalBlend);

bool LSPOpenTextureFreqEQ_EncodeToCommandBuffer(id<MTLCommandBuffer> cmd, id<MTLBuffer> srcStrided, size_t srcOffset, id<MTLBuffer> dstStrided, size_t dstOffset, const LSPOpenTextureMetalParamsHost& io, const float eq[8], int displaySwitch, int grey, float lumaBlend, bool* outSkipUnpack);
