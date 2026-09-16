#pragma once

struct OpenTextureGlareParamsCuda {
    float threshold;
    float smoothness;
    float maxBrightness;
    int quality;
    int qualityFactor;
    float spread;
    float strength;
    float saturation;
    float temperature;
    float exposure;
    float glareAmount;
    int chainLength;
    int chainLengthAlt;
    float chainBlend;
    int clampEnabled;
    int displayMode;
    int highlightsWidth;
    int highlightsHeight;
    float bloomBlurSigma;
};
