#ifndef LSP_OPEN_TEXTURE_PRESET_HELPERS_H
#define LSP_OPEN_TEXTURE_PRESET_HELPERS_H

#include <map>
#include <string>
#include <vector>

enum LSPOpenTexturePresetFolderKind {
    kLSPOpenTexturePresetFolderBundle = 0,
    kLSPOpenTexturePresetFolderUserRoot,
    kLSPOpenTexturePresetFolderUserSub
};

struct LSPOpenTexturePresetFolderEntry {
    LSPOpenTexturePresetFolderKind kind;
    std::string userSubfolderName;
};

std::string getOpenTextureBundleResourcesPath();
void LSPOpenTextureSetOFXPluginBundleRoot(const std::string& bundleRootFromHost);
std::string getOpenTextureUserPresetsPath();
std::vector<std::string> scanOpenTexturePresetDirectory(const std::string& dirPath);
std::string getOpenTexturePresetBasenameForLookMenu(const std::string& presetPath);
bool formatOpenTextureLookPresetFolderMenuLabel(const LSPOpenTexturePresetFolderEntry& e, std::string& outLabel);
std::string resolveOpenTextureLookPresetFolderDirectory(const LSPOpenTexturePresetFolderEntry& e);
void collectOpenTextureLookPresetFolderEntries(std::vector<LSPOpenTexturePresetFolderEntry>& out);
void orderOpenTexturePresetPathsForLookMenu(const LSPOpenTexturePresetFolderEntry& folder, std::vector<std::string>& paths);
bool saveOpenTexturePresetToFile(const std::string& filepath, const std::map<std::string, std::string>& params);
bool loadOpenTexturePresetFromFileHelper(const std::string& filepath, std::map<std::string, std::string>& params);
bool loadOpenTexturePresetFromBuffer(const std::string& body, std::map<std::string, std::string>& params);

#endif
