#ifndef LSP_OPEN_TEXTURE_PLUGIN_INTERNAL_H
#define LSP_OPEN_TEXTURE_PLUGIN_INTERNAL_H

#include "LSPOpenTexturePresetHelpers.h"
#include "ofxsImageEffect.h"

#include <map>
#include <string>
#include <utility>
#include <vector>

class LSPOpenTexturePlugin : public OFX::ImageEffect {
public:
    explicit LSPOpenTexturePlugin(OfxImageEffectHandle p_Handle);

    void render(const OFX::RenderArguments& p_Args) override;
    bool isIdentity(const OFX::IsIdentityArguments& p_Args, OFX::Clip*& p_IdentityClip, double& p_IdentityTime) override;
    void changedParam(const OFX::InstanceChangedArgs& p_Args, const std::string& p_ParamName) override;

private:
    void syncHalationChildParamsEnabled();
    void syncMtfChildParamsEnabled();
    void syncEffectWindowChildParamsEnabled();
    void syncHalationOverlayChildParamsEnabled();
    void syncMtfOverlayChildParamsEnabled();
    void syncGlareChildParamsEnabled();
    void syncMinHighlightsNitsFromUi();
    void syncMaxHighlightsNitsFromUi();
    void enforceMinMaxHighlightsOrder(bool minChanged);
    void applyEffectWindowAspectFromPresetChoice(double time);

    void syncLookPresetMenuFromDisk(double time, const std::string* forceSelectPath);
    void rebuildLookMenuForFolderIndex(int folderIdx);
    void rebuildLookMenuForCurrentFolder(double time);
    void collectPresetParams(double time, std::map<std::string, std::string>& out);
    void applyPresetFromParams(double time, const std::map<std::string, std::string>& params);
    void saveCurrentAsPreset(double time);
    void loadExternalPreset(double time);
    void bumpLookPresetToCustomIfNeeded(const OFX::InstanceChangedArgs& args, const std::string& paramName);
    bool handlePresetChangedParam(const OFX::InstanceChangedArgs& args, const std::string& paramName);
    static std::string folderKeyForEntry(const LSPOpenTexturePresetFolderEntry& e);
    bool findFolderAndLookIndicesForPath(const std::vector<LSPOpenTexturePresetFolderEntry>& folders, const std::string& path, int& outFolderIdx,
        int& outLookIdx);

    OFX::Clip* m_DstClip;
    OFX::Clip* m_SrcClip;
    OFX::ChoiceParam* m_LookPresetFolder;
    OFX::ChoiceParam* m_LookPreset;
    OFX::ChoiceParam* m_OperationOrder;
    OFX::BooleanParam* m_EffectWindowEnable;
    OFX::ChoiceParam* m_EffectWindowAspectPreset;
    OFX::DoubleParam* m_EffectWindowAspect;
    OFX::BooleanParam* m_EffectWindowVertical;
    OFX::BooleanParam* m_EffectWindowShowBorder;
    OFX::BooleanParam* m_HalationEnable;
    OFX::DoubleParam* m_HalationGlobalBlend;
    OFX::DoubleParam* m_Intensity;
    OFX::DoubleParam* m_Size;
    OFX::DoubleParam* m_Color;
    OFX::DoubleParam* m_Saturation;
    OFX::DoubleParam* m_Distribution;
    OFX::BooleanParam* m_ShowDistribution;
    OFX::ChoiceParam* m_InputGamut;
    OFX::ChoiceParam* m_TransferFunction;
    OFX::BooleanParam* m_MtfEnable;
    OFX::DoubleParam* m_MtfGlobalBlend;
    OFX::DoubleParam* m_MtfGlobalStrength;
    OFX::DoubleParam* m_MtfEQ1;
    OFX::DoubleParam* m_MtfEQ2;
    OFX::DoubleParam* m_MtfEQ3;
    OFX::DoubleParam* m_MtfEQ4;
    OFX::DoubleParam* m_MtfEQ5;
    OFX::DoubleParam* m_MtfEQ6;
    OFX::DoubleParam* m_MtfLumaBlend;
    OFX::ChoiceParam* m_MtfDisplay;
    OFX::PushButtonParam* m_HalationResetBtn;
    OFX::PushButtonParam* m_MtfResetBtn;
    OFX::BooleanParam* m_GlareEnable;
    OFX::PushButtonParam* m_GlareResetBtn;
    OFX::DoubleParam* m_GlareGlobalBlend;
    OFX::DoubleParam* m_GlareThreshold;
    OFX::DoubleParam* m_GlareMinHighlightsNits;
    OFX::DoubleParam* m_GlareSmoothness;
    OFX::BooleanParam* m_GlareClampHighlights;
    OFX::DoubleParam* m_GlareMaxHighlights;
    OFX::DoubleParam* m_GlareMaxHighlightsNits;
    OFX::DoubleParam* m_GlareStrength;
    OFX::DoubleParam* m_GlareSaturation;
    OFX::DoubleParam* m_GlareTemperature;
    OFX::DoubleParam* m_GlareExposure;
    OFX::DoubleParam* m_GlareSpread;
    OFX::ChoiceParam* m_GlareDisplay;

    std::map<int, std::pair<std::string, bool>> m_PresetMapping;
    std::vector<LSPOpenTexturePresetFolderEntry> m_FolderEntries;
    bool m_FolderHasNoneOnly;
    bool m_ApplyingPreset;
    bool m_SuppressLookPresetApply;
    bool m_LookPresetFirstRenderResyncDone;
    bool m_SyncingEffectWindowAspect;
    bool m_SyncingMaxHighlights;
};

#endif
