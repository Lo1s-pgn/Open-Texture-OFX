#ifndef LSP_OPEN_TEXTURE_PROCESSOR_H
#define LSP_OPEN_TEXTURE_PROCESSOR_H

#include "ofxsProcessing.h"
#include "LSPOpenTextureEffectWindow.h"

class LSPOpenTextureProcessor : public OFX::ImageProcessor {
public:
    explicit LSPOpenTextureProcessor(OFX::ImageEffect& p_Effect);

    void setSrcImg(OFX::Image* p_Img) { _srcImg = p_Img; }
    void setParams(
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
        int p_GlareDisplay);

    void multiThreadProcessImages(OfxRectI p_Window) override;
#if defined(__APPLE__)
    void processImagesMetal(void) override;
#endif
#if defined(OFX_SUPPORTS_CUDARENDER)
    void processImagesCuda(void) override;
#endif

private:
    OFX::Image* _srcImg;
    bool _halationEnable;
    int _operationOrder;
    float _halationGlobalBlend;
    float _intensity;
    float _size;
    float _hue;
    float _saturation;
    float _distribution;
    bool _showDistribution;
    int _transferFunction;
    int _inputGamut;
    float _inputToDwg[9];
    float _dwgToInput[9];
    float _cieLumaCoeffs[3];
    bool _mtfEnable;
    float _mtfGlobalBlend;
    float _mtfEq[8];
    int _mtfDisplay;
    float _mtfLumaBlend;
    int _mtfGrey;
    bool _effectWindowEnabled;
    float _effectWindowAspect;
    bool _effectWindowVertical;
    bool _effectWindowShowBorder;
    bool _glareEnable;
    float _glareGlobalBlend;
    float _glareThreshold;
    float _glareSmoothness;
    bool _glareClampHighlights;
    float _glareMaxHighlights;
    float _glareStrength;
    float _glareSaturation;
    float _glareTemperature;
    float _glareExposure;
    float _glareSpread;
    int _glareDisplay;
    LSPOpenTextureEffectWindowGeo _effectWindowGeo;
};

#endif
