#pragma once

#include <cmath>
#include <cstddef>

inline size_t openTextureBlurPackedBytes(int width, int height) {
    return static_cast<size_t>(width) * static_cast<size_t>(height) * 4u * sizeof(float);
}

inline size_t openTextureBlurScalarBytes(int width, int height) {
    return static_cast<size_t>(width) * static_cast<size_t>(height) * sizeof(float);
}

inline void fillVanVlietCoeffsFromRadius(int radius, float coeffs[4]) {
    const double m0 = 1.16680;
    const double m1 = 1.10783;
    const double m2 = 1.40586;
    const double m1sq = m1 * m1;
    const double m2sq = m2 * m2;
    const float sigma = (radius < 1 ? 1.0f : static_cast<float>(radius)) / 2.4f;
    const double nnsigma = sigma < 0.1f ? 0.1f : sigma;
    const double q = (nnsigma < 3.556) ? (-0.2568 + 0.5784 * nnsigma + 0.0561 * nnsigma * nnsigma)
                                       : (2.5091 + 0.9804 * (nnsigma - 3.556));
    const double qsq = q * q;
    const double scale = (m0 + q) * (m1sq + m2sq + 2.0 * m1 * q + qsq);
    const double b1 = -q * (2.0 * m0 * m1 + m1sq + m2sq + (2.0 * m0 + 4.0 * m1) * q + 3.0 * qsq) / scale;
    const double b2 = qsq * (m0 + 2.0 * m1 + 3.0 * q) / scale;
    const double b3 = -qsq * q / scale;
    const double B = (m0 * (m1sq + m2sq)) / scale;
    coeffs[0] = static_cast<float>(B);
    coeffs[1] = static_cast<float>(-b1);
    coeffs[2] = static_cast<float>(-b2);
    coeffs[3] = static_cast<float>(-b3);
}

inline int vanVlietRadiusFromMpsSigma(float mpsSigma) {
    const float s = mpsSigma < 0.1f ? 0.1f : mpsSigma;
    int radius = static_cast<int>(std::lround(s * 2.4f));
    if (radius < 1)
        radius = 1;
    return radius;
}

// big sigma: half res pyramid (keep in sync w/ mps halation path on mac)
inline constexpr float kOpenTexturePyramidBlurSigmaThreshold = 5.0f;

inline bool openTextureUsePyramidBlur(float sigma) {
    const float s = sigma < 0.1f ? 0.1f : sigma;
    return s >= kOpenTexturePyramidBlurSigmaThreshold;
}
