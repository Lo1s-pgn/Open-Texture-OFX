#pragma once

#include <cstddef>

inline size_t openTextureBlurPackedBytes(int width, int height) {
    return static_cast<size_t>(width) * static_cast<size_t>(height) * 4u * sizeof(float);
}

inline size_t openTextureBlurScalarBytes(int width, int height) {
    return static_cast<size_t>(width) * static_cast<size_t>(height) * sizeof(float);
}
