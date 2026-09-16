#include "LSPOpenTexturePresetMenus.h"
#include "LSPOpenTexturePluginInternal.h"
#include "LSPOpenTextureParamSchema.h"
#include "LSPOpenTextureParamUtils.h"
#include "LSPOpenTexturePresetDialogs.h"
#include "LSPOpenTexturePresetHelpers.h"
#include "LSPOpenTextureLog.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace {

std::string paramLeafName(const std::string& p_Name) {
    const size_t slash = p_Name.find_last_of("/.");
    if (slash == std::string::npos)
        return p_Name;
    return p_Name.substr(slash + 1);
}

void choiceParamSetFromPresetIndex(OFX::ChoiceParam* p, int idx) {
    if (!p)
        return;
    const int n = static_cast<int>(p->getNOptions());
    if (n <= 0)
        return;
    if (idx < 0)
        idx = 0;
    else if (idx >= n)
        idx = n - 1;
    p->setValue(idx);
}

}

void describeOpenTexturePresetParams(OFX::ImageEffectDescriptor& p_Desc, OFX::GroupParamDescriptor* presetsG) {
    OFX::ChoiceParamDescriptor* folderParam = p_Desc.defineChoiceParam("halationLookPresetFolder");
    folderParam->setLabels("Folder", "Folder", "Folder");
    folderParam->setHint("Folder.");
    folderParam->setAnimates(false);
    folderParam->setParent(*presetsG);
    {
        std::vector<LSPOpenTexturePresetFolderEntry> folders;
        collectOpenTextureLookPresetFolderEntries(folders);
        if (folders.empty())
            folderParam->appendOption("(none)");
        else {
            for (const auto& f : folders) {
                std::string label;
                if (formatOpenTextureLookPresetFolderMenuLabel(f, label))
                    folderParam->appendOption(label.c_str());
            }
        }
    }

    OFX::ChoiceParamDescriptor* lookParam = p_Desc.defineChoiceParam("halationLookPreset");
    lookParam->setLabels("Preset", "Preset", "Preset");
    lookParam->setHint("Preset.");
    lookParam->appendOption("---");
    lookParam->setDefault(0);
    lookParam->setAnimates(false);
    lookParam->setParent(*presetsG);
    {
        std::vector<LSPOpenTexturePresetFolderEntry> folders;
        collectOpenTextureLookPresetFolderEntries(folders);
        if (!folders.empty()) {
            const LSPOpenTexturePresetFolderEntry& first = folders[0];
            std::string dir = resolveOpenTextureLookPresetFolderDirectory(first);
            std::vector<std::string> paths = scanOpenTexturePresetDirectory(dir);
            orderOpenTexturePresetPathsForLookMenu(first, paths);
            for (const auto& p : paths)
                lookParam->appendOption(getOpenTexturePresetBasenameForLookMenu(p).c_str());
        }
    }

    OFX::PushButtonParamDescriptor* exportBtn = p_Desc.definePushButtonParam("halationExportPreset");
    exportBtn->setLabels("Export Preset", "Export Preset", "Export Preset");
    exportBtn->setHint("Export.");
    exportBtn->setParent(*presetsG);

    OFX::PushButtonParamDescriptor* importBtn = p_Desc.definePushButtonParam("halationImportPreset");
    importBtn->setLabels("Import Preset", "Import Preset", "Import Preset");
    importBtn->setHint("Import.");
    importBtn->setParent(*presetsG);

    OFX::PushButtonParamDescriptor* openFolderBtn = p_Desc.definePushButtonParam("halationOpenPresetFolder");
    openFolderBtn->setLabels("Open Folder", "Open Folder", "Open Folder");
    openFolderBtn->setHint("Folder.");
    openFolderBtn->setParent(*presetsG);

    OFX::PushButtonParamDescriptor* refreshBtn = p_Desc.definePushButtonParam("halationRefreshPresets");
    refreshBtn->setLabels("Refresh Presets", "Refresh Presets", "Refresh Presets");
    refreshBtn->setHint("Refresh.");
    refreshBtn->setParent(*presetsG);
}

std::string LSPOpenTexturePlugin::folderKeyForEntry(const LSPOpenTexturePresetFolderEntry& e) {
    switch (e.kind) {
        case kLSPOpenTexturePresetFolderBundle:
            return "bundle";
        case kLSPOpenTexturePresetFolderUserRoot:
            return "user";
        case kLSPOpenTexturePresetFolderUserSub:
            return "sub:" + e.userSubfolderName;
        default:
            return "";
    }
}

bool LSPOpenTexturePlugin::findFolderAndLookIndicesForPath(const std::vector<LSPOpenTexturePresetFolderEntry>& folders, const std::string& path,
    int& outFolderIdx, int& outLookIdx) {
    for (int fi = 0; fi < static_cast<int>(folders.size()); ++fi) {
        std::string dir = resolveOpenTextureLookPresetFolderDirectory(folders[static_cast<size_t>(fi)]);
        std::vector<std::string> files = scanOpenTexturePresetDirectory(dir);
        orderOpenTexturePresetPathsForLookMenu(folders[static_cast<size_t>(fi)], files);
        int lookIdx = 1;
        for (const auto& fpath : files) {
            if (fpath == path) {
                outFolderIdx = fi;
                outLookIdx = lookIdx;
                return true;
            }
            ++lookIdx;
        }
    }
    return false;
}

void LSPOpenTexturePlugin::rebuildLookMenuForFolderIndex(int folderIdx) {
    if (!m_LookPreset)
        return;
    m_PresetMapping.clear();
    m_LookPreset->resetOptions();
    m_LookPreset->appendOption("---");
    if (m_FolderHasNoneOnly || folderIdx < 0 || folderIdx >= static_cast<int>(m_FolderEntries.size()))
        return;
    const LSPOpenTexturePresetFolderEntry& fe = m_FolderEntries[static_cast<size_t>(folderIdx)];
    std::string dir = resolveOpenTextureLookPresetFolderDirectory(fe);
    std::vector<std::string> paths = scanOpenTexturePresetDirectory(dir);
    orderOpenTexturePresetPathsForLookMenu(fe, paths);
    int idx = 1;
    const bool isUser = fe.kind != kLSPOpenTexturePresetFolderBundle;
    for (const auto& p : paths) {
        m_PresetMapping[idx] = std::make_pair(p, isUser);
        m_LookPreset->appendOption(getOpenTexturePresetBasenameForLookMenu(p).c_str());
        ++idx;
    }
}

void LSPOpenTexturePlugin::rebuildLookMenuForCurrentFolder(double time) {
    int fidx = 0;
    if (m_LookPresetFolder)
        m_LookPresetFolder->getValueAtTime(time, fidx);
    rebuildLookMenuForFolderIndex(fidx);
}

void LSPOpenTexturePlugin::syncLookPresetMenuFromDisk(double time, const std::string* forceSelectPath) {
    if (!m_LookPreset)
        return;

    std::vector<LSPOpenTexturePresetFolderEntry> oldFolderEntries = m_FolderEntries;
    const bool oldNone = m_FolderHasNoneOnly;

    int prevFolderIdx = 0;
    int prevLookIdx = 0;
    if (m_LookPresetFolder)
        m_LookPresetFolder->getValueAtTime(time, prevFolderIdx);
    m_LookPreset->getValueAtTime(time, prevLookIdx);

    std::string prevLookPath;
    if (prevLookIdx >= 1 && !oldNone && prevFolderIdx >= 0 && prevFolderIdx < static_cast<int>(oldFolderEntries.size())) {
        const LSPOpenTexturePresetFolderEntry& fe = oldFolderEntries[static_cast<size_t>(prevFolderIdx)];
        std::string dir = resolveOpenTextureLookPresetFolderDirectory(fe);
        std::vector<std::string> files = scanOpenTexturePresetDirectory(dir);
        orderOpenTexturePresetPathsForLookMenu(fe, files);
        int scanIdx = 1;
        for (const auto& e : files) {
            if (scanIdx == prevLookIdx) {
                prevLookPath = e;
                break;
            }
            ++scanIdx;
        }
    }
    if (prevLookPath.empty() && prevLookIdx >= 1) {
        auto it = m_PresetMapping.find(prevLookIdx);
        if (it != m_PresetMapping.end())
            prevLookPath = it->second.first;
    }

    std::string prevFolderKey;
    if (!oldNone && m_LookPresetFolder && prevFolderIdx >= 0 && prevFolderIdx < static_cast<int>(oldFolderEntries.size()))
        prevFolderKey = folderKeyForEntry(oldFolderEntries[static_cast<size_t>(prevFolderIdx)]);

    std::vector<LSPOpenTexturePresetFolderEntry> newFolders;
    collectOpenTextureLookPresetFolderEntries(newFolders);

    if (newFolders.empty()) {
        m_FolderEntries.clear();
        m_FolderHasNoneOnly = true;
        if (m_LookPresetFolder) {
            m_SuppressLookPresetApply = true;
            m_LookPresetFolder->resetOptions();
            m_LookPresetFolder->appendOption("(none)");
            m_LookPresetFolder->setValue(0);
            m_SuppressLookPresetApply = false;
        }
        m_PresetMapping.clear();
        m_LookPreset->resetOptions();
        m_LookPreset->appendOption("---");
        m_SuppressLookPresetApply = true;
        m_LookPreset->setValue(0);
        m_SuppressLookPresetApply = false;
        return;
    }

    m_FolderHasNoneOnly = false;
    m_FolderEntries = newFolders;

    int targetFolderIdx = 0;
    int targetLookIdx = 0;
    bool resolved = false;

    if (forceSelectPath && !forceSelectPath->empty()) {
        if (findFolderAndLookIndicesForPath(newFolders, *forceSelectPath, targetFolderIdx, targetLookIdx))
            resolved = true;
    }
    if (!resolved && !prevLookPath.empty()) {
        if (!findFolderAndLookIndicesForPath(newFolders, prevLookPath, targetFolderIdx, targetLookIdx)) {
            targetFolderIdx = 0;
            targetLookIdx = 0;
        }
    } else if (!resolved) {
        for (int i = 0; i < static_cast<int>(newFolders.size()); ++i) {
            if (folderKeyForEntry(newFolders[static_cast<size_t>(i)]) == prevFolderKey) {
                targetFolderIdx = i;
                break;
            }
        }
        if (targetFolderIdx < 0 || targetFolderIdx >= static_cast<int>(newFolders.size()))
            targetFolderIdx = std::min(std::max(0, prevFolderIdx), static_cast<int>(newFolders.size()) - 1);
        targetLookIdx = 0;
    }

    if (m_LookPresetFolder) {
        m_SuppressLookPresetApply = true;
        m_LookPresetFolder->resetOptions();
        for (const auto& f : newFolders) {
            std::string label;
            if (formatOpenTextureLookPresetFolderMenuLabel(f, label))
                m_LookPresetFolder->appendOption(label.c_str());
        }
        m_LookPresetFolder->setValue(targetFolderIdx);
        m_SuppressLookPresetApply = false;
    }

    rebuildLookMenuForFolderIndex(targetFolderIdx);

    if (m_LookPreset) {
        const int maxLookIdx = static_cast<int>(m_PresetMapping.size());
        if (targetLookIdx > maxLookIdx)
            targetLookIdx = maxLookIdx;
        if (targetLookIdx < 0)
            targetLookIdx = 0;
        m_SuppressLookPresetApply = true;
        m_LookPreset->setValue(targetLookIdx);
        m_SuppressLookPresetApply = false;
    }
}

void LSPOpenTexturePlugin::collectPresetParams(double time, std::map<std::string, std::string>& out) {
    int iv = 0;
    if (m_OperationOrder) {
        m_OperationOrder->getValueAtTime(time, iv);
        out["halationOperationOrder"] = std::to_string(iv);
    }
    if (m_HalationEnable)
        out["halationEnable"] = m_HalationEnable->getValueAtTime(time) ? "true" : "false";
    double dv = 0.0;
    if (m_HalationGlobalBlend) {
        m_HalationGlobalBlend->getValueAtTime(time, dv);
        out["halationGlobalBlend"] = std::to_string(dv);
    }
    if (m_Intensity) {
        m_Intensity->getValueAtTime(time, dv);
        out["halationIntensity"] = std::to_string(dv);
    }
    if (m_Size) {
        m_Size->getValueAtTime(time, dv);
        out["halationSize"] = std::to_string(dv);
    }
    if (m_Color) {
        m_Color->getValueAtTime(time, dv);
        out["halationColor"] = std::to_string(dv);
    }
    if (m_Saturation) {
        m_Saturation->getValueAtTime(time, dv);
        out["halationSaturation"] = std::to_string(dv);
    }
    if (m_Distribution) {
        m_Distribution->getValueAtTime(time, dv);
        out["halationDistribution"] = std::to_string(dv);
    }
    if (m_MtfEnable)
        out["halationMtfEnable"] = m_MtfEnable->getValueAtTime(time) ? "true" : "false";
    if (m_MtfGlobalBlend) {
        m_MtfGlobalBlend->getValueAtTime(time, dv);
        out["halationMtfGlobalBlend"] = std::to_string(dv);
    }
    if (m_MtfGlobalStrength) {
        m_MtfGlobalStrength->getValueAtTime(time, dv);
        out["halationMtfGlobalStrength"] = std::to_string(dv);
    }
    if (m_MtfEQ1) {
        m_MtfEQ1->getValueAtTime(time, dv);
        out["halationMtfEQ1"] = std::to_string(dv);
    }
    if (m_MtfEQ2) {
        m_MtfEQ2->getValueAtTime(time, dv);
        out["halationMtfEQ2"] = std::to_string(dv);
    }
    if (m_MtfEQ3) {
        m_MtfEQ3->getValueAtTime(time, dv);
        out["halationMtfEQ3"] = std::to_string(dv);
    }
    if (m_MtfEQ4) {
        m_MtfEQ4->getValueAtTime(time, dv);
        out["halationMtfEQ4"] = std::to_string(dv);
    }
    if (m_MtfEQ5) {
        m_MtfEQ5->getValueAtTime(time, dv);
        out["halationMtfEQ5"] = std::to_string(dv);
    }
    if (m_MtfEQ6) {
        m_MtfEQ6->getValueAtTime(time, dv);
        out["halationMtfEQ6"] = std::to_string(dv);
    }
    if (m_MtfLumaBlend) {
        m_MtfLumaBlend->getValueAtTime(time, dv);
        out["halationMtfLumaBlend"] = std::to_string(dv);
    }
    if (m_GlareEnable)
        out["halationGlareEnable"] = m_GlareEnable->getValueAtTime(time) ? "true" : "false";
    if (m_GlareGlobalBlend) {
        m_GlareGlobalBlend->getValueAtTime(time, dv);
        out["halationGlareGlobalBlend"] = std::to_string(dv);
    }
    if (m_GlareSpread) {
        m_GlareSpread->getValueAtTime(time, dv);
        out["halationGlareSpread"] = std::to_string(dv);
    }
    if (m_GlareStrength) {
        m_GlareStrength->getValueAtTime(time, dv);
        out["halationGlareStrength"] = std::to_string(dv);
    }
    if (m_GlareExposure) {
        m_GlareExposure->getValueAtTime(time, dv);
        out["halationGlareExposure"] = std::to_string(dv);
    }
    if (m_GlareSaturation) {
        m_GlareSaturation->getValueAtTime(time, dv);
        out["halationGlareSaturation"] = std::to_string(dv);
    }
    if (m_GlareTemperature) {
        m_GlareTemperature->getValueAtTime(time, dv);
        out["halationGlareTemperature"] = std::to_string(dv);
    }
    if (m_GlareThreshold) {
        m_GlareThreshold->getValueAtTime(time, dv);
        out["halationGlareThreshold"] = std::to_string(dv);
    }
    if (m_GlareSmoothness) {
        m_GlareSmoothness->getValueAtTime(time, dv);
        out["halationGlareSmoothness"] = std::to_string(dv);
    }
    if (m_GlareClampHighlights)
        out["halationGlareClampHighlights"] = m_GlareClampHighlights->getValueAtTime(time) ? "true" : "false";
    if (m_GlareMaxHighlights) {
        m_GlareMaxHighlights->getValueAtTime(time, dv);
        out["halationGlareMaxHighlights"] = std::to_string(dv);
    }
}

void LSPOpenTexturePlugin::applyPresetFromParams(double time, const std::map<std::string, std::string>& params) {
    (void)time;
    std::map<std::string, std::string> filtered;
    for (const auto& p : params) {
        if (p.first == "__preset_plugin_version__")
            continue;
        int idOrIdx = -1;
        try {
            idOrIdx = std::stoi(p.first);
        } catch (...) {
        }
        std::string name;
        if (idOrIdx >= LSPOpenTextureParamSchema::kStableIdBase)
            name = LSPOpenTextureParamSchema::getParamNameFromStableId(idOrIdx);
        else
            name = p.first;
        if (!name.empty() && !LSPOpenTextureParamSchema::isPresetKeyNeverLoad(name))
            filtered[name] = p.second;
    }

    auto setD = [&](const char* name, OFX::DoubleParam* param) {
        if (!param || !filtered.count(name))
            return;
        try {
            param->setValue(std::stod(filtered.at(name)));
        } catch (...) {
        }
    };
    auto setB = [&](const char* name, OFX::BooleanParam* param) {
        if (!param || !filtered.count(name))
            return;
        const std::string& v = filtered.at(name);
        param->setValue(v == "true" || v == "1");
    };
    auto setC = [&](const char* name, OFX::ChoiceParam* param) {
        if (!param || !filtered.count(name))
            return;
        try {
            choiceParamSetFromPresetIndex(param, std::stoi(filtered.at(name)));
        } catch (...) {
        }
    };

    setC("halationOperationOrder", m_OperationOrder);
    setB("halationEnable", m_HalationEnable);
    setD("halationGlobalBlend", m_HalationGlobalBlend);
    setD("halationIntensity", m_Intensity);
    setD("halationSize", m_Size);
    setD("halationColor", m_Color);
    setD("halationSaturation", m_Saturation);
    setD("halationDistribution", m_Distribution);
    setB("halationMtfEnable", m_MtfEnable);
    setD("halationMtfGlobalBlend", m_MtfGlobalBlend);
    setD("halationMtfGlobalStrength", m_MtfGlobalStrength);
    setD("halationMtfEQ1", m_MtfEQ1);
    setD("halationMtfEQ2", m_MtfEQ2);
    setD("halationMtfEQ3", m_MtfEQ3);
    setD("halationMtfEQ4", m_MtfEQ4);
    setD("halationMtfEQ5", m_MtfEQ5);
    setD("halationMtfEQ6", m_MtfEQ6);
    setD("halationMtfLumaBlend", m_MtfLumaBlend);
    setB("halationGlareEnable", m_GlareEnable);
    setD("halationGlareGlobalBlend", m_GlareGlobalBlend);
    setD("halationGlareSpread", m_GlareSpread);
    setD("halationGlareStrength", m_GlareStrength);
    setD("halationGlareExposure", m_GlareExposure);
    setD("halationGlareSaturation", m_GlareSaturation);
    setD("halationGlareTemperature", m_GlareTemperature);
    setD("halationGlareThreshold", m_GlareThreshold);
    setD("halationGlareSmoothness", m_GlareSmoothness);
    setB("halationGlareClampHighlights", m_GlareClampHighlights);
    setD("halationGlareMaxHighlights", m_GlareMaxHighlights);

    syncHalationChildParamsEnabled();
    syncMtfChildParamsEnabled();
    syncGlareChildParamsEnabled();
}

void LSPOpenTexturePlugin::saveCurrentAsPreset(double time) {
#ifdef __APPLE__
    std::string userPresetsPath = getOpenTextureUserPresetsPath();
    if (userPresetsPath.empty())
        return;
    std::string presetPath = LSPOpenTextureShowSavePresetDialog(userPresetsPath.c_str());
    if (presetPath.empty())
        return;
    if (presetPath.size() < 4 || presetPath.compare(presetPath.size() - 4, 4, ".xml") != 0)
        presetPath += ".xml";
    std::map<std::string, std::string> paramsByName;
    collectPresetParams(time, paramsByName);
    std::map<std::string, std::string> paramsByStableId;
    for (const auto& p : paramsByName) {
        if (LSPOpenTextureParamSchema::isPresetKeyNeverLoad(p.first))
            continue;
        int sid = LSPOpenTextureParamSchema::getParamStableId(p.first);
        if (sid >= LSPOpenTextureParamSchema::kStableIdBase)
            paramsByStableId[std::to_string(sid)] = p.second;
    }
    if (!saveOpenTexturePresetToFile(presetPath, paramsByStableId))
        return;
    syncLookPresetMenuFromDisk(time, &presetPath);
#endif
}

void LSPOpenTexturePlugin::loadExternalPreset(double time) {
#ifdef __APPLE__
    std::string sourcePath = LSPOpenTextureShowOpenPresetDialog();
    if (sourcePath.empty())
        return;
    std::ifstream in(sourcePath);
    if (!in.is_open())
        return;
    std::stringstream buffer;
    buffer << in.rdbuf();
    in.close();
    std::map<std::string, std::string> importedParams;
    if (!loadOpenTexturePresetFromBuffer(buffer.str(), importedParams))
        return;
    size_t lastSlash = sourcePath.find_last_of("/\\");
    std::string filename = (lastSlash != std::string::npos) ? sourcePath.substr(lastSlash + 1) : sourcePath;
    size_t dotPos = filename.find_last_of(".");
    std::string presetName = (dotPos != std::string::npos) ? filename.substr(0, dotPos) : filename;
    for (char& c : presetName) {
        if (c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|')
            c = '_';
    }
    if (presetName.empty())
        presetName = "preset";
    std::string userDir = getOpenTextureUserPresetsPath();
    if (userDir.empty())
        return;
    const std::string destPath = (std::filesystem::path(userDir) / (presetName + ".xml")).string();
    std::ifstream existsCheck(destPath);
    if (existsCheck.good()) {
        existsCheck.close();
        LSPOpenTextureShowPresetAlreadyExistsAlert(presetName.c_str());
        return;
    }
    if (!saveOpenTexturePresetToFile(destPath, importedParams))
        return;
    syncLookPresetMenuFromDisk(time, &destPath);
    m_ApplyingPreset = true;
    applyPresetFromParams(time, importedParams);
    m_ApplyingPreset = false;
#endif
}

void LSPOpenTexturePlugin::bumpLookPresetToCustomIfNeeded(const OFX::InstanceChangedArgs& args, const std::string& paramName) {
    if (!m_LookPreset || m_ApplyingPreset)
        return;
    if (paramLeafIs(paramName, "halationLookPreset") || paramLeafIs(paramName, "halationLookPresetFolder") ||
        paramLeafIs(paramName, "halationExportPreset") || paramLeafIs(paramName, "halationImportPreset") ||
        paramLeafIs(paramName, "halationOpenPresetFolder") || paramLeafIs(paramName, "halationRefreshPresets"))
        return;
    if (!LSPOpenTextureParamSchema::isPresetRelevantParam(paramLeafName(paramName)) &&
        !paramLeafIs(paramName, "halationResetHalation") && !paramLeafIs(paramName, "halationResetMtf") &&
        !paramLeafIs(paramName, "halationResetEffectWindow"))
        return;
    int idx = 0;
    m_LookPreset->getValueAtTime(args.time, idx);
    if (idx <= 0)
        return;
    m_SuppressLookPresetApply = true;
    m_LookPreset->setValue(0);
    m_SuppressLookPresetApply = false;
}

bool LSPOpenTexturePlugin::handlePresetChangedParam(const OFX::InstanceChangedArgs& args, const std::string& paramName) {
    if (paramLeafIs(paramName, "halationLookPresetFolder")) {
        if (m_SuppressLookPresetApply)
            return true;
        m_SuppressLookPresetApply = true;
        rebuildLookMenuForCurrentFolder(args.time);
        if (m_LookPreset)
            m_LookPreset->setValue(0);
        m_SuppressLookPresetApply = false;
        return true;
    }
    if (paramLeafIs(paramName, "halationLookPreset")) {
        if (m_SuppressLookPresetApply || m_ApplyingPreset)
            return true;
        int idx = 0;
        m_LookPreset->getValueAtTime(args.time, idx);
        if (idx >= 1) {
            if (args.reason != OFX::eChangeUserEdit)
                return true;
            auto it = m_PresetMapping.find(idx);
            if (it != m_PresetMapping.end()) {
                std::map<std::string, std::string> params;
                if (loadOpenTexturePresetFromFileHelper(it->second.first, params)) {
                    m_ApplyingPreset = true;
                    applyPresetFromParams(args.time, params);
                    m_ApplyingPreset = false;
                }
            }
        }
        return true;
    }
    if (paramLeafIs(paramName, "halationExportPreset")) {
        saveCurrentAsPreset(args.time);
        return true;
    }
    if (paramLeafIs(paramName, "halationImportPreset")) {
        loadExternalPreset(args.time);
        return true;
    }
    if (paramLeafIs(paramName, "halationOpenPresetFolder")) {
#ifdef __APPLE__
        std::string userDir = getOpenTextureUserPresetsPath();
        if (!userDir.empty()) {
            const std::string cmd = std::string("open \"") + userDir + "\"";
            if (std::system(cmd.c_str()) != 0)
                LSP_OPEN_TEXTURE_LOG_ERROR("open_preset_folder_failed");
        }
#endif
        return true;
    }
    if (paramLeafIs(paramName, "halationRefreshPresets")) {
        syncLookPresetMenuFromDisk(args.time, nullptr);
        return true;
    }
    return false;
}
