#pragma once

#include <cstddef>

struct LSPOpenTextureHostParams;

bool LSPOpenTextureFreqEQ_IsIdentity(const float eq[8], int displaySwitch, float globalBlend);

bool LSPOpenTextureFreqEQ_EncodeCuda(
    float* srcStrided,
    float* dstStrided,
    const LSPOpenTextureHostParams& io,
    const float eq[8],
    int displaySwitch,
    int grey,
    float lumaBlend,
    bool* outSkipUnpack,
    void* cudaStream);
