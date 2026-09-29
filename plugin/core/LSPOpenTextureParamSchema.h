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
    static const char* kNeverLoad[] = {
        "halationShowDistribution",
        "halationGlareDisplay",
        "halationMtfDisplay",
        "halationEffectWindowEnable",
        "halationEffectWindowAspect",
        "halationEffectWindowVertical",
        "halationEffectWindowAspectPreset",
        "halationEffectWindowShowBorder",
        "halationTransferFunction",
        "halationInputGamut",
        "halationLookPresetFolder",
        "halationLookPreset",
        "halationExportPreset",
        "halationImportPreset",
        "halationOpenPresetFolder",
        "halationRefreshPresets",
        "halationResetHalation",
        "halationResetMtf",
        "halationResetEffectWindow",
        "halationResetGlare",
        "halationGlareMaxHighlightsNits",
        "halationGlareMinHighlightsNits",
    };
    for (const char* key : kNeverLoad) {
        if (name == key)
            return true;
    }
    return false;
}

inline bool isPresetRelevantParam(const std::string& name) {
    if (isPresetKeyNeverLoad(name))
        return false;
    return getParamStableId(name) >= kStableIdBase;
}

}
