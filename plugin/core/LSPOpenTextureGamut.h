#ifndef LSP_OPEN_TEXTURE_GAMUT_H
#define LSP_OPEN_TEXTURE_GAMUT_H


constexpr int kOpenTextureInputGamutCount = 15;

constexpr int kOpenTextureInputGamutDefault = 14;

constexpr int kOpenTextureWorkingTransferFunction = 1;

void halationCieYLumaCoeffsDwg(float out3[3]);

void halationComputeInputToDwg(int inputGamut, float out9[9]);

void halationComputeDwgToInput(int inputGamut, float out9[9]);

struct LSPOpenTextureHostParams;
void openTextureFillWorkingGamutParams(int inputGamut, LSPOpenTextureHostParams& p);

#endif
