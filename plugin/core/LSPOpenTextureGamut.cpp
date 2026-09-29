#include "LSPOpenTextureGamut.h"
#include "LSPOpenTextureHostParams.h"

#include <cmath>
#include <cstring>

namespace {

static const float kInToXyz[kOpenTextureInputGamutCount][9] = {
    {1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f},
    {0.93863095f, -0.00574192f, 0.01756690f, 0.33809359f, 0.72721390f, -0.06530750f, 0.00072312f, 0.00081844f, 1.08751619f},
    {0.65241872f, 0.12717993f, 0.17085728f, 0.26806406f, 0.67246448f, 0.05947146f, -0.00546993f, 0.00518280f, 1.08934488f},
    {0.48657095f, 0.26566769f, 0.19821729f, 0.22897456f, 0.69173852f, 0.07928691f, 0.0f, 0.04511338f, 1.04394437f},
    {0.63695805f, 0.14461690f, 0.16888098f, 0.26270021f, 0.67799807f, 0.05930172f, 0.0f, 0.02807269f, 1.06098506f},
    {0.41239080f, 0.35758434f, 0.18048079f, 0.21263901f, 0.71516868f, 0.07219232f, 0.01933082f, 0.11919478f, 0.95053215f},
    {0.63800762f, 0.21470386f, 0.09774445f, 0.29195378f, 0.82384104f, -0.11579482f, 0.00279828f, -0.06703424f, 1.15329371f},
    {0.70485832f, 0.12976030f, 0.11583731f, 0.25452418f, 0.78147773f, -0.03600191f, 0.0f, 0.0f, 1.08905775f},
    {0.73527525f, 0.06860941f, 0.14657127f, 0.28669410f, 0.84297913f, -0.12967323f, -0.07968086f, -0.34734322f, 1.51608182f},
    {0.70648271f, 0.12880105f, 0.11517216f, 0.27097967f, 0.78660641f, -0.05758608f, -0.00967785f, 0.00460004f, 1.09413556f},
    {0.59908392f, 0.24892552f, 0.10244649f, 0.21507582f, 0.88506850f, -0.10014432f, -0.03206585f, -0.02765839f, 1.14878199f},
    {0.67964447f, 0.15221141f, 0.11860004f, 0.26068555f, 0.77489446f, -0.03558001f, -0.00931020f, -0.00461247f, 1.10298042f},
    {0.70539685f, 0.16404133f, 0.08101775f, 0.28013072f, 0.82020664f, -0.10033737f, -0.10378151f, -0.07290726f, 1.26574652f},
    {0.73647770f, 0.13073965f, 0.08323858f, 0.27506998f, 0.82801779f, -0.10308777f, -0.12422515f, -0.08715977f, 1.30044267f},
    {0.70062239f, 0.14877482f, 0.10105872f, 0.27411851f, 0.87363190f, -0.14775041f, -0.09896291f, -0.13789533f, 1.32591599f},
};

static const float kIdentity9[9] = {1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f};

int clampGamut(int g) {
    if (g < 0)
        return 0;
    if (g >= kOpenTextureInputGamutCount)
        return kOpenTextureInputGamutCount - 1;
    return g;
}

void mulMat3(const float a[9], const float b[9], float out[9]) {
    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 3; ++col) {
            float sum = 0.0f;
            for (int k = 0; k < 3; ++k)
                sum += a[row * 3 + k] * b[k * 3 + col];
            out[row * 3 + col] = sum;
        }
    }
}

bool invertMat3(const float m[9], float out[9]) {
    const float a = m[0], b = m[1], c = m[2];
    const float d = m[3], e = m[4], f = m[5];
    const float g = m[6], h = m[7], i = m[8];
    const float A = e * i - f * h;
    const float B = -(d * i - f * g);
    const float C = d * h - e * g;
    const float D = -(b * i - c * h);
    const float E = a * i - c * g;
    const float F = -(a * h - b * g);
    const float G = b * f - c * e;
    const float H = -(a * f - c * d);
    const float I = a * e - b * d;
    const float det = a * A + b * B + c * C;
    if (std::fabs(det) < 1.0e-12f)
        return false;
    const float invDet = 1.0f / det;
    out[0] = A * invDet;
    out[1] = D * invDet;
    out[2] = G * invDet;
    out[3] = B * invDet;
    out[4] = E * invDet;
    out[5] = H * invDet;
    out[6] = C * invDet;
    out[7] = F * invDet;
    out[8] = I * invDet;
    return true;
}

const float* inToXyz(int inputGamut) {
    return kInToXyz[clampGamut(inputGamut)];
}

}

void halationCieYLumaCoeffsDwg(float out3[3]) {
    const float* m = kInToXyz[kOpenTextureInputGamutDefault];
    out3[0] = m[3];
    out3[1] = m[4];
    out3[2] = m[5];
}

void halationComputeInputToDwg(int inputGamut, float out9[9]) {
    const int g = clampGamut(inputGamut);
    if (g == kOpenTextureInputGamutDefault) {
        std::memcpy(out9, kIdentity9, sizeof(kIdentity9));
        return;
    }
    float invDwg[9];
    if (!invertMat3(kInToXyz[kOpenTextureInputGamutDefault], invDwg)) {
        std::memcpy(out9, kIdentity9, sizeof(kIdentity9));
        return;
    }
    mulMat3(invDwg, inToXyz(g), out9);
}

void halationComputeDwgToInput(int inputGamut, float out9[9]) {
    const int g = clampGamut(inputGamut);
    if (g == kOpenTextureInputGamutDefault) {
        std::memcpy(out9, kIdentity9, sizeof(kIdentity9));
        return;
    }
    float invIn[9];
    if (!invertMat3(inToXyz(g), invIn)) {
        std::memcpy(out9, kIdentity9, sizeof(kIdentity9));
        return;
    }
    mulMat3(invIn, kInToXyz[kOpenTextureInputGamutDefault], out9);
}

void openTextureFillWorkingGamutParams(int inputGamut, LSPOpenTextureHostParams& p) {
    halationComputeInputToDwg(inputGamut, p.inputToDwg);
    halationComputeDwgToInput(inputGamut, p.dwgToInput);
    halationCieYLumaCoeffsDwg(p.cieLumaCoeffs);
    p.workingTransferFunction = kOpenTextureWorkingTransferFunction;
}
