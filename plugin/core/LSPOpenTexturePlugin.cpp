#include "LSPOpenTexturePlugin.h"
#include "LSPOpenTexturePluginInternal.h"
#include "LSPOpenTextureDescribe.h"
#include "LSPOpenTextureProcessor.h"
#include "LSPOpenTextureConstants.h"
#include "LSPOpenTextureEffectWindow.h"
#include "LSPOpenTextureGamut.h"
#include "LSPOpenTextureLog.h"
#include "LSPOpenTextureMtfIdentity.h"
#include "LSPOpenTextureGlareMapping.h"
#include "LSPOpenTextureParamSchema.h"
#include "LSPOpenTextureParamUtils.h"
#include "LSPOpenTexturePresetHelpers.h"

#include "ofxsCore.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <memory>
#include <string>
#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <shellapi.h>
#endif

namespace {

bool renderScalesMatchBetweenClips(const OFX::Image& p_Src, const OFX::Image& p_Dst) {
    const OfxPointD& a = p_Src.getRenderScale();
    const OfxPointD& b = p_Dst.getRenderScale();
    const double e = 1.0e-6;
    return std::fabs(a.x - b.x) <= e && std::fabs(a.y - b.y) <= e;
}

void setParamsEnabled(bool on, std::initializer_list<OFX::Param*> params) {
    for (OFX::Param* p : params) {
        if (p)
            p->setEnabled(on);
    }
}

}

LSPOpenTexturePlugin::LSPOpenTexturePlugin(OfxImageEffectHandle p_Handle)
    : OFX::ImageEffect(p_Handle)
    , m_DstClip(nullptr)
    , m_SrcClip(nullptr)
    , m_LookPresetFolder(nullptr)
    , m_LookPreset(nullptr)
    , m_OperationOrder(nullptr)
    , m_EffectWindowEnable(nullptr)
    , m_EffectWindowAspectPreset(nullptr)
    , m_EffectWindowAspect(nullptr)
    , m_EffectWindowVertical(nullptr)
    , m_EffectWindowShowBorder(nullptr)
    , m_HalationEnable(nullptr)
    , m_HalationGlobalBlend(nullptr)
    , m_Intensity(nullptr)
    , m_Size(nullptr)
    , m_Color(nullptr)
    , m_Saturation(nullptr)
    , m_Distribution(nullptr)
    , m_ShowDistribution(nullptr)
    , m_InputGamut(nullptr)
    , m_TransferFunction(nullptr)
    , m_MtfEnable(nullptr)
    , m_MtfGlobalBlend(nullptr)
    , m_MtfGlobalStrength(nullptr)
    , m_MtfEQ1(nullptr)
    , m_MtfEQ2(nullptr)
    , m_MtfEQ3(nullptr)
    , m_MtfEQ4(nullptr)
    , m_MtfEQ5(nullptr)
    , m_MtfEQ6(nullptr)
    , m_MtfLumaBlend(nullptr)
    , m_MtfDisplay(nullptr)
    , m_HalationResetBtn(nullptr)
    , m_MtfResetBtn(nullptr)
    , m_GlareEnable(nullptr)
    , m_GlareResetBtn(nullptr)
    , m_GlareGlobalBlend(nullptr)
    , m_GlareThreshold(nullptr)
    , m_GlareMinHighlightsNits(nullptr)
    , m_GlareSmoothness(nullptr)
    , m_GlareClampHighlights(nullptr)
    , m_GlareMaxHighlights(nullptr)
    , m_GlareMaxHighlightsNits(nullptr)
    , m_GlareStrength(nullptr)
    , m_GlareSaturation(nullptr)
    , m_GlareTemperature(nullptr)
    , m_GlareExposure(nullptr)
    , m_GlareSpread(nullptr)
    , m_GlareDisplay(nullptr)
    , m_FolderHasNoneOnly(true)
    , m_ApplyingPreset(false)
    , m_SuppressLookPresetApply(false)
    , m_LookPresetFirstRenderResyncDone(false)
    , m_SyncingEffectWindowAspect(false)
    , m_SyncingMaxHighlights(false) {
    m_DstClip = fetchClip(kOfxImageEffectOutputClipName);
    m_SrcClip = fetchClip(kOfxImageEffectSimpleSourceClipName);
    m_LookPresetFolder = fetchChoiceParam("halationLookPresetFolder");
    m_LookPreset = fetchChoiceParam("halationLookPreset");
    m_OperationOrder = fetchChoiceParam("halationOperationOrder");
    m_EffectWindowEnable = fetchBooleanParam("halationEffectWindowEnable");
    m_EffectWindowAspectPreset = fetchChoiceParam("halationEffectWindowAspectPreset");
    m_EffectWindowAspect = fetchDoubleParam("halationEffectWindowAspect");
    m_EffectWindowVertical = fetchBooleanParam("halationEffectWindowVertical");
    m_EffectWindowShowBorder = fetchBooleanParam("halationEffectWindowShowBorder");
    m_HalationEnable = fetchBooleanParam("halationEnable");
    m_HalationGlobalBlend = fetchDoubleParam("halationGlobalBlend");
    m_Intensity = fetchDoubleParam("halationIntensity");
    m_Size = fetchDoubleParam("halationSize");
    m_Color = fetchDoubleParam("halationColor");
    m_Saturation = fetchDoubleParam("halationSaturation");
    m_Distribution = fetchDoubleParam("halationDistribution");
    m_ShowDistribution = fetchBooleanParam("halationShowDistribution");
    m_InputGamut = fetchChoiceParam("halationInputGamut");
    m_TransferFunction = fetchChoiceParam("halationTransferFunction");
    m_MtfEnable = fetchBooleanParam("halationMtfEnable");
    m_MtfGlobalBlend = fetchDoubleParam("halationMtfGlobalBlend");
    m_MtfGlobalStrength = fetchDoubleParam("halationMtfGlobalStrength");
    m_MtfEQ1 = fetchDoubleParam("halationMtfEQ1");
    m_MtfEQ2 = fetchDoubleParam("halationMtfEQ2");
    m_MtfEQ3 = fetchDoubleParam("halationMtfEQ3");
    m_MtfEQ4 = fetchDoubleParam("halationMtfEQ4");
    m_MtfEQ5 = fetchDoubleParam("halationMtfEQ5");
    m_MtfEQ6 = fetchDoubleParam("halationMtfEQ6");
    m_MtfLumaBlend = fetchDoubleParam("halationMtfLumaBlend");
    m_MtfDisplay = fetchChoiceParam("halationMtfDisplay");
    m_HalationResetBtn = fetchPushButtonParam("halationResetHalation");
    m_MtfResetBtn = fetchPushButtonParam("halationResetMtf");
    m_GlareEnable = fetchBooleanParam("halationGlareEnable");
    m_GlareResetBtn = fetchPushButtonParam("halationResetGlare");
    m_GlareGlobalBlend = fetchDoubleParam("halationGlareGlobalBlend");
    m_GlareThreshold = fetchDoubleParam("halationGlareThreshold");
    m_GlareMinHighlightsNits = fetchDoubleParam("halationGlareMinHighlightsNits");
    m_GlareSmoothness = fetchDoubleParam("halationGlareSmoothness");
    m_GlareClampHighlights = fetchBooleanParam("halationGlareClampHighlights");
    m_GlareMaxHighlights = fetchDoubleParam("halationGlareMaxHighlights");
    m_GlareMaxHighlightsNits = fetchDoubleParam("halationGlareMaxHighlightsNits");
    m_GlareStrength = fetchDoubleParam("halationGlareStrength");
    m_GlareSaturation = fetchDoubleParam("halationGlareSaturation");
    m_GlareTemperature = fetchDoubleParam("halationGlareTemperature");
    m_GlareExposure = fetchDoubleParam("halationGlareExposure");
    m_GlareSpread = fetchDoubleParam("halationGlareSpread");
    m_GlareDisplay = fetchChoiceParam("halationGlareDisplay");

    OFX::StringParam* creditsLabel = fetchStringParam("halationCreditsLabel");
    if (creditsLabel)
        creditsLabel->setEnabled(false);
    if (m_GlareMinHighlightsNits)
        m_GlareMinHighlightsNits->setEnabled(false);
    if (m_GlareMaxHighlightsNits)
        m_GlareMaxHighlightsNits->setEnabled(false);

    {
        const std::string versionStr = PLUGIN_VERSION_STR;
        OFX::ImageEffectHostDescription* host = OFX::getImageEffectHostDescription();
        const std::string hostName = host ? host->hostName : "unknown";
        const std::string hostLabel = host ? host->hostLabel : "";
        std::string hostVersion;
        if (host) {
            if (!host->versionLabel.empty())
                hostVersion = host->versionLabel;
            else if (host->versionMajor != 0 || host->versionMinor != 0 || host->versionMicro != 0)
                hostVersion = std::to_string(host->versionMajor) + "." + std::to_string(host->versionMinor) + "." +
                              std::to_string(host->versionMicro);
        }
        const std::string buildInfo = __DATE__;
        const std::string bundlePath = LSPOpenTextureLog::getPluginBundleRootPath();
        LSP_OPEN_TEXTURE_LOG_SESSION_START(kPluginName, versionStr, hostName, hostLabel, hostVersion, buildInfo, bundlePath, "");
    }

    syncLookPresetMenuFromDisk(0.0, nullptr);
    syncHalationChildParamsEnabled();
    syncMtfChildParamsEnabled();
    syncGlareChildParamsEnabled();
    if (m_GlareMaxHighlights) {
        double raw = 0.0;
        m_GlareMaxHighlights->getValue(raw);
        if (raw > 1.0) {
            m_SyncingMaxHighlights = true;
            m_GlareMaxHighlights->setValue(LSPOpenTextureGlareMapping::normalizeHighlightsUi(raw));
            m_SyncingMaxHighlights = false;
        }
    }
    enforceMinMaxHighlightsOrder();
    syncMinHighlightsNitsFromUi();
    syncMaxHighlightsNitsFromUi();
    syncEffectWindowChildParamsEnabled();
    syncHalationOverlayChildParamsEnabled();
    syncMtfOverlayChildParamsEnabled();
}

void LSPOpenTexturePlugin::syncEffectWindowChildParamsEnabled() {
    const bool groupOn = m_EffectWindowEnable ? m_EffectWindowEnable->getValue() : false;
    int presetIdx = kOpenTextureEffectWindowAspectPresetDefault;
    if (m_EffectWindowAspectPreset) {
        m_EffectWindowAspectPreset->getValue(presetIdx);
        const int presetMax =
            (m_EffectWindowAspectPreset->getNOptions() > 0) ? static_cast<int>(m_EffectWindowAspectPreset->getNOptions()) - 1
                                                            : kOpenTextureEffectWindowAspectPresetCount - 1;
        if (presetIdx < 0)
            presetIdx = 0;
        else if (presetIdx > presetMax)
            presetIdx = presetMax;
    }
    const bool customAspect = presetIdx == kOpenTextureEffectWindowAspectPresetCustom;
    setParamsEnabled(groupOn, {m_EffectWindowAspectPreset, m_EffectWindowVertical, m_EffectWindowShowBorder});
    if (m_EffectWindowAspect)
        m_EffectWindowAspect->setEnabled(groupOn && customAspect);
}

void LSPOpenTexturePlugin::syncHalationOverlayChildParamsEnabled() {
    const bool on = m_HalationEnable ? m_HalationEnable->getValue() : false;
    setParamsEnabled(on, {m_ShowDistribution});
}

void LSPOpenTexturePlugin::syncMtfOverlayChildParamsEnabled() {
    const bool on = m_MtfEnable ? m_MtfEnable->getValue() : false;
    setParamsEnabled(on, {m_MtfDisplay});
}

void LSPOpenTexturePlugin::syncMinHighlightsNitsFromUi() {
    if (!m_GlareThreshold || !m_GlareMinHighlightsNits || m_SyncingMaxHighlights)
        return;
    double ui = LSPOpenTextureGlareMapping::defaultMinHighlightsUi();
    m_GlareThreshold->getValue(ui);
    ui = LSPOpenTextureGlareMapping::normalizeHighlightsUi(ui);
    m_SyncingMaxHighlights = true;
    m_GlareMinHighlightsNits->setValue(LSPOpenTextureGlareMapping::uiToHighlightsNits(static_cast<float>(ui)));
    m_SyncingMaxHighlights = false;
}

void LSPOpenTexturePlugin::syncMaxHighlightsNitsFromUi() {
    if (!m_GlareMaxHighlights || !m_GlareMaxHighlightsNits || m_SyncingMaxHighlights)
        return;
    double ui = LSPOpenTextureGlareMapping::defaultMaxHighlightsUi();
    m_GlareMaxHighlights->getValue(ui);
    ui = LSPOpenTextureGlareMapping::normalizeHighlightsUi(ui);
    m_SyncingMaxHighlights = true;
    m_GlareMaxHighlightsNits->setValue(LSPOpenTextureGlareMapping::uiToHighlightsNits(static_cast<float>(ui)));
    m_SyncingMaxHighlights = false;
}

void LSPOpenTexturePlugin::enforceMinMaxHighlightsOrder() {
    if (!m_GlareThreshold || !m_GlareMaxHighlights || m_SyncingMaxHighlights)
        return;
    double minUi = LSPOpenTextureGlareMapping::defaultMinHighlightsUi();
    double maxUi = LSPOpenTextureGlareMapping::defaultMaxHighlightsUi();
    m_GlareThreshold->getValue(minUi);
    m_GlareMaxHighlights->getValue(maxUi);
    minUi = LSPOpenTextureGlareMapping::normalizeHighlightsUi(minUi);
    maxUi = LSPOpenTextureGlareMapping::normalizeHighlightsUi(maxUi);
    if (minUi <= maxUi)
        return;
    m_SyncingMaxHighlights = true;
    m_GlareThreshold->setValue(maxUi);
    m_SyncingMaxHighlights = false;
}

void LSPOpenTexturePlugin::syncGlareChildParamsEnabled() {
    const bool on = m_GlareEnable ? m_GlareEnable->getValue() : false;
    const bool clampOn = m_GlareClampHighlights ? m_GlareClampHighlights->getValue() : false;
    setParamsEnabled(on,
                     {m_GlareResetBtn,
                      m_GlareGlobalBlend,
                      m_GlareThreshold,
                      m_GlareSmoothness,
                      m_GlareClampHighlights,
                      m_GlareStrength,
                      m_GlareSaturation,
                      m_GlareTemperature,
                      m_GlareExposure,
                      m_GlareSpread,
                      m_GlareDisplay});
    if (m_GlareMaxHighlights)
        m_GlareMaxHighlights->setEnabled(on && clampOn);
}

void LSPOpenTexturePlugin::applyEffectWindowAspectFromPresetChoice(double time) {
    (void)time;
    if (!m_EffectWindowAspectPreset || !m_EffectWindowAspect)
        return;
    int presetIdx = 0;
    m_EffectWindowAspectPreset->getValue(presetIdx);
    const int presetMax =
        (m_EffectWindowAspectPreset->getNOptions() > 0) ? static_cast<int>(m_EffectWindowAspectPreset->getNOptions()) - 1
                                                        : kOpenTextureEffectWindowAspectPresetCount - 1;
    if (presetIdx < 0)
        presetIdx = 0;
    else if (presetIdx > presetMax)
        presetIdx = presetMax;
    if (presetIdx == kOpenTextureEffectWindowAspectPresetCustom)
        return;
    const float presetAspect = halationEffectWindowAspectForPresetIndex(presetIdx);
    if (presetAspect < 0.0f)
        return;
    m_SyncingEffectWindowAspect = true;
    m_EffectWindowAspect->setValue(static_cast<double>(presetAspect));
    m_SyncingEffectWindowAspect = false;
}

void LSPOpenTexturePlugin::syncHalationChildParamsEnabled() {
    const bool on = m_HalationEnable ? m_HalationEnable->getValue() : true;
    setParamsEnabled(on,
                     {m_HalationResetBtn,
                      m_HalationGlobalBlend,
                      m_Intensity,
                      m_Size,
                      m_Color,
                      m_Saturation,
                      m_Distribution});
    syncHalationOverlayChildParamsEnabled();
}

void LSPOpenTexturePlugin::syncMtfChildParamsEnabled() {
    const bool on = m_MtfEnable ? m_MtfEnable->getValue() : false;
    setParamsEnabled(on,
                     {m_MtfResetBtn,
                      m_MtfGlobalBlend,
                      m_MtfGlobalStrength,
                      m_MtfEQ1,
                      m_MtfEQ2,
                      m_MtfEQ3,
                      m_MtfEQ4,
                      m_MtfEQ5,
                      m_MtfEQ6,
                      m_MtfLumaBlend});
    syncMtfOverlayChildParamsEnabled();
}

void LSPOpenTexturePlugin::changedParam(const OFX::InstanceChangedArgs& p_Args, const std::string& p_ParamName) {
    if (handlePresetChangedParam(p_Args, p_ParamName))
        return;

    if (paramLeafIs(p_ParamName, "halationResetHalation")) {
        if (m_HalationGlobalBlend)
            m_HalationGlobalBlend->setValue(1.0);
        if (m_Intensity)
            m_Intensity->setValue(1.25);
        if (m_Size)
            m_Size->setValue(3.0);
        if (m_Color)
            m_Color->setValue(0.5);
        if (m_Saturation)
            m_Saturation->setValue(1.0);
        if (m_Distribution)
            m_Distribution->setValue(1.0);
        if (m_ShowDistribution)
            m_ShowDistribution->setValue(false);
        syncHalationChildParamsEnabled();
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationResetEffectWindow")) {
        if (m_EffectWindowEnable)
            m_EffectWindowEnable->setValue(false);
        if (m_EffectWindowAspectPreset) {
            m_SyncingEffectWindowAspect = true;
            m_EffectWindowAspectPreset->setValue(kOpenTextureEffectWindowAspectPresetDefault);
            m_SyncingEffectWindowAspect = false;
        }
        if (m_EffectWindowAspect) {
            m_SyncingEffectWindowAspect = true;
            m_EffectWindowAspect->setValue(static_cast<double>(kOpenTextureEffectWindowDefaultAspect));
            m_SyncingEffectWindowAspect = false;
        }
        if (m_EffectWindowVertical)
            m_EffectWindowVertical->setValue(false);
        if (m_EffectWindowShowBorder)
            m_EffectWindowShowBorder->setValue(false);
        syncHalationOverlayChildParamsEnabled();
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationResetMtf")) {
        if (m_MtfGlobalBlend)
            m_MtfGlobalBlend->setValue(1.0);
        if (m_MtfGlobalStrength)
            m_MtfGlobalStrength->setValue(1.0);
        if (m_MtfEQ1)
            m_MtfEQ1->setValue(0.0);
        if (m_MtfEQ2)
            m_MtfEQ2->setValue(0.0);
        if (m_MtfEQ3)
            m_MtfEQ3->setValue(0.0);
        if (m_MtfEQ4)
            m_MtfEQ4->setValue(0.0);
        if (m_MtfEQ5)
            m_MtfEQ5->setValue(0.0);
        if (m_MtfEQ6)
            m_MtfEQ6->setValue(0.0);
        if (m_MtfLumaBlend)
            m_MtfLumaBlend->setValue(0.0);
        if (m_MtfDisplay)
            m_MtfDisplay->setValue(0);
        syncMtfChildParamsEnabled();
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationResetGlare")) {
        if (m_GlareGlobalBlend)
            m_GlareGlobalBlend->setValue(1.0);
        if (m_GlareThreshold)
            m_GlareThreshold->setValue(LSPOpenTextureGlareMapping::defaultMinHighlightsUi());
        if (m_GlareMinHighlightsNits)
            m_GlareMinHighlightsNits->setValue(LSPOpenTextureGlareMapping::defaultMinHighlightsNits());
        if (m_GlareSmoothness)
            m_GlareSmoothness->setValue(0.4);
        if (m_GlareClampHighlights)
            m_GlareClampHighlights->setValue(true);
        if (m_GlareMaxHighlights)
            m_GlareMaxHighlights->setValue(LSPOpenTextureGlareMapping::defaultMaxHighlightsUi());
        if (m_GlareMaxHighlightsNits)
            m_GlareMaxHighlightsNits->setValue(LSPOpenTextureGlareMapping::defaultMaxHighlightsNits());
        if (m_GlareStrength)
            m_GlareStrength->setValue(1.0);
        if (m_GlareSaturation)
            m_GlareSaturation->setValue(1.0);
        if (m_GlareTemperature)
            m_GlareTemperature->setValue(0.5);
        if (m_GlareExposure)
            m_GlareExposure->setValue(1.0);
        if (m_GlareSpread)
            m_GlareSpread->setValue(0.5);
        if (m_GlareDisplay)
            m_GlareDisplay->setValue(0);
        syncGlareChildParamsEnabled();
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationHelp")) {
#if defined(__APPLE__)
        const std::string cmd = std::string("open \"") + kOpenTextureRepoUrl + "\"";
        if (std::system(cmd.c_str()) != 0)
            LSP_OPEN_TEXTURE_LOG_ERROR("open_help_url_failed");
#elif defined(_WIN32)
        const INT_PTR rc = reinterpret_cast<INT_PTR>(ShellExecuteA(nullptr, "open", kOpenTextureRepoUrl, nullptr, nullptr, SW_SHOWNORMAL));
        if (rc <= 32)
            LSP_OPEN_TEXTURE_LOG_ERROR("open_help_url_failed");
#endif
        return;
    }
    if (paramLeafIs(p_ParamName, "halationReportIssue")) {
#if defined(__APPLE__)
        const std::string cmd = std::string("open \"") + kOpenTextureIssuesUrl + "\"";
        if (std::system(cmd.c_str()) != 0)
            LSP_OPEN_TEXTURE_LOG_ERROR("open_report_issue_url_failed");
#elif defined(_WIN32)
        const INT_PTR rc = reinterpret_cast<INT_PTR>(ShellExecuteA(nullptr, "open", kOpenTextureIssuesUrl, nullptr, nullptr, SW_SHOWNORMAL));
        if (rc <= 32)
            LSP_OPEN_TEXTURE_LOG_ERROR("open_report_issue_url_failed");
#endif
        return;
    }
    if (paramLeafIs(p_ParamName, "halationOpenLog")) {
        LSPOpenTextureLog::ensureLogFileExists();
        const std::string path = LSPOpenTextureLog::getLogPath();
#if defined(__APPLE__)
        const std::string cmd = std::string("open \"") + path + "\"";
        if (std::system(cmd.c_str()) != 0)
            LSP_OPEN_TEXTURE_LOG_ERROR("open_log_failed");
#elif defined(_WIN32)
        const INT_PTR rc = reinterpret_cast<INT_PTR>(ShellExecuteA(nullptr, "open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
        if (rc <= 32)
            LSP_OPEN_TEXTURE_LOG_ERROR("open_log_failed");
#endif
        return;
    }
    if (paramLeafIs(p_ParamName, "halationEnable")) {
        syncHalationChildParamsEnabled();
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationMtfEnable")) {
        syncMtfChildParamsEnabled();
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationGlareEnable")) {
        syncGlareChildParamsEnabled();
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationGlareClampHighlights")) {
        syncGlareChildParamsEnabled();
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationGlareThreshold")) {
        if (!m_SyncingMaxHighlights) {
            enforceMinMaxHighlightsOrder();
            syncMinHighlightsNitsFromUi();
        }
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationGlareMaxHighlights")) {
        if (!m_SyncingMaxHighlights) {
            // old saves put linear nits on this knob; rewrite to log ui so readout isnt lying
            if (m_GlareMaxHighlights) {
                double raw = 0.0;
                m_GlareMaxHighlights->getValue(raw);
                if (raw > 1.0) {
                    m_SyncingMaxHighlights = true;
                    m_GlareMaxHighlights->setValue(LSPOpenTextureGlareMapping::normalizeHighlightsUi(raw));
                    m_SyncingMaxHighlights = false;
                }
            }
            enforceMinMaxHighlightsOrder();
            syncMaxHighlightsNitsFromUi();
            syncMinHighlightsNitsFromUi();
        }
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationEffectWindowEnable")) {
        syncEffectWindowChildParamsEnabled();
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationEffectWindowAspectPreset")) {
        applyEffectWindowAspectFromPresetChoice(p_Args.time);
        syncEffectWindowChildParamsEnabled();
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationEffectWindowAspect")) {
        if (!m_SyncingEffectWindowAspect && m_EffectWindowAspectPreset) {
            m_SyncingEffectWindowAspect = true;
            m_EffectWindowAspectPreset->setValue(kOpenTextureEffectWindowAspectPresetCustom);
            m_SyncingEffectWindowAspect = false;
        }
        syncEffectWindowChildParamsEnabled();
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }
    if (paramLeafIs(p_ParamName, "halationEffectWindowVertical") || paramLeafIs(p_ParamName, "halationEffectWindowShowBorder")) {
        bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
        return;
    }

    bumpLookPresetToCustomIfNeeded(p_Args, p_ParamName);
}

bool LSPOpenTexturePlugin::isIdentity(const OFX::IsIdentityArguments& p_Args, OFX::Clip*& p_IdentityClip, double& p_IdentityTime) {
    constexpr double kEps = 1.0e-5;

    if (m_EffectWindowEnable && m_EffectWindowEnable->getValueAtTime(p_Args.time))
        return false;
    if (m_ShowDistribution && m_ShowDistribution->getValueAtTime(p_Args.time))
        return false;

    bool halationEnable = false;
    double halationGlobalBlend = 1.0;
    double size = 0.0;
    if (m_HalationEnable)
        halationEnable = m_HalationEnable->getValueAtTime(p_Args.time);
    if (m_HalationGlobalBlend)
        m_HalationGlobalBlend->getValueAtTime(p_Args.time, halationGlobalBlend);
    if (m_Size)
        m_Size->getValueAtTime(p_Args.time, size);

    const bool halationActive = halationEnable && halationGlobalBlend > kEps && size > kEps;

    bool mtfEnable = false;
    double mtfGlobalBlend = 1.0;
    double mtfGlobalStrength = 1.0;
    float mtfEqRaw[8];
    float mtfEq[8];
    for (int i = 0; i < 8; ++i)
        mtfEqRaw[i] = (i < 6) ? 0.0f : ((i == 6) ? 1.0f : 0.0f);
    int mtfDisplay = 0;
    if (m_MtfEnable)
        mtfEnable = m_MtfEnable->getValueAtTime(p_Args.time);
    if (m_MtfGlobalBlend)
        m_MtfGlobalBlend->getValueAtTime(p_Args.time, mtfGlobalBlend);
    if (m_MtfGlobalStrength)
        m_MtfGlobalStrength->getValueAtTime(p_Args.time, mtfGlobalStrength);
    double eqd = 0.0;
    if (m_MtfEQ1) {
        m_MtfEQ1->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[0] = static_cast<float>(eqd);
    }
    if (m_MtfEQ2) {
        m_MtfEQ2->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[1] = static_cast<float>(eqd);
    }
    if (m_MtfEQ3) {
        m_MtfEQ3->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[2] = static_cast<float>(eqd);
    }
    if (m_MtfEQ4) {
        m_MtfEQ4->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[3] = static_cast<float>(eqd);
    }
    if (m_MtfEQ5) {
        m_MtfEQ5->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[4] = static_cast<float>(eqd);
    }
    if (m_MtfEQ6) {
        m_MtfEQ6->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[5] = static_cast<float>(eqd);
    }
    mtfEqRaw[6] = kOpenTextureMtfBaseFreqFixed * kOpenTextureMtfBaseFreqUnderHoodScale;
    mtfEqRaw[7] = 0.0f;
    openTextureMtfBuildEffectiveEq(mtfEq, mtfEqRaw, static_cast<float>(mtfGlobalStrength));
    if (m_MtfDisplay)
        m_MtfDisplay->getValueAtTime(p_Args.time, mtfDisplay);
    if (mtfDisplay < 0)
        mtfDisplay = 0;
    else if (mtfDisplay == 7)
        mtfDisplay = 0;

    const bool mtfActive = mtfEnable && !openTextureMtfIsIdentity(mtfEq, mtfDisplay, static_cast<float>(mtfGlobalBlend));

    bool glareEnable = false;
    double glareGlobalBlend = 1.0;
    double glareStrength = 1.0;
    int glareDisplay = 0;
    if (m_GlareEnable)
        glareEnable = m_GlareEnable->getValueAtTime(p_Args.time);
    if (m_GlareGlobalBlend)
        m_GlareGlobalBlend->getValueAtTime(p_Args.time, glareGlobalBlend);
    if (m_GlareStrength)
        m_GlareStrength->getValueAtTime(p_Args.time, glareStrength);
    if (m_GlareDisplay)
        m_GlareDisplay->getValueAtTime(p_Args.time, glareDisplay);
    if (glareDisplay < 0)
        glareDisplay = 0;
    else if (glareDisplay > 2)
        glareDisplay = 2;

    const bool glareActive =
        (glareDisplay != 0) || !LSPOpenTextureGlareMapping::isIdentity(glareEnable, static_cast<float>(glareGlobalBlend), static_cast<float>(glareStrength));

    if (!halationActive && !mtfActive && !glareActive) {
        p_IdentityClip = m_SrcClip;
        p_IdentityTime = p_Args.time;
        return true;
    }
    return false;
}

void LSPOpenTexturePlugin::render(const OFX::RenderArguments& p_Args) {
    if (!m_LookPresetFirstRenderResyncDone) {
        m_LookPresetFirstRenderResyncDone = true;
        syncLookPresetMenuFromDisk(p_Args.time, nullptr);
    }

    std::unique_ptr<OFX::Image> dst(m_DstClip->fetchImage(p_Args.time));
    std::unique_ptr<OFX::Image> src(m_SrcClip->fetchImage(p_Args.time));
    if (!dst.get() || !src.get() || !dst->getPixelData() || !src->getPixelData()) {
        LSP_OPEN_TEXTURE_LOG_ERROR("render_fetch_image_or_pixel_data_null");
        OFX::throwSuiteStatusException(kOfxStatFailed);
    }
    if (!renderScalesMatchBetweenClips(*src, *dst)) {
        LSP_OPEN_TEXTURE_LOG_ERROR("render_scale_mismatch");
        OFX::throwSuiteStatusException(kOfxStatErrValue);
    }
    if (src->getPixelDepth() != dst->getPixelDepth() || src->getPixelComponents() != dst->getPixelComponents()) {
        LSP_OPEN_TEXTURE_LOG_ERROR("render_src_dst_format_mismatch");
        OFX::throwSuiteStatusException(kOfxStatErrValue);
    }
    if (dst->getPixelDepth() != OFX::eBitDepthFloat || dst->getPixelComponents() != OFX::ePixelComponentRGBA) {
        LSP_OPEN_TEXTURE_LOG_ERROR("render_requires_float_rgba");
        OFX::throwSuiteStatusException(kOfxStatErrFormat);
    }

    LSPOpenTextureProcessor proc(*this);
    double size = 2.0;
    double intensity = 1.0;
    double hue = 0.5;
    double saturation = 1.0;
    double distribution = 1.0;
    bool showDistribution = false;
    int transferFunction = 1;
    int inputGamut = kOpenTextureInputGamutDefault;
    bool halationEnable = false;
    int operationOrder = 0;
    double halationGlobalBlend = 1.0;
    bool mtfEnable = false;
    double mtfGlobalBlend = 1.0;
    double mtfGlobalStrength = 1.0;
    float mtfEqRaw[8];
    float mtfEq[8];
    for (int i = 0; i < 8; ++i)
        mtfEqRaw[i] = (i < 6) ? 0.0f : ((i == 6) ? 1.0f : 0.0f);
    int mtfDisplay = 0;
    double mtfLumaBlend = 0.0;
    if (m_Size)
        m_Size->getValueAtTime(p_Args.time, size);
    if (m_Intensity)
        m_Intensity->getValueAtTime(p_Args.time, intensity);
    if (m_Color)
        m_Color->getValueAtTime(p_Args.time, hue);
    if (m_Saturation)
        m_Saturation->getValueAtTime(p_Args.time, saturation);
    if (m_Distribution)
        m_Distribution->getValueAtTime(p_Args.time, distribution);
    if (m_ShowDistribution)
        showDistribution = m_ShowDistribution->getValueAtTime(p_Args.time);
    if (m_InputGamut)
        m_InputGamut->getValueAtTime(p_Args.time, inputGamut);
    if (m_TransferFunction)
        m_TransferFunction->getValueAtTime(p_Args.time, transferFunction);
    if (hue < 0.0)
        hue = 0.0;
    else if (hue > 1.0)
        hue = 1.0;
    if (intensity < 0.0)
        intensity = 0.0;
    else if (intensity > 2.0)
        intensity = 2.0;
    if (saturation < 0.0)
        saturation = 0.0;
    else if (saturation > 2.0)
        saturation = 2.0;
    if (m_HalationEnable)
        halationEnable = m_HalationEnable->getValueAtTime(p_Args.time);
    if (m_OperationOrder)
        m_OperationOrder->getValueAtTime(p_Args.time, operationOrder);
    if (m_HalationGlobalBlend)
        m_HalationGlobalBlend->getValueAtTime(p_Args.time, halationGlobalBlend);
    if (m_MtfEnable)
        mtfEnable = m_MtfEnable->getValueAtTime(p_Args.time);
    if (m_MtfGlobalBlend)
        m_MtfGlobalBlend->getValueAtTime(p_Args.time, mtfGlobalBlend);
    if (m_MtfGlobalStrength)
        m_MtfGlobalStrength->getValueAtTime(p_Args.time, mtfGlobalStrength);
    double eqd = 0.0;
    if (m_MtfEQ1) {
        m_MtfEQ1->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[0] = static_cast<float>(eqd);
    }
    if (m_MtfEQ2) {
        m_MtfEQ2->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[1] = static_cast<float>(eqd);
    }
    if (m_MtfEQ3) {
        m_MtfEQ3->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[2] = static_cast<float>(eqd);
    }
    if (m_MtfEQ4) {
        m_MtfEQ4->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[3] = static_cast<float>(eqd);
    }
    if (m_MtfEQ5) {
        m_MtfEQ5->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[4] = static_cast<float>(eqd);
    }
    if (m_MtfEQ6) {
        m_MtfEQ6->getValueAtTime(p_Args.time, eqd);
        mtfEqRaw[5] = static_cast<float>(eqd);
    }
    mtfEqRaw[6] = kOpenTextureMtfBaseFreqFixed * kOpenTextureMtfBaseFreqUnderHoodScale;
    mtfEqRaw[7] = 0.0f;
    openTextureMtfBuildEffectiveEq(mtfEq, mtfEqRaw, static_cast<float>(mtfGlobalStrength));
    if (m_MtfLumaBlend)
        m_MtfLumaBlend->getValueAtTime(p_Args.time, mtfLumaBlend);
    if (mtfLumaBlend < 0.0)
        mtfLumaBlend = 0.0;
    else if (mtfLumaBlend > 1.0)
        mtfLumaBlend = 1.0;
    if (m_MtfDisplay)
        m_MtfDisplay->getValueAtTime(p_Args.time, mtfDisplay);
    const int mtfDispMax = (m_MtfDisplay && m_MtfDisplay->getNOptions() > 0) ? static_cast<int>(m_MtfDisplay->getNOptions()) - 1 : 6;
    if (mtfDisplay < 0)
        mtfDisplay = 0;
    else if (mtfDisplay == 7)
        mtfDisplay = 0;
    else if (mtfDisplay > mtfDispMax)
        mtfDisplay = mtfDispMax;
    const int gamutMax =
        (m_InputGamut && m_InputGamut->getNOptions() > 0) ? static_cast<int>(m_InputGamut->getNOptions()) - 1 : kOpenTextureInputGamutCount - 1;
    if (inputGamut < 0)
        inputGamut = 0;
    else if (inputGamut > gamutMax)
        inputGamut = gamutMax;
    const int tfMax =
        (m_TransferFunction && m_TransferFunction->getNOptions() > 0) ? static_cast<int>(m_TransferFunction->getNOptions()) - 1 : 9;
    if (transferFunction < 0)
        transferFunction = 0;
    else if (transferFunction > tfMax)
        transferFunction = tfMax;
    if (operationOrder < 0)
        operationOrder = 0;
    else if (operationOrder > 1)
        operationOrder = 1;

    bool effectWindowEnable = false;
    double effectWindowAspect = static_cast<double>(kOpenTextureEffectWindowDefaultAspect);
    bool effectWindowVertical = false;
    bool effectWindowShowBorder = false;
    if (m_EffectWindowEnable)
        effectWindowEnable = m_EffectWindowEnable->getValueAtTime(p_Args.time);
    if (m_EffectWindowAspect)
        m_EffectWindowAspect->getValueAtTime(p_Args.time, effectWindowAspect);
    if (effectWindowAspect < 1.0)
        effectWindowAspect = 1.0;
    else if (effectWindowAspect > 2.76)
        effectWindowAspect = 2.76;
    if (m_EffectWindowVertical)
        effectWindowVertical = m_EffectWindowVertical->getValueAtTime(p_Args.time);
    if (m_EffectWindowShowBorder)
        effectWindowShowBorder = m_EffectWindowShowBorder->getValueAtTime(p_Args.time);

    bool glareEnable = false;
    double glareGlobalBlend = 1.0;
    double glareThreshold = LSPOpenTextureGlareMapping::defaultMinHighlightsUi();
    double glareSmoothness = 0.4;
    bool glareClampHighlights = true;
    double glareMaxHighlights = LSPOpenTextureGlareMapping::defaultMaxHighlightsUi();
    double glareStrength = 1.0;
    double glareSaturation = 1.0;
    double glareTemperature = 0.5;
    double glareExposure = 1.0;
    double glareSpreadUi = LSPOpenTextureGlareMapping::defaultSpreadUi();
    int glareDisplay = 0;
    if (m_GlareEnable)
        glareEnable = m_GlareEnable->getValueAtTime(p_Args.time);
    if (m_GlareGlobalBlend)
        m_GlareGlobalBlend->getValueAtTime(p_Args.time, glareGlobalBlend);
    if (m_GlareThreshold)
        m_GlareThreshold->getValueAtTime(p_Args.time, glareThreshold);
    if (m_GlareSmoothness)
        m_GlareSmoothness->getValueAtTime(p_Args.time, glareSmoothness);
    if (m_GlareClampHighlights)
        glareClampHighlights = m_GlareClampHighlights->getValueAtTime(p_Args.time);
    if (m_GlareMaxHighlights)
        m_GlareMaxHighlights->getValueAtTime(p_Args.time, glareMaxHighlights);
    if (m_GlareStrength)
        m_GlareStrength->getValueAtTime(p_Args.time, glareStrength);
    if (m_GlareSaturation)
        m_GlareSaturation->getValueAtTime(p_Args.time, glareSaturation);
    if (m_GlareTemperature)
        m_GlareTemperature->getValueAtTime(p_Args.time, glareTemperature);
    if (m_GlareExposure)
        m_GlareExposure->getValueAtTime(p_Args.time, glareExposure);
    if (m_GlareSpread)
        m_GlareSpread->getValueAtTime(p_Args.time, glareSpreadUi);
    if (m_GlareDisplay)
        m_GlareDisplay->getValueAtTime(p_Args.time, glareDisplay);
    if (glareDisplay < 0)
        glareDisplay = 0;
    else if (glareDisplay > 2)
        glareDisplay = 2;

    const OfxRectI& srcBounds = src->getBounds();
    const int srcPixelW = std::max(1, srcBounds.x2 - srcBounds.x1);
    const int srcPixelH = std::max(1, srcBounds.y2 - srcBounds.y1);
    const float srcDiag =
        std::hypot(static_cast<float>(srcPixelW), static_cast<float>(srcPixelH));
    const float resScale =
        (srcDiag > 1e-6f && kOpenTextureReferenceDiagonalPixels > 1e-6f)
            ? (srcDiag / kOpenTextureReferenceDiagonalPixels)
            : 1.0f;
    const double scaledHalationSize = size * static_cast<double>(resScale);
    // glare spread already tracks frame size through bloom pyramid; dont * resScale or you double count
    const double scaledGlareSpread =
        static_cast<double>(LSPOpenTextureGlareMapping::uiToSpread(static_cast<float>(glareSpreadUi)));

    proc.setDstImg(dst.get());
    proc.setSrcImg(src.get());
    proc.setParams(
        halationEnable,
        halationGlobalBlend,
        intensity,
        scaledHalationSize,
        hue,
        saturation,
        distribution,
        showDistribution,
        transferFunction,
        inputGamut,
        operationOrder,
        mtfEnable,
        mtfGlobalBlend,
        mtfEq,
        mtfDisplay,
        static_cast<float>(mtfLumaBlend),
        effectWindowEnable,
        static_cast<float>(effectWindowAspect),
        effectWindowVertical,
        effectWindowShowBorder,
        glareEnable,
        glareGlobalBlend,
        glareThreshold,
        glareSmoothness,
        glareClampHighlights,
        glareMaxHighlights,
        glareStrength,
        glareSaturation,
        glareTemperature,
        glareExposure,
        scaledGlareSpread,
        glareDisplay);
    proc.setRenderWindow(p_Args.renderWindow);
    proc.setGPURenderArgs(p_Args);
    proc.process();
}

LSPOpenTexturePluginFactory::LSPOpenTexturePluginFactory()
    : OFX::PluginFactoryHelper<LSPOpenTexturePluginFactory>(kPluginIdentifier, kPluginVersionMajor, kPluginVersionMinor) {}

void LSPOpenTexturePluginFactory::describe(OFX::ImageEffectDescriptor& p_Desc) {
#ifdef __APPLE__
    {
        const std::string hostBundle = p_Desc.getPropertySet().propGetString(kOfxPluginPropFilePath, false);
        if (!hostBundle.empty())
            LSPOpenTextureSetOFXPluginBundleRoot(hostBundle);
    }
    p_Desc.setSupportsMetalRender(true);
#elif defined(_WIN32)
    {
        const std::string hostBundle = p_Desc.getPropertySet().propGetString(kOfxPluginPropFilePath, false);
        if (!hostBundle.empty())
            LSPOpenTextureSetOFXPluginBundleRoot(hostBundle);
    }
    p_Desc.setSupportsCudaRender(true);
    p_Desc.setSupportsCudaStream(true);
#endif
    p_Desc.setLabels(kPluginName, kPluginName, kPluginName);
    p_Desc.setVersion(PLUGIN_VERSION_MAJOR, PLUGIN_VERSION_MINOR, PLUGIN_VERSION_PATCH, 0, std::string(PLUGIN_VERSION_STR));
    p_Desc.setPluginGrouping(kPluginGrouping);
    p_Desc.setPluginDescription(kPluginDescription);
    p_Desc.addSupportedContext(OFX::eContextFilter);
    p_Desc.addSupportedContext(OFX::eContextGeneral);
    p_Desc.addSupportedBitDepth(OFX::eBitDepthFloat);
    p_Desc.setSingleInstance(false);
    p_Desc.setHostFrameThreading(false);
    p_Desc.setSupportsMultiResolution(kSupportsMultiResolution);
    p_Desc.setSupportsTiles(kSupportsTiles);
    p_Desc.setTemporalClipAccess(false);
    p_Desc.setRenderTwiceAlways(false);
    p_Desc.setSupportsMultipleClipPARs(kSupportsMultipleClipPARs);
}

void LSPOpenTexturePluginFactory::describeInContext(OFX::ImageEffectDescriptor& p_Desc, OFX::ContextEnum p_Context) {
    describeOpenTextureInContext(p_Desc, p_Context);
}

OFX::ImageEffect* LSPOpenTexturePluginFactory::createInstance(OfxImageEffectHandle p_Handle, OFX::ContextEnum /*p_Context*/) {
    return new LSPOpenTexturePlugin(p_Handle);
}

void OFX::Plugin::getPluginIDs(OFX::PluginFactoryArray& p_FactoryArray) {
    static LSPOpenTexturePluginFactory s_factory;
    p_FactoryArray.push_back(&s_factory);
}
