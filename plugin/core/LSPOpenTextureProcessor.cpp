#include "LSPOpenTextureProcessor.h"
#include "LSPOpenTextureConstants.h"
#include "LSPOpenTextureGamut.h"
#include "LSPOpenTextureGlareMapping.h"
#include "LSPOpenTextureLog.h"
#include "LSPOpenTextureTransfers.h"
#include "LSPOpenTextureTfMapping.h"
#if defined(__APPLE__)
#include "../metal/LSPOpenTextureMetal.h"
#endif
#if defined(_WIN32)
#include "../cuda/LSPOpenTextureCuda.h"
#endif

#include <atomic>
#include <cmath>
#include <cstring>

namespace {

inline float sanitizeFinite(float p_Value, float p_Fallback) {
    return std::isfinite(p_Value) ? p_Value : p_Fallback;
}

inline float clampf(float p_Value, float p_Min, float p_Max) {
    if (p_Value < p_Min)
        return p_Min;
    if (p_Value > p_Max)
        return p_Max;
    return p_Value;
}

struct Float3 {
    float r;
    float g;
    float b;
};

inline Float3 makeFloat3(float p_R, float p_G, float p_B) {
    Float3 v{p_R, p_G, p_B};
    return v;
}

inline Float3 add3(const Float3& a, const Float3& b) {
    return makeFloat3(a.r + b.r, a.g + b.g, a.b + b.b);
}

inline Float3 mul3f(const Float3& a, float b) {
    return makeFloat3(a.r * b, a.g * b, a.b * b);
}

inline Float3 div3f(const Float3& a, float b) {
    return (b == 0.0f) ? makeFloat3(0.0f, 0.0f, 0.0f) : makeFloat3(a.r / b, a.g / b, a.b / b);
}

inline LSPOpenTextureTransfers::RGBf rgbf(const Float3& v) {
    return {v.r, v.g, v.b};
}

inline Float3 toFloat3(const LSPOpenTextureTransfers::RGBf& v) {
    return makeFloat3(v.r, v.g, v.b);
}

inline Float3 toLinearByTransfer(const Float3& rgb, int p_TransferFunction) {
    int tf = p_TransferFunction;
    LSPOpenTextureTransfers::clamp_choice_index(&tf);
    return toFloat3(LSPOpenTextureTransfers::to_scene_linear(rgbf(rgb), tf));
}

inline Float3 fromLinearByTransfer(const Float3& rgb, int p_TransferFunction) {
    int tf = p_TransferFunction;
    LSPOpenTextureTransfers::clamp_choice_index(&tf);
    return toFloat3(LSPOpenTextureTransfers::from_scene_linear(rgbf(rgb), tf));
}

inline float whitepointForTransfer(int p_TransferFunction) {
    int tf = p_TransferFunction;
    LSPOpenTextureTransfers::clamp_choice_index(&tf);
    return LSPOpenTextureTransfers::whitepoint_for_transfer(tf);
}

inline Float3 samplePixel(const OFX::Image* p_Src, int p_X, int p_Y) {
    const float* s = static_cast<const float*>(p_Src->getPixelAddress(p_X, p_Y));
    if (!s)
        return makeFloat3(0.0f, 0.0f, 0.0f);
    return makeFloat3(sanitizeFinite(s[0], 0.0f), sanitizeFinite(s[1], 0.0f), sanitizeFinite(s[2], 0.0f));
}

inline float gaussianKernel(float p_X, float p_Y, float p_Sigma) {
    const float denom = 2.0f * p_Sigma * p_Sigma;
    if (denom <= 1.0e-6f)
        return 0.0f;
    return std::exp(-(p_X * p_X + p_Y * p_Y) / denom);
}

inline float cieLuma(const Float3& lin, const float coeffs[3]) {
    return coeffs[0] * lin.r + coeffs[1] * lin.g + coeffs[2] * lin.b;
}

inline Float3 mulMat33(const float m[9], const Float3& v) {
    return makeFloat3(
        m[0] * v.r + m[1] * v.g + m[2] * v.b,
        m[3] * v.r + m[4] * v.g + m[5] * v.b,
        m[6] * v.r + m[7] * v.g + m[8] * v.b);
}

inline Float3 hostToWorking(const Float3& enc, int inputTf, const float inputToDwg[9]) {
    const Float3 linIn = toLinearByTransfer(enc, inputTf);
    return mulMat33(inputToDwg, linIn);
}

inline Float3 workingToHost(const Float3& linDwg, int inputTf, const float dwgToInput[9]) {
    const Float3 linIn = mulMat33(dwgToInput, linDwg);
    return fromLinearByTransfer(linIn, inputTf);
}

inline Float3 sampleLinearDwg(
    const OFX::Image* p_Src,
    int p_X,
    int p_Y,
    int p_InputTransferFunction,
    const float inputToDwg[9]) {
    const Float3 s = samplePixel(p_Src, p_X, p_Y);
    return hostToWorking(s, p_InputTransferFunction, inputToDwg);
}

inline Float3 gaussianBlurLinear(
    const OFX::Image* p_Src,
    int p_X,
    int p_Y,
    float p_Spread,
    int p_InputTransferFunction,
    const float inputToDwg[9],
    float p_Distribution,
    float p_Whitepoint,
    const float cieLumaCoeffs[3],
    const LSPOpenTextureEffectWindowGeo& p_Geo,
    bool p_WindowEnabled) {
    const int radius = static_cast<int>(std::ceil(4.5f * p_Spread));
    const float sigma = std::fmax(0.1f, static_cast<float>(radius) / 2.57f);
    Float3 sum = makeFloat3(0.0f, 0.0f, 0.0f);
    float weightSum = 0.0f;
    for (int j = -radius; j <= radius; ++j) {
        for (int i = -radius; i <= radius; ++i) {
            const float w = gaussianKernel(static_cast<float>(i), static_cast<float>(j), sigma);
            int sx = p_X + i;
            int sy = p_Y + j;
            if (p_WindowEnabled)
                halationClampToEffectWindowGeo(sx, sy, p_Geo);
            const Float3 lin = sampleLinearDwg(p_Src, sx, sy, p_InputTransferFunction, inputToDwg);
            const LSPOpenTextureTfMapping::RGBf linTf{lin.r, lin.g, lin.b};
            const LSPOpenTextureTfMapping::RGBf shaped =
                LSPOpenTextureTfMapping::scaleLinearForBlurDistribution(linTf, p_Distribution, p_Whitepoint, cieLumaCoeffs);
            const Float3 sp = makeFloat3(shaped.r, shaped.g, shaped.b);
            sum = add3(sum, mul3f(sp, w));
            weightSum += w;
        }
    }
    return div3f(sum, weightSum);
}

inline Float3 composeTfHalation(
    const Float3& inRgb,
    const Float3& blurredLinDwg,
    int p_InputTransferFunction,
    const float inputToDwg[9],
    const float dwgToInput[9],
    float p_Distribution,
    bool p_ShowDistribution,
    const float cieLumaCoeffs[3],
    const LSPOpenTextureTfMapping::ResolvedTf& tf) {
    const Float3 rgbLinDwg = hostToWorking(inRgb, p_InputTransferFunction, inputToDwg);
    const float diffusedR = blurredLinDwg.r;
    const float e = tf.exposureLostLin;
    const float g = tf.greenLin;
    const float b = tf.blueLin;
    const Float3 halLin = makeFloat3(
        rgbLinDwg.r + diffusedR * e,
        rgbLinDwg.g + diffusedR * e * g,
        rgbLinDwg.b + diffusedR * e * g * b);
    const float whitepoint = whitepointForTransfer(kOpenTextureWorkingTransferFunction);
    const float dr = LSPOpenTextureTfMapping::highlightDistributionBlurScale(
        cieLuma(rgbLinDwg, cieLumaCoeffs), p_Distribution, whitepoint);
    float invMatrix[9];
    LSPOpenTextureTfMapping::buildRedshiftInvMatrix(e, g, b, invMatrix, dr);
    const Float3 corrected = mulMat33(invMatrix, halLin);
    if (p_ShowDistribution) {
        const Float3 halVis = makeFloat3(
            corrected.r - rgbLinDwg.r > 0.0f ? corrected.r - rgbLinDwg.r : 0.0f,
            corrected.g - rgbLinDwg.g > 0.0f ? corrected.g - rgbLinDwg.g : 0.0f,
            corrected.b - rgbLinDwg.b > 0.0f ? corrected.b - rgbLinDwg.b : 0.0f);
        return workingToHost(halVis, p_InputTransferFunction, dwgToInput);
    }
    return workingToHost(corrected, p_InputTransferFunction, dwgToInput);
}

}

LSPOpenTextureProcessor::LSPOpenTextureProcessor(OFX::ImageEffect& p_Effect)
    : OFX::ImageProcessor(p_Effect)
    , _srcImg(nullptr)
    , _halationEnable(true)
    , _operationOrder(0)
    , _halationGlobalBlend(1.0f)
    , _intensity(1.25f)
    , _size(3.0f)
    , _hue(0.5f)
    , _saturation(1.0f)
    , _distribution(1.0f)
    , _showDistribution(false)
    , _transferFunction(1)
    , _inputGamut(kOpenTextureInputGamutDefault)
    , _mtfEnable(false)
    , _mtfGlobalBlend(1.0f)
    , _mtfDisplay(0)
    , _mtfLumaBlend(0.0f)
    , _mtfGrey(1)
    , _effectWindowEnabled(false)
    , _effectWindowAspect(kOpenTextureEffectWindowDefaultAspect)
    , _effectWindowVertical(false)
    , _effectWindowShowBorder(false)
    , _glareEnable(false)
    , _glareGlobalBlend(1.0f)
    , _glareThreshold(LSPOpenTextureGlareMapping::defaultThresholdUi())
    , _glareSmoothness(0.4f)
    , _glareClampHighlights(true)
    , _glareMaxHighlights(LSPOpenTextureGlareMapping::defaultMaxHighlightsUi())
    , _glareStrength(1.0f)
    , _glareSaturation(1.0f)
    , _glareTemperature(0.5f)
    , _glareExposure(1.0f)
    , _glareSpread(LSPOpenTextureGlareMapping::uiToSpread(LSPOpenTextureGlareMapping::defaultSpreadUi()))
    , _glareDisplay(0)
    , _effectWindowGeo{} {
    for (int i = 0; i < 8; ++i)
        _mtfEq[i] = (i < 6) ? 1.0f : ((i == 6) ? 1.0f : 0.0f);
    halationComputeInputToDwg(_inputGamut, _inputToDwg);
    halationComputeDwgToInput(_inputGamut, _dwgToInput);
    halationCieYLumaCoeffsDwg(_cieLumaCoeffs);
}

void LSPOpenTextureProcessor::setParams(
    bool p_HalationEnable,
    double p_HalationGlobalBlend,
    double p_Intensity,
    double p_Size,
    double p_Hue,
    double p_Saturation,
    double p_Distribution,
    bool p_ShowDistribution,
    int p_TransferFunction,
    int p_InputGamut,
    int p_OperationOrder,
    bool p_MtfEnable,
    double p_MtfGlobalBlend,
    const float p_MtfEq[8],
    int p_MtfDisplay,
    float p_MtfLumaBlend,
    bool p_EffectWindowEnabled,
    float p_EffectWindowAspect,
    bool p_EffectWindowVertical,
    bool p_EffectWindowShowBorder,
    bool p_GlareEnable,
    double p_GlareGlobalBlend,
    double p_GlareThreshold,
    double p_GlareSmoothness,
    bool p_GlareClampHighlights,
    double p_GlareMaxHighlights,
    double p_GlareStrength,
    double p_GlareSaturation,
    double p_GlareTemperature,
    double p_GlareExposure,
    double p_GlareSpread,
    int p_GlareDisplay) {
    _halationEnable = p_HalationEnable;
    int oo = p_OperationOrder;
    if (oo < 0)
        oo = 0;
    else if (oo > 1)
        oo = 1;
    _operationOrder = oo;
    _halationGlobalBlend = clampf(static_cast<float>(p_HalationGlobalBlend), 0.0f, 1.0f);
    _intensity = LSPOpenTextureTfMapping::clampIntensity(static_cast<float>(p_Intensity));
    _size = clampf(static_cast<float>(p_Size), 0.0f, 8192.0f);
    _hue = LSPOpenTextureTfMapping::clampHue01(static_cast<float>(p_Hue));
    _saturation = LSPOpenTextureTfMapping::clampSaturation(static_cast<float>(p_Saturation));
    _distribution = clampf(static_cast<float>(p_Distribution), 0.6f, 1.0f);
    _showDistribution = p_ShowDistribution;
    const int tt = static_cast<int>(p_TransferFunction);
    _transferFunction = (tt >= 0 && tt <= 9) ? tt : 0;
    int ig = p_InputGamut;
    if (ig < 0)
        ig = 0;
    else if (ig >= kOpenTextureInputGamutCount)
        ig = kOpenTextureInputGamutCount - 1;
    _inputGamut = ig;
    halationComputeInputToDwg(_inputGamut, _inputToDwg);
    halationComputeDwgToInput(_inputGamut, _dwgToInput);
    halationCieYLumaCoeffsDwg(_cieLumaCoeffs);
    _mtfEnable = p_MtfEnable;
    _mtfGlobalBlend = clampf(static_cast<float>(p_MtfGlobalBlend), 0.0f, 1.0f);
    std::memcpy(_mtfEq, p_MtfEq, sizeof(_mtfEq));
    _mtfDisplay = p_MtfDisplay;
    _mtfLumaBlend = clampf(p_MtfLumaBlend, 0.0f, 1.0f);
    _mtfGrey = 1;
    _effectWindowEnabled = p_EffectWindowEnabled;
    _effectWindowAspect = p_EffectWindowAspect;
    _effectWindowVertical = p_EffectWindowVertical;
    _effectWindowShowBorder = p_EffectWindowShowBorder;
    _effectWindowGeo = {};
    _glareEnable = p_GlareEnable;
    _glareGlobalBlend = clampf(static_cast<float>(p_GlareGlobalBlend), 0.0f, 1.0f);
    _glareThreshold = LSPOpenTextureGlareMapping::normalizeHighlightsUi(p_GlareThreshold);
    _glareSmoothness = clampf(static_cast<float>(p_GlareSmoothness), 0.0f, 1.0f);
    _glareClampHighlights = p_GlareClampHighlights;
    _glareMaxHighlights = LSPOpenTextureGlareMapping::normalizeHighlightsUi(p_GlareMaxHighlights);
    if (_glareThreshold > _glareMaxHighlights)
        _glareThreshold = _glareMaxHighlights;
    _glareStrength = clampf(static_cast<float>(p_GlareStrength), 0.0f, 2.0f);
    _glareSaturation = clampf(static_cast<float>(p_GlareSaturation), 0.0f, 2.0f);
    _glareTemperature = clampf(static_cast<float>(p_GlareTemperature), 0.0f, 1.0f);
    _glareExposure = clampf(static_cast<float>(p_GlareExposure), 0.5f, 2.5f);
    _glareSpread = static_cast<float>(p_GlareSpread);
    if (_glareSpread < 0.0f)
        _glareSpread = 0.0f;
    int gd = p_GlareDisplay;
    if (gd < 0)
        gd = 0;
    else if (gd > 2)
        gd = 2;
    _glareDisplay = gd;
}

void LSPOpenTextureProcessor::multiThreadProcessImages(OfxRectI p_Window) {
    if (!_dstImg || !_srcImg)
        return;

    const int frameW = p_Window.x2 - p_Window.x1;
    const int frameH = p_Window.y2 - p_Window.y1;
    if (frameW > 0 && frameH > 0) {
        const LSPOpenTextureEffectWindowGeo geo =
            computeOpenTextureEffectWindowGeo(frameW, frameH, _effectWindowAspect, _effectWindowVertical);
        _effectWindowGeo = geo;
    }

    auto applyBorderIfNeeded = [&](int lx, int ly, float& r, float& g, float& b) {
        if (_effectWindowEnabled && _effectWindowShowBorder &&
            halationEffectWindowPixelOnBorder(lx, ly, _effectWindowGeo))
            halationEffectWindowBorderRgb(r, g, b);
    };

    auto writeCopyOrBlack = [&](int x, int y) {
        float* d = static_cast<float*>(_dstImg->getPixelAddress(x, y));
        const float* s = static_cast<const float*>(_srcImg->getPixelAddress(x, y));
        if (!d || !s)
            return;
        const int lx = x - p_Window.x1;
        const int ly = y - p_Window.y1;
        if (_effectWindowEnabled && !halationPixelInEffectWindowGeo(lx, ly, _effectWindowGeo)) {
            d[0] = 0.0f;
            d[1] = 0.0f;
            d[2] = 0.0f;
            d[3] = sanitizeFinite(s[3], 1.0f);
            float br = d[0];
            float bg = d[1];
            float bb = d[2];
            applyBorderIfNeeded(lx, ly, br, bg, bb);
            d[0] = br;
            d[1] = bg;
            d[2] = bb;
            return;
        }
        d[0] = sanitizeFinite(s[0], 0.0f);
        d[1] = sanitizeFinite(s[1], 0.0f);
        d[2] = sanitizeFinite(s[2], 0.0f);
        d[3] = sanitizeFinite(s[3], 1.0f);
        applyBorderIfNeeded(lx, ly, d[0], d[1], d[2]);
    };

    if (_mtfEnable && !_isEnabledMetalRender) {
        static std::atomic<bool> s_loggedMtfCpu{false};
        if (!s_loggedMtfCpu.exchange(true))
            LSP_OPEN_TEXTURE_LOG_ERROR("mtf_curve_requires_metal_render_enable_gpu_processing_for_this_node");
    }

    if (!_halationEnable) {
        for (int y = p_Window.y1; y < p_Window.y2; ++y) {
            for (int x = p_Window.x1; x < p_Window.x2; ++x)
                writeCopyOrBlack(x, y);
        }
        return;
    }

    if (_size < 1e-6f && !_showDistribution) {
        for (int y = p_Window.y1; y < p_Window.y2; ++y) {
            for (int x = p_Window.x1; x < p_Window.x2; ++x)
                writeCopyOrBlack(x, y);
        }
        return;
    }

    static std::atomic<bool> s_loggedCpuBlurFallback{false};
    if (!_isEnabledMetalRender && !s_loggedCpuBlurFallback.exchange(true))
        LSP_OPEN_TEXTURE_LOG_ERROR("cpu_halation_uses_gaussian_fallback_enable_gpu_for_mps");

    const LSPOpenTextureTfMapping::ResolvedTf tf = LSPOpenTextureTfMapping::resolveTfParams(_intensity, _hue, _saturation);
    const float whitepoint = whitepointForTransfer(kOpenTextureWorkingTransferFunction);

    for (int y = p_Window.y1; y < p_Window.y2; ++y) {
        for (int x = p_Window.x1; x < p_Window.x2; ++x) {
            float* d = static_cast<float*>(_dstImg->getPixelAddress(x, y));
            const float* s = static_cast<const float*>(_srcImg->getPixelAddress(x, y));
            if (!d || !s)
                continue;

            if (_effectWindowEnabled && !halationPixelInEffectWindowGeo(x - p_Window.x1, y - p_Window.y1, _effectWindowGeo)) {
                d[0] = 0.0f;
                d[1] = 0.0f;
                d[2] = 0.0f;
                d[3] = sanitizeFinite(s[3], 1.0f);
                const int lx = x - p_Window.x1;
                const int ly = y - p_Window.y1;
                applyBorderIfNeeded(lx, ly, d[0], d[1], d[2]);
                continue;
            }

            const Float3 inRgb = makeFloat3(sanitizeFinite(s[0], 0.0f), sanitizeFinite(s[1], 0.0f), sanitizeFinite(s[2], 0.0f));
            const float srcA = sanitizeFinite(s[3], 1.0f);
            const Float3 blurredLin = gaussianBlurLinear(
                _srcImg,
                x,
                y,
                _size,
                _transferFunction,
                _inputToDwg,
                _distribution,
                whitepoint,
                _cieLumaCoeffs,
                _effectWindowGeo,
                _effectWindowEnabled);
            const Float3 halOut = composeTfHalation(
                inRgb,
                blurredLin,
                _transferFunction,
                _inputToDwg,
                _dwgToInput,
                _distribution,
                _showDistribution,
                _cieLumaCoeffs,
                tf);
            Float3 outRgb = halOut;
            if (_halationGlobalBlend < 1.0f - 1.0e-5f) {
                const float g = _halationGlobalBlend;
                if (_showDistribution) {
                    outRgb = makeFloat3(halOut.r * g, halOut.g * g, halOut.b * g);
                } else {
                    const float om = 1.0f - g;
                    outRgb = makeFloat3(
                        om * inRgb.r + g * halOut.r,
                        om * inRgb.g + g * halOut.g,
                        om * inRgb.b + g * halOut.b);
                }
            }
            d[0] = sanitizeFinite(outRgb.r, _showDistribution ? 0.0f : inRgb.r);
            d[1] = sanitizeFinite(outRgb.g, _showDistribution ? 0.0f : inRgb.g);
            d[2] = sanitizeFinite(outRgb.b, _showDistribution ? 0.0f : inRgb.b);
            d[3] = srcA;
            applyBorderIfNeeded(x - p_Window.x1, y - p_Window.y1, d[0], d[1], d[2]);
        }
    }
}

#if defined(__APPLE__)
void LSPOpenTextureProcessor::processImagesMetal(void) {
    if (!_dstImg || !_srcImg) {
        LSP_OPEN_TEXTURE_LOG_ERROR("metal_missing_src_or_dst_image");
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }
    if (!_pMetalCmdQ) {
        LSP_OPEN_TEXTURE_LOG_ERROR("metal_no_command_queue");
        OFX::throwSuiteStatusException(kOfxStatErrUnsupported);
    }

    const void* srcMetalBuffer = _srcImg->getPixelData();
    void* dstMetalBuffer = _dstImg->getPixelData();
    if (!srcMetalBuffer || !dstMetalBuffer) {
        LSP_OPEN_TEXTURE_LOG_ERROR("metal_pixel_data_null");
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }

    const int width = _renderWindow.x2 - _renderWindow.x1;
    const int height = _renderWindow.y2 - _renderWindow.y1;
    if (width <= 0 || height <= 0) {
        return;
    }

    const LSPOpenTextureEffectWindowGeo geo =
        computeOpenTextureEffectWindowGeo(width, height, _effectWindowAspect, _effectWindowVertical);
    _effectWindowGeo = geo;

    const int srcRb = _srcImg->getRowBytes();
    const int dstRb = _dstImg->getRowBytes();
    const size_t srcRowBytes = srcRb < 0 ? static_cast<size_t>(-srcRb) : static_cast<size_t>(srcRb);
    const size_t dstRowBytes = dstRb < 0 ? static_cast<size_t>(-dstRb) : static_cast<size_t>(dstRb);

    const OfxRectI& srcB = _srcImg->getBounds();
    const OfxRectI& dstB = _dstImg->getBounds();
    const int srcCol = _renderWindow.x1 - srcB.x1;
    const int srcRow = _renderWindow.y1 - srcB.y1;
    const int dstCol = _renderWindow.x1 - dstB.x1;
    const int dstRow = _renderWindow.y1 - dstB.y1;
    if (srcCol < 0 || srcRow < 0 || dstCol < 0 || dstRow < 0) {
        LSP_OPEN_TEXTURE_LOG_ERROR("metal_render_window_outside_image_bounds");
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }

    const bool ok = LSPOpenTextureMetal::renderHost(
        srcMetalBuffer,
        dstMetalBuffer,
        width,
        height,
        srcRowBytes,
        dstRowBytes,
        srcCol,
        srcRow,
        dstCol,
        dstRow,
        _halationEnable,
        _halationGlobalBlend,
        _intensity,
        _size,
        _hue,
        _saturation,
        _distribution,
        _showDistribution,
        _transferFunction,
        _inputGamut,
        _operationOrder,
        _mtfEnable,
        _mtfGlobalBlend,
        _mtfEq,
        _mtfDisplay,
        _mtfGrey,
        _mtfLumaBlend,
        _effectWindowEnabled,
        _effectWindowAspect,
        _effectWindowVertical,
        _effectWindowShowBorder,
        _glareEnable,
        _glareGlobalBlend,
        _glareThreshold,
        _glareSmoothness,
        _glareClampHighlights,
        _glareMaxHighlights,
        _glareStrength,
        _glareSaturation,
        _glareTemperature,
        _glareExposure,
        _glareSpread,
        _glareDisplay,
        _pMetalCmdQ);
    if (!ok) {
        static std::atomic<int> s_metalRenderHostFailLogCount{0};
        if (s_metalRenderHostFailLogCount.fetch_add(1) < 8)
            LSP_OPEN_TEXTURE_LOG_ERROR("metal_renderHost_failed");
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }
}
#endif

#if defined(OFX_SUPPORTS_CUDARENDER)
void LSPOpenTextureProcessor::processImagesCuda(void) {
    if (!_dstImg || !_srcImg) {
        LSP_OPEN_TEXTURE_LOG_ERROR("cuda_missing_src_or_dst_image");
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }

    const float* srcDevice = static_cast<const float*>(_srcImg->getPixelData());
    float* dstDevice = static_cast<float*>(_dstImg->getPixelData());
    if (!srcDevice || !dstDevice) {
        LSP_OPEN_TEXTURE_LOG_ERROR("cuda_pixel_data_null");
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }

    const int width = _renderWindow.x2 - _renderWindow.x1;
    const int height = _renderWindow.y2 - _renderWindow.y1;
    if (width <= 0 || height <= 0)
        return;

    const LSPOpenTextureEffectWindowGeo geo =
        computeOpenTextureEffectWindowGeo(width, height, _effectWindowAspect, _effectWindowVertical);
    _effectWindowGeo = geo;

    const int srcRb = _srcImg->getRowBytes();
    const int dstRb = _dstImg->getRowBytes();
    const size_t srcRowBytes = srcRb < 0 ? static_cast<size_t>(-srcRb) : static_cast<size_t>(srcRb);
    const size_t dstRowBytes = dstRb < 0 ? static_cast<size_t>(-dstRb) : static_cast<size_t>(dstRb);

    const OfxRectI& srcB = _srcImg->getBounds();
    const OfxRectI& dstB = _dstImg->getBounds();
    const int srcCol = _renderWindow.x1 - srcB.x1;
    const int srcRow = _renderWindow.y1 - srcB.y1;
    const int dstCol = _renderWindow.x1 - dstB.x1;
    const int dstRow = _renderWindow.y1 - dstB.y1;
    if (srcCol < 0 || srcRow < 0 || dstCol < 0 || dstRow < 0) {
        LSP_OPEN_TEXTURE_LOG_ERROR("cuda_render_window_outside_image_bounds");
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }

    const bool ok = LSPOpenTextureCuda::renderHost(
        srcDevice,
        dstDevice,
        width,
        height,
        srcRowBytes,
        dstRowBytes,
        srcCol,
        srcRow,
        dstCol,
        dstRow,
        _halationEnable,
        _halationGlobalBlend,
        _intensity,
        _size,
        _hue,
        _saturation,
        _distribution,
        _showDistribution,
        _transferFunction,
        _inputGamut,
        _operationOrder,
        _mtfEnable,
        _mtfGlobalBlend,
        _mtfEq,
        _mtfDisplay,
        _mtfGrey,
        _mtfLumaBlend,
        _effectWindowEnabled,
        _effectWindowAspect,
        _effectWindowVertical,
        _effectWindowShowBorder,
        _glareEnable,
        _glareGlobalBlend,
        _glareThreshold,
        _glareSmoothness,
        _glareClampHighlights,
        _glareMaxHighlights,
        _glareStrength,
        _glareSaturation,
        _glareTemperature,
        _glareExposure,
        _glareSpread,
        _glareDisplay,
        _pCudaStream);
    if (!ok) {
        static std::atomic<int> s_cudaRenderHostFailLogCount{0};
        if (s_cudaRenderHostFailLogCount.fetch_add(1) < 8)
            LSP_OPEN_TEXTURE_LOG_ERROR("cuda_renderHost_failed");
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }
}
#endif
