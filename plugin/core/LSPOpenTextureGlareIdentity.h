#pragma once

inline bool openTextureGlareIsIdentity(bool enable, float globalBlend, float strength) {
    constexpr float kEps = 1.0e-5f;
    return !enable || globalBlend <= kEps || strength <= kEps;
}
