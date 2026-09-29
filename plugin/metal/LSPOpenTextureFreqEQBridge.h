#pragma once

#import <Metal/Metal.h>

#include <cstddef>

struct LSPOpenTextureHostParams;

bool LSPOpenTextureFreqEQ_IsIdentity(const float eq[8], int displaySwitch, float globalBlend);

bool LSPOpenTextureFreqEQ_EncodeToCommandBuffer(id<MTLCommandBuffer> cmd, id<MTLBuffer> srcStrided, size_t srcOffset, id<MTLBuffer> dstStrided, size_t dstOffset, const LSPOpenTextureHostParams& io, const float eq[8], int displaySwitch, int grey, float lumaBlend, bool* outSkipUnpack);
