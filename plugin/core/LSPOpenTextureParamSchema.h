#pragma once
// preset xml ids (2000+); never recycle a number once its out there

#include <string>

namespace LSPOpenTextureParamSchema {

static const int kStableIdBase = 2000;

struct ParamStableIdEntry {
    int id;
    const char* name;
};

static const ParamStableIdEntry kParamStableIdMap[] = {
    {2002, "halationOperationOrder"},
    {2003, "halationEnable"},
    {2004, "halationGlobalBlend"},
    {2005, "halationIntensity"},
    {2006, "halationSize"},
    {2007, "halationColor"},
    {2008, "halationSaturation"},
    {2009, "halationDistribution"},
    {2010, "halationMtfEnable"},
    {2011, "halationMtfGlobalBlend"},
    {2027, "halationMtfGlobalStrength"},
    {2012, "halationMtfEQ1"},
    {2013, "halationMtfEQ2"},
    {2014, "halationMtfEQ3"},
    {2015, "halationMtfEQ4"},
    {2016, "halationMtfEQ5"},
    {2017, "halationMtfEQ6"},
    {2024, "halationMtfLumaBlend"},
    {2028, "halationGlareEnable"},
    {2029, "halationGlareGlobalBlend"},
    {2031, "halationGlareThreshold"},
    {2032, "halationGlareSmoothness"},
    {2033, "halationGlareClampHighlights"},
    {2034, "halationGlareMaxHighlights"},
    {2035, "halationGlareStrength"},
    {2036, "halationGlareSaturation"},
    {2037, "halationGlareTemperature"},
    {2038, "halationGlareSpread"},
    {2039, "halationGlareExposure"},
};

static const int kParamStableIdCount = static_cast<int>(sizeof(kParamStableIdMap) / sizeof(kParamStableIdMap[0]));

inline int getParamStableId(const std::string& name) {
    for (int i = 0; i < kParamStableIdCount; ++i) {
        if (name == kParamStableIdMap[i].name)
            return kParamStableIdMap[i].id;
    }
    return -1;
}

inline std::string getParamNameFromStableId(int id) {
    for (int i = 0; i < kParamStableIdCount; ++i) {
        if (kParamStableIdMap[i].id == id)
            return kParamStableIdMap[i].name;
    }
    return std::string();
}

inline bool isPresetKeyNeverLoad(const std::string& name) {
    if (name == "halationShowDistribution")
        return true;
    if (name == "halationGlareDisplay")
        return true;
    if (name == "halationMtfDisplay")
        return true;
    if (name == "halationEffectWindowEnable")
        return true;
    if (name == "halationEffectWindowAspect")
        return true;
    if (name == "halationEffectWindowVertical")
        return true;
    if (name == "halationEffectWindowAspectPreset")
        return true;
    if (name == "halationEffectWindowShowBorder")
        return true;
    if (name == "halationTransferFunction")
        return true;
    if (name == "halationInputGamut")
        return true;
    if (name == "halationLookPresetFolder")
        return true;
    if (name == "halationLookPreset")
        return true;
    if (name == "halationExportPreset")
        return true;
    if (name == "halationImportPreset")
        return true;
    if (name == "halationOpenPresetFolder")
        return true;
    if (name == "halationRefreshPresets")
        return true;
    if (name == "halationResetHalation")
        return true;
    if (name == "halationResetMtf")
        return true;
    if (name == "halationResetEffectWindow")
        return true;
    if (name == "halationResetGlare")
        return true;
    if (name == "halationGlareMaxHighlightsNits")
        return true;
    if (name == "halationGlareMinHighlightsNits")
        return true;
    return false;
}

inline bool isPresetRelevantParam(const std::string& name) {
    if (isPresetKeyNeverLoad(name))
        return false;
    return getParamStableId(name) >= kStableIdBase;
}

}
