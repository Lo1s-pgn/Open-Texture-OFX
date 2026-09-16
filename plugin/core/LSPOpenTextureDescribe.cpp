#include "LSPOpenTextureDescribe.h"
#include "LSPOpenTextureConstants.h"
#include "LSPOpenTextureEffectWindow.h"
#include "LSPOpenTextureGlareMapping.h"
#include "LSPOpenTexturePresetMenus.h"

namespace {
OFX::GroupParamDescriptor* addGroup(OFX::ImageEffectDescriptor& p_Desc, const char* p_Name, const char* p_Label, const char* p_Hint, bool p_Open) {
    OFX::GroupParamDescriptor* g = p_Desc.defineGroupParam(p_Name);
    g->setLabels(p_Label, p_Label, p_Label);
    g->setHint(p_Hint);
    g->setOpen(p_Open);
    return g;
}

OFX::GroupParamDescriptor* addSubGroup(
    OFX::ImageEffectDescriptor& p_Desc,
    const char* p_Name,
    const char* p_Label,
    const char* p_Hint,
    bool p_Open,
    OFX::GroupParamDescriptor& p_Parent) {
    OFX::GroupParamDescriptor* g = addGroup(p_Desc, p_Name, p_Label, p_Hint, p_Open);
    g->setParent(p_Parent);
    return g;
}
}

void describeOpenTextureInContext(OFX::ImageEffectDescriptor& p_Desc, OFX::ContextEnum /*p_Context*/) {
    OFX::ClipDescriptor* srcClip = p_Desc.defineClip(kOfxImageEffectSimpleSourceClipName);
    srcClip->addSupportedComponent(OFX::ePixelComponentRGBA);
    srcClip->setTemporalClipAccess(false);
    srcClip->setSupportsTiles(kSupportsTiles);
    srcClip->setIsMask(false);

    OFX::ClipDescriptor* dstClip = p_Desc.defineClip(kOfxImageEffectOutputClipName);
    dstClip->addSupportedComponent(OFX::ePixelComponentRGBA);
    dstClip->addSupportedComponent(OFX::ePixelComponentAlpha);
    dstClip->setSupportsTiles(kSupportsTiles);

    OFX::PageParamDescriptor* page = p_Desc.definePageParam("Controls");

    OFX::GroupParamDescriptor* presetsG =
        addGroup(p_Desc, "halationPresetsGroup", "PRESET", "Presets.", false);
    describeOpenTexturePresetParams(p_Desc, presetsG);

    OFX::GroupParamDescriptor* inputG = addGroup(
        p_Desc,
        "halationInputGroup",
        "INPUT",
        "Input.",
        true);

    OFX::ChoiceParamDescriptor* gamutParam = p_Desc.defineChoiceParam("halationInputGamut");
    gamutParam->setLabels("Input Gamut", "Input Gamut", "Input Gamut");
    gamutParam->setHint("Gamut.");
    gamutParam->appendOption("XYZ");
    gamutParam->appendOption("ACES 2065-1");
    gamutParam->appendOption("ACEScg");
    gamutParam->appendOption("P3D65");
    gamutParam->appendOption("Rec.2020");
    gamutParam->appendOption("Rec.709");
    gamutParam->appendOption("Arri Wide Gamut 3");
    gamutParam->appendOption("Arri Wide Gamut 4");
    gamutParam->appendOption("Red Wide Gamut RGB");
    gamutParam->appendOption("Sony SGamut3");
    gamutParam->appendOption("Sony SGamut3Cine");
    gamutParam->appendOption("Panasonic V-Gamut");
    gamutParam->appendOption("Filmlight E-Gamut");
    gamutParam->appendOption("Filmlight E-Gamut2");
    gamutParam->appendOption("DaVinci Wide Gamut");
    gamutParam->setDefault(14);
    gamutParam->setAnimates(false);
    gamutParam->setParent(*inputG);

    OFX::ChoiceParamDescriptor* transferParam = p_Desc.defineChoiceParam("halationTransferFunction");
    transferParam->setLabels("Transfer Function", "Transfer Function", "Transfer Function");
    transferParam->setHint("Transfer.");
    transferParam->appendOption("Linear");
    transferParam->appendOption("DaVinci Intermediate");
    transferParam->appendOption("Filmlight T-Log");
    transferParam->appendOption("ACEScct");
    transferParam->appendOption("Arri LogC3");
    transferParam->appendOption("Arri LogC4");
    transferParam->appendOption("RedLog3G10");
    transferParam->appendOption("Panasonic V-Log");
    transferParam->appendOption("Sony S-Log3");
    transferParam->appendOption("Fuji F-Log2");
    transferParam->setDefault(1);
    transferParam->setAnimates(false);
    transferParam->setParent(*inputG);

    OFX::GroupParamDescriptor* pipelineG =
        addGroup(p_Desc, "halationPipelineOrderGroup", "PIPELINE", "Order.", true);

    OFX::ChoiceParamDescriptor* opOrderParam = p_Desc.defineChoiceParam("halationOperationOrder");
    opOrderParam->setLabels("Operation order", "Operation order", "Operation order");
    opOrderParam->setHint("Order.");
    opOrderParam->appendOption("Halation / MTF");
    opOrderParam->appendOption("MTF / Halation");
    opOrderParam->setDefault(0);
    opOrderParam->setAnimates(false);
    opOrderParam->setParent(*pipelineG);

    OFX::GroupParamDescriptor* effectWindowG = addGroup(
        p_Desc,
        "halationEffectWindowGroup",
        "EFFECT WINDOW",
        "Mask.",
        true);

    OFX::BooleanParamDescriptor* effectWindowEnableParam = p_Desc.defineBooleanParam("halationEffectWindowEnable");
    effectWindowEnableParam->setLabels("Enable", "Enable", "Enable");
    effectWindowEnableParam->setHint("Enable.");
    effectWindowEnableParam->setDefault(false);
    effectWindowEnableParam->setAnimates(false);
    effectWindowEnableParam->setParent(*effectWindowG);

    OFX::PushButtonParamDescriptor* effectWindowResetBtn = p_Desc.definePushButtonParam("halationResetEffectWindow");
    effectWindowResetBtn->setLabels("Reset", "Reset", "Reset");
    effectWindowResetBtn->setHint("Reset.");
    effectWindowResetBtn->setParent(*effectWindowG);

    OFX::ChoiceParamDescriptor* effectWindowAspectPresetParam = p_Desc.defineChoiceParam("halationEffectWindowAspectPreset");
    effectWindowAspectPresetParam->setLabels("Aspect preset", "Aspect preset", "Aspect preset");
    effectWindowAspectPresetParam->setHint("Preset.");
    effectWindowAspectPresetParam->appendOption("Custom");
    effectWindowAspectPresetParam->appendOption("1.33");
    effectWindowAspectPresetParam->appendOption("1.37");
    effectWindowAspectPresetParam->appendOption("1.43");
    effectWindowAspectPresetParam->appendOption("1.66");
    effectWindowAspectPresetParam->appendOption("1.78");
    effectWindowAspectPresetParam->appendOption("1.85");
    effectWindowAspectPresetParam->appendOption("2.00");
    effectWindowAspectPresetParam->appendOption("2.20");
    effectWindowAspectPresetParam->appendOption("2.35");
    effectWindowAspectPresetParam->appendOption("2.39");
    effectWindowAspectPresetParam->appendOption("2.40");
    effectWindowAspectPresetParam->setDefault(kOpenTextureEffectWindowAspectPresetDefault);
    effectWindowAspectPresetParam->setAnimates(false);
    effectWindowAspectPresetParam->setParent(*effectWindowG);

    OFX::DoubleParamDescriptor* effectWindowAspectParam = p_Desc.defineDoubleParam("halationEffectWindowAspect");
    effectWindowAspectParam->setLabels("Aspect ratio", "Aspect ratio", "Aspect ratio");
    effectWindowAspectParam->setHint("Aspect.");
    effectWindowAspectParam->setDefault(kOpenTextureEffectWindowDefaultAspect);
    effectWindowAspectParam->setRange(1.0, 2.76);
    effectWindowAspectParam->setDisplayRange(1.0, 2.76);
    effectWindowAspectParam->setIncrement(0.001);
    effectWindowAspectParam->setAnimates(false);
    effectWindowAspectParam->setParent(*effectWindowG);

    OFX::BooleanParamDescriptor* effectWindowVerticalParam = p_Desc.defineBooleanParam("halationEffectWindowVertical");
    effectWindowVerticalParam->setLabels("Use Vertical Aspect Ratio", "Use Vertical Aspect Ratio", "Use Vertical Aspect Ratio");
    effectWindowVerticalParam->setHint("Vertical.");
    effectWindowVerticalParam->setDefault(false);
    effectWindowVerticalParam->setAnimates(false);
    effectWindowVerticalParam->setParent(*effectWindowG);

    OFX::BooleanParamDescriptor* effectWindowShowBorderParam = p_Desc.defineBooleanParam("halationEffectWindowShowBorder");
    effectWindowShowBorderParam->setLabels("Show border", "Show border", "Show border");
    effectWindowShowBorderParam->setHint("Border.");
    effectWindowShowBorderParam->setDefault(false);
    effectWindowShowBorderParam->setAnimates(false);
    effectWindowShowBorderParam->setParent(*effectWindowG);

    OFX::GroupParamDescriptor* mainG = addGroup(p_Desc, "halationMainGroup", "HALATION", "Halation.", true);

    OFX::BooleanParamDescriptor* halationEnableParam = p_Desc.defineBooleanParam("halationEnable");
    halationEnableParam->setLabels("Enable", "Enable", "Enable");
    halationEnableParam->setHint("Enable.");
    halationEnableParam->setDefault(false);
    halationEnableParam->setAnimates(false);
    halationEnableParam->setParent(*mainG);

    OFX::PushButtonParamDescriptor* halationResetBtn = p_Desc.definePushButtonParam("halationResetHalation");
    halationResetBtn->setLabels("Reset", "Reset", "Reset");
    halationResetBtn->setHint("Reset.");
    halationResetBtn->setParent(*mainG);

    OFX::DoubleParamDescriptor* halationGlobalBlendParam = p_Desc.defineDoubleParam("halationGlobalBlend");
    halationGlobalBlendParam->setLabels("Global blend", "Global blend", "Global blend");
    halationGlobalBlendParam->setHint("Mix.");
    halationGlobalBlendParam->setDefault(1.0);
    halationGlobalBlendParam->setRange(0.0, 1.0);
    halationGlobalBlendParam->setDisplayRange(0.0, 1.0);
    halationGlobalBlendParam->setIncrement(0.001);
    halationGlobalBlendParam->setAnimates(true);
    halationGlobalBlendParam->setParent(*mainG);

    OFX::DoubleParamDescriptor* intensityParam = p_Desc.defineDoubleParam("halationIntensity");
    intensityParam->setLabels("Intensity", "Intensity", "Intensity");
    intensityParam->setHint("Strength.");
    intensityParam->setDefault(1.25);
    intensityParam->setRange(0.0, 2.0);
    intensityParam->setDisplayRange(0.0, 2.0);
    intensityParam->setIncrement(0.01);
    intensityParam->setAnimates(true);
    intensityParam->setParent(*mainG);

    OFX::DoubleParamDescriptor* sizeParam = p_Desc.defineDoubleParam("halationSize");
    sizeParam->setLabels("Spread", "Spread", "Spread");
    sizeParam->setHint("Spread.");
    sizeParam->setDefault(3.0);
    sizeParam->setRange(0.0, 7.0);
    sizeParam->setDisplayRange(0.0, 7.0);
    sizeParam->setIncrement(0.001);
    sizeParam->setAnimates(true);
    sizeParam->setParent(*mainG);

    OFX::DoubleParamDescriptor* colorParam = p_Desc.defineDoubleParam("halationColor");
    colorParam->setLabels("Hue", "Hue", "Hue");
    colorParam->setHint("Hue.");
    colorParam->setDefault(0.5);
    colorParam->setRange(0.0, 1.0);
    colorParam->setDisplayRange(0.0, 1.0);
    colorParam->setIncrement(0.001);
    colorParam->setAnimates(true);
    colorParam->setParent(*mainG);

    OFX::DoubleParamDescriptor* saturationParam = p_Desc.defineDoubleParam("halationSaturation");
    saturationParam->setLabels("Saturation", "Saturation", "Saturation");
    saturationParam->setHint("Saturation.");
    saturationParam->setDefault(1.0);
    saturationParam->setRange(0.0, 2.0);
    saturationParam->setDisplayRange(0.0, 2.0);
    saturationParam->setIncrement(0.01);
    saturationParam->setAnimates(true);
    saturationParam->setParent(*mainG);

    OFX::DoubleParamDescriptor* distributionParam = p_Desc.defineDoubleParam("halationDistribution");
    distributionParam->setLabels("Highlight Distribution", "Highlight Distribution", "Highlight Distribution");
    distributionParam->setHint("Rolloff.");
    distributionParam->setDefault(1.0);
    distributionParam->setRange(0.6, 1.0);
    distributionParam->setDisplayRange(0.6, 1.0);
    distributionParam->setIncrement(0.001);
    distributionParam->setAnimates(true);
    distributionParam->setParent(*mainG);

    OFX::GroupParamDescriptor* halationOverlayG = addSubGroup(
        p_Desc,
        "halationOverlayGroup",
        "\u2B55 Overlay",
        "Overlay.",
        false,
        *mainG);

    OFX::BooleanParamDescriptor* showDistributionParam = p_Desc.defineBooleanParam("halationShowDistribution");
    showDistributionParam->setLabels("Show Distribution", "Show Distribution", "Show Distribution");
    showDistributionParam->setHint("Solo.");
    showDistributionParam->setDefault(false);
    showDistributionParam->setAnimates(false);
    showDistributionParam->setParent(*halationOverlayG);

    OFX::GroupParamDescriptor* mtfG =
        addGroup(p_Desc, "halationMtfGroup", "MTF CURVE", "MTF.", true);

    OFX::BooleanParamDescriptor* mtfEnableParam = p_Desc.defineBooleanParam("halationMtfEnable");
    mtfEnableParam->setLabels("Enable", "Enable", "Enable");
    mtfEnableParam->setHint("Enable.");
    mtfEnableParam->setDefault(false);
    mtfEnableParam->setAnimates(false);
    mtfEnableParam->setParent(*mtfG);

    OFX::PushButtonParamDescriptor* mtfResetBtn = p_Desc.definePushButtonParam("halationResetMtf");
    mtfResetBtn->setLabels("Reset", "Reset", "Reset");
    mtfResetBtn->setHint("Reset.");
    mtfResetBtn->setParent(*mtfG);

    OFX::DoubleParamDescriptor* mtfGlobalBlendOut = p_Desc.defineDoubleParam("halationMtfGlobalBlend");
    mtfGlobalBlendOut->setLabels("Global blend", "Global blend", "Global blend");
    mtfGlobalBlendOut->setHint("Mix.");
    mtfGlobalBlendOut->setDefault(1.0);
    mtfGlobalBlendOut->setRange(0.0, 1.0);
    mtfGlobalBlendOut->setDisplayRange(0.0, 1.0);
    mtfGlobalBlendOut->setIncrement(0.001);
    mtfGlobalBlendOut->setAnimates(true);
    mtfGlobalBlendOut->setParent(*mtfG);

    OFX::DoubleParamDescriptor* mtfGlobalStrengthOut = p_Desc.defineDoubleParam("halationMtfGlobalStrength");
    mtfGlobalStrengthOut->setLabels("Global strength", "Global strength", "Global strength");
    mtfGlobalStrengthOut->setHint("Scale.");
    mtfGlobalStrengthOut->setDefault(1.0);
    mtfGlobalStrengthOut->setRange(0.0, 2.0);
    mtfGlobalStrengthOut->setDisplayRange(0.0, 2.0);
    mtfGlobalStrengthOut->setIncrement(0.001);
    mtfGlobalStrengthOut->setAnimates(true);
    mtfGlobalStrengthOut->setParent(*mtfG);

    const char* mtfEqHint = "Gain.";

    OFX::DoubleParamDescriptor* mtfPQ1 = p_Desc.defineDoubleParam("halationMtfEQ1");
    mtfPQ1->setLabels("EQ band 1", "EQ band 1", "EQ band 1");
    mtfPQ1->setHint(mtfEqHint);
    mtfPQ1->setDefault(0.0);
    mtfPQ1->setRange(-1.0, 1.0);
    mtfPQ1->setDisplayRange(-1.0, 1.0);
    mtfPQ1->setIncrement(0.001);
    mtfPQ1->setAnimates(true);
    mtfPQ1->setParent(*mtfG);

    OFX::DoubleParamDescriptor* mtfPQ2 = p_Desc.defineDoubleParam("halationMtfEQ2");
    mtfPQ2->setLabels("EQ band 2", "EQ band 2", "EQ band 2");
    mtfPQ2->setHint(mtfEqHint);
    mtfPQ2->setDefault(0.0);
    mtfPQ2->setRange(-1.0, 1.0);
    mtfPQ2->setDisplayRange(-1.0, 1.0);
    mtfPQ2->setIncrement(0.001);
    mtfPQ2->setAnimates(true);
    mtfPQ2->setParent(*mtfG);

    OFX::DoubleParamDescriptor* mtfPQ3 = p_Desc.defineDoubleParam("halationMtfEQ3");
    mtfPQ3->setLabels("EQ band 3", "EQ band 3", "EQ band 3");
    mtfPQ3->setHint(mtfEqHint);
    mtfPQ3->setDefault(0.0);
    mtfPQ3->setRange(-1.0, 1.0);
    mtfPQ3->setDisplayRange(-1.0, 1.0);
    mtfPQ3->setIncrement(0.001);
    mtfPQ3->setAnimates(true);
    mtfPQ3->setParent(*mtfG);

    OFX::DoubleParamDescriptor* mtfPQ4 = p_Desc.defineDoubleParam("halationMtfEQ4");
    mtfPQ4->setLabels("EQ band 4", "EQ band 4", "EQ band 4");
    mtfPQ4->setHint(mtfEqHint);
    mtfPQ4->setDefault(0.0);
    mtfPQ4->setRange(-1.0, 1.0);
    mtfPQ4->setDisplayRange(-1.0, 1.0);
    mtfPQ4->setIncrement(0.001);
    mtfPQ4->setAnimates(true);
    mtfPQ4->setParent(*mtfG);

    OFX::DoubleParamDescriptor* mtfPQ5 = p_Desc.defineDoubleParam("halationMtfEQ5");
    mtfPQ5->setLabels("EQ band 5", "EQ band 5", "EQ band 5");
    mtfPQ5->setHint(mtfEqHint);
    mtfPQ5->setDefault(0.0);
    mtfPQ5->setRange(-1.0, 1.0);
    mtfPQ5->setDisplayRange(-1.0, 1.0);
    mtfPQ5->setIncrement(0.001);
    mtfPQ5->setAnimates(true);
    mtfPQ5->setParent(*mtfG);

    OFX::DoubleParamDescriptor* mtfPQ6 = p_Desc.defineDoubleParam("halationMtfEQ6");
    mtfPQ6->setLabels("EQ band 6", "EQ band 6", "EQ band 6");
    mtfPQ6->setHint(mtfEqHint);
    mtfPQ6->setDefault(0.0);
    mtfPQ6->setRange(-1.0, 1.0);
    mtfPQ6->setDisplayRange(-1.0, 1.0);
    mtfPQ6->setIncrement(0.001);
    mtfPQ6->setAnimates(true);
    mtfPQ6->setParent(*mtfG);

    OFX::DoubleParamDescriptor* mtfLumaBlend = p_Desc.defineDoubleParam("halationMtfLumaBlend");
    mtfLumaBlend->setLabels("Luma blend", "Luma blend", "Luma blend");
    mtfLumaBlend->setHint("0=scale Rec.709-Y (keep chroma). 1=Paul Dore Lab a/b. Working RGB treated as Rec.709 (no gamut convert).");
    mtfLumaBlend->setDefault(0.0);
    mtfLumaBlend->setRange(0.0, 1.0);
    mtfLumaBlend->setDisplayRange(0.0, 1.0);
    mtfLumaBlend->setIncrement(0.001);
    mtfLumaBlend->setAnimates(true);
    mtfLumaBlend->setParent(*mtfG);

    OFX::GroupParamDescriptor* mtfOverlayG = addSubGroup(
        p_Desc,
        "halationMtfOverlayGroup",
        "\u2B55 Overlay",
        "Overlay.",
        false,
        *mtfG);

    OFX::ChoiceParamDescriptor* mtfDisp = p_Desc.defineChoiceParam("halationMtfDisplay");
    mtfDisp->setLabels("Display band", "Display band", "Display band");
    mtfDisp->setHint("Solo.");
    mtfDisp->appendOption("None");
    mtfDisp->appendOption("EQ band 1");
    mtfDisp->appendOption("EQ band 2");
    mtfDisp->appendOption("EQ band 3");
    mtfDisp->appendOption("EQ band 4");
    mtfDisp->appendOption("EQ band 5");
    mtfDisp->appendOption("EQ band 6");
    mtfDisp->setDefault(0);
    mtfDisp->setAnimates(false);
    mtfDisp->setParent(*mtfOverlayG);

    OFX::GroupParamDescriptor* glareG = addGroup(
        p_Desc,
        "halationGlareGroup",
        "DIFFUSION",
        "Diffusion.",
        true);

    OFX::BooleanParamDescriptor* glareEnableParam = p_Desc.defineBooleanParam("halationGlareEnable");
    glareEnableParam->setLabels("Enable", "Enable", "Enable");
    glareEnableParam->setHint("Enable.");
    glareEnableParam->setDefault(false);
    glareEnableParam->setAnimates(false);
    glareEnableParam->setParent(*glareG);

    OFX::PushButtonParamDescriptor* glareResetBtn = p_Desc.definePushButtonParam("halationResetGlare");
    glareResetBtn->setLabels("Reset", "Reset", "Reset");
    glareResetBtn->setHint("Reset.");
    glareResetBtn->setParent(*glareG);

    OFX::DoubleParamDescriptor* glareGlobalBlendParam = p_Desc.defineDoubleParam("halationGlareGlobalBlend");
    glareGlobalBlendParam->setLabels("Global blend", "Global blend", "Global blend");
    glareGlobalBlendParam->setHint("Mix.");
    glareGlobalBlendParam->setDefault(1.0);
    glareGlobalBlendParam->setRange(0.0, 1.0);
    glareGlobalBlendParam->setDisplayRange(0.0, 1.0);
    glareGlobalBlendParam->setIncrement(0.001);
    glareGlobalBlendParam->setAnimates(true);
    glareGlobalBlendParam->setParent(*glareG);

    OFX::GroupParamDescriptor* glareBloomG = addSubGroup(
        p_Desc,
        "halationGlareBloomGroup",
        "Bloom",
        "Bloom.",
        true,
        *glareG);

    OFX::DoubleParamDescriptor* glareSpreadParam = p_Desc.defineDoubleParam("halationGlareSpread");
    glareSpreadParam->setLabels("Spread", "Spread", "Spread");
    glareSpreadParam->setHint("Size.");
    glareSpreadParam->setDefault(0.5);
    glareSpreadParam->setRange(0.0, 1.0);
    glareSpreadParam->setDisplayRange(0.0, 1.0);
    glareSpreadParam->setIncrement(0.001);
    glareSpreadParam->setAnimates(true);
    glareSpreadParam->setParent(*glareBloomG);

    OFX::DoubleParamDescriptor* glareStrengthParam = p_Desc.defineDoubleParam("halationGlareStrength");
    glareStrengthParam->setLabels("Strength", "Strength", "Strength");
    glareStrengthParam->setHint("Strength.");
    glareStrengthParam->setDefault(1.0);
    glareStrengthParam->setRange(0.0, 2.0);
    glareStrengthParam->setDisplayRange(0.0, 2.0);
    glareStrengthParam->setIncrement(0.001);
    glareStrengthParam->setAnimates(true);
    glareStrengthParam->setParent(*glareBloomG);

    OFX::DoubleParamDescriptor* glareExposureParam = p_Desc.defineDoubleParam("halationGlareExposure");
    glareExposureParam->setLabels("Exposure shift", "Exposure shift", "Exposure shift");
    glareExposureParam->setHint("Exposure.");
    glareExposureParam->setDefault(1.0);
    glareExposureParam->setRange(0.5, 2.5);
    glareExposureParam->setDisplayRange(0.5, 2.5);
    glareExposureParam->setIncrement(0.001);
    glareExposureParam->setAnimates(true);
    glareExposureParam->setParent(*glareBloomG);

    OFX::DoubleParamDescriptor* glareSaturationParam = p_Desc.defineDoubleParam("halationGlareSaturation");
    glareSaturationParam->setLabels("Saturation", "Saturation", "Saturation");
    glareSaturationParam->setHint("Saturation.");
    glareSaturationParam->setDefault(1.0);
    glareSaturationParam->setRange(0.0, 2.0);
    glareSaturationParam->setDisplayRange(0.0, 2.0);
    glareSaturationParam->setIncrement(0.001);
    glareSaturationParam->setAnimates(true);
    glareSaturationParam->setParent(*glareBloomG);

    OFX::DoubleParamDescriptor* glareTemperatureParam = p_Desc.defineDoubleParam("halationGlareTemperature");
    glareTemperatureParam->setLabels("Temperature", "Temperature", "Temperature");
    glareTemperatureParam->setHint("Temperature.");
    glareTemperatureParam->setDefault(0.5);
    glareTemperatureParam->setRange(0.0, 1.0);
    glareTemperatureParam->setDisplayRange(0.0, 1.0);
    glareTemperatureParam->setIncrement(0.001);
    glareTemperatureParam->setAnimates(true);
    glareTemperatureParam->setParent(*glareBloomG);

    OFX::GroupParamDescriptor* glareHighlightsG = addSubGroup(
        p_Desc,
        "halationGlareHighlightsGroup",
        "Highlights",
        "Highlights.",
        true,
        *glareG);

    OFX::DoubleParamDescriptor* glareThresholdParam = p_Desc.defineDoubleParam("halationGlareThreshold");
    glareThresholdParam->setLabels("Min Highlights", "Min Highlights", "Min Highlights");
    glareThresholdParam->setHint("Floor.");
    glareThresholdParam->setDefault(LSPOpenTextureGlareMapping::defaultMinHighlightsUi());
    glareThresholdParam->setRange(0.0, 1.0);
    glareThresholdParam->setDisplayRange(0.0, 1.0);
    glareThresholdParam->setIncrement(0.001);
    glareThresholdParam->setAnimates(true);
    glareThresholdParam->setParent(*glareHighlightsG);

    OFX::DoubleParamDescriptor* glareMinHighlightsNitsParam = p_Desc.defineDoubleParam("halationGlareMinHighlightsNits");
    glareMinHighlightsNitsParam->setLabels("Min Nits", "Min Nits", "Min Nits");
    glareMinHighlightsNitsParam->setHint("Nits.");
    glareMinHighlightsNitsParam->setDefault(LSPOpenTextureGlareMapping::defaultMinHighlightsNits());
    glareMinHighlightsNitsParam->setRange(LSPOpenTextureGlareMapping::kHighlightsNitsMin, LSPOpenTextureGlareMapping::kHighlightsNitsMax);
    glareMinHighlightsNitsParam->setDisplayRange(LSPOpenTextureGlareMapping::kHighlightsNitsMin, LSPOpenTextureGlareMapping::kHighlightsNitsMax);
    glareMinHighlightsNitsParam->setIncrement(1.0);
    glareMinHighlightsNitsParam->setAnimates(false);
    glareMinHighlightsNitsParam->setParent(*glareHighlightsG);

    OFX::DoubleParamDescriptor* glareSmoothnessParam = p_Desc.defineDoubleParam("halationGlareSmoothness");
    glareSmoothnessParam->setLabels("Smoothness", "Smoothness", "Smoothness");
    glareSmoothnessParam->setHint("Fade.");
    glareSmoothnessParam->setDefault(0.4);
    glareSmoothnessParam->setRange(0.0, 1.0);
    glareSmoothnessParam->setDisplayRange(0.0, 1.0);
    glareSmoothnessParam->setIncrement(0.001);
    glareSmoothnessParam->setAnimates(true);
    glareSmoothnessParam->setParent(*glareHighlightsG);

    OFX::BooleanParamDescriptor* glareClampParam = p_Desc.defineBooleanParam("halationGlareClampHighlights");
    glareClampParam->setLabels("Limit Highlights", "Limit Highlights", "Limit Highlights");
    glareClampParam->setHint("Cap source.");
    glareClampParam->setDefault(true);
    glareClampParam->setAnimates(false);
    glareClampParam->setParent(*glareHighlightsG);

    OFX::DoubleParamDescriptor* glareMaxHighlightsParam = p_Desc.defineDoubleParam("halationGlareMaxHighlights");
    glareMaxHighlightsParam->setLabels("Max Highlights", "Max Highlights", "Max Highlights");
    glareMaxHighlightsParam->setHint("Peak.");
    glareMaxHighlightsParam->setDefault(LSPOpenTextureGlareMapping::defaultMaxHighlightsUi());
    glareMaxHighlightsParam->setRange(0.0, 1.0);
    glareMaxHighlightsParam->setDisplayRange(0.0, 1.0);
    glareMaxHighlightsParam->setIncrement(0.001);
    glareMaxHighlightsParam->setAnimates(true);
    glareMaxHighlightsParam->setParent(*glareHighlightsG);

    OFX::DoubleParamDescriptor* glareMaxHighlightsNitsParam = p_Desc.defineDoubleParam("halationGlareMaxHighlightsNits");
    glareMaxHighlightsNitsParam->setLabels("Max Nits", "Max Nits", "Max Nits");
    glareMaxHighlightsNitsParam->setHint("Nits.");
    glareMaxHighlightsNitsParam->setDefault(LSPOpenTextureGlareMapping::defaultMaxHighlightsNits());
    glareMaxHighlightsNitsParam->setRange(LSPOpenTextureGlareMapping::kHighlightsNitsMin, LSPOpenTextureGlareMapping::kHighlightsNitsMax);
    glareMaxHighlightsNitsParam->setDisplayRange(LSPOpenTextureGlareMapping::kHighlightsNitsMin, LSPOpenTextureGlareMapping::kHighlightsNitsMax);
    glareMaxHighlightsNitsParam->setIncrement(1.0);
    glareMaxHighlightsNitsParam->setAnimates(false);
    glareMaxHighlightsNitsParam->setParent(*glareHighlightsG);

    OFX::GroupParamDescriptor* glareOverlayG = addSubGroup(
        p_Desc,
        "halationGlareOverlayGroup",
        "\u2B55 Overlay",
        "Overlay.",
        false,
        *glareG);

    OFX::ChoiceParamDescriptor* glareDisplayParam = p_Desc.defineChoiceParam("halationGlareDisplay");
    glareDisplayParam->setLabels("Display", "Display", "Display");
    glareDisplayParam->setHint("Overlay.");
    glareDisplayParam->appendOption("Render");
    glareDisplayParam->appendOption("Source");
    glareDisplayParam->appendOption("Diffusion");
    glareDisplayParam->setDefault(0);
    glareDisplayParam->setAnimates(false);
    glareDisplayParam->setParent(*glareOverlayG);

    OFX::GroupParamDescriptor* supportG =
        addGroup(p_Desc, "halationSupportGroup", "SUPPORT", "Support.", false);
    OFX::StringParamDescriptor* creditsParam = p_Desc.defineStringParam("halationCreditsLabel");
    creditsParam->setLabels("Credits", "Credits", "Credits");
    creditsParam->setDefault("Made by Loïs Plagnard · Glare bloom: Blender Foundation");
    creditsParam->setStringType(OFX::eStringTypeLabel);
    creditsParam->setAnimates(false);
    creditsParam->setParent(*supportG);
    OFX::PushButtonParamDescriptor* helpBtn = p_Desc.definePushButtonParam("halationHelp");
    helpBtn->setLabels("Help", "Help", "Help");
    helpBtn->setHint("Docs.");
    helpBtn->setParent(*supportG);
    OFX::PushButtonParamDescriptor* reportBugBtn = p_Desc.definePushButtonParam("halationReportIssue");
    reportBugBtn->setLabels("Report a bug", "Report a bug", "Report a bug");
    reportBugBtn->setHint("Report.");
    reportBugBtn->setParent(*supportG);
    OFX::PushButtonParamDescriptor* openLogBtn = p_Desc.definePushButtonParam("halationOpenLog");
    openLogBtn->setLabels("Open Log", "Open Log", "Open Log");
    openLogBtn->setHint("Log.");
    openLogBtn->setParent(*supportG);

    page->addChild(*presetsG);
    page->addChild(*inputG);
    page->addChild(*pipelineG);
    page->addChild(*effectWindowG);
    page->addChild(*mainG);
    page->addChild(*mtfG);
    page->addChild(*glareG);
    page->addChild(*supportG);
}
