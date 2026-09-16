#pragma once

#include <cstddef>

struct LSPOpenTextureMetalParamsHost;

bool LSPOpenTextureFreqEQ_IsIdentity(const float eq[8], int displaySwitch, float globalBlend);

bool LSPOpenTextureFreqEQ_EncodeCuda(
    float* srcStrided,
    float* dstStrided,
    const LSPOpenTextureMetalParamsHost& io,
    const float eq[8],
    int displaySwitch,
    int grey,
    float lumaBlend,
    bool* outSkipUnpack,
    void* cudaStream);
