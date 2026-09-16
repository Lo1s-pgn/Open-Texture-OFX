#include "LSPOpenTexturePresetHelpers.h"
#include "version_gen.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <mutex>
#include <sstream>
#include <string_view>
#ifndef _WIN32
#include <dirent.h>
#endif
#include <sys/stat.h>
#ifdef __APPLE__
#include <dlfcn.h>
#include <limits.h>
#endif

namespace {

#ifdef __APPLE__
static void lspOpenTexturePresetHelpersBundleAnchor() {}

static std::string tryPluginImageResourcesPath() {
    Dl_info info{};
    if (dladdr(reinterpret_cast<void*>(&lspOpenTexturePresetHelpersBundleAnchor), &info) == 0 || !info.dli_fname)
        return "";
    std::string p = info.dli_fname;
    char resolved[PATH_MAX];
    if (realpath(p.c_str(), resolved))
        p = resolved;
    const char* marker = ".ofx.bundle";
    size_t pos = p.find(marker);
    if (pos == std::string::npos)
        return "";
    std::string bundleRoot = p.substr(0, pos + std::strlen(marker));
    std::string res = bundleRoot + "/Contents/Resources";
    struct stat st{};
    if (stat(res.c_str(), &st) == 0 && S_ISDIR(st.st_mode))
        return res;
    return "";
}
#endif

static std::mutex g_ofxBundleRootMutex;
static std::string g_ofxPluginBundleRoot;

std::string presetBasenameOnly(const std::string& path) {
    size_t lastSlash = path.find_last_of("/\\");
    std::string filename = (lastSlash != std::string::npos) ? path.substr(lastSlash + 1) : path;
    size_t dotPos = filename.find_last_of(".");
    if (dotPos != std::string::npos && dotPos > 0)
        return filename.substr(0, dotPos);
    return filename;
}

bool endsWithExtension(const std::string& filename, const char* ext) {
    size_t n = filename.size();
    size_t el = std::strlen(ext);
    if (n < el)
        return false;
    return filename.compare(n - el, el, ext) == 0;
}

static void xmlEscapeAttr(std::ostream& os, const std::string& s) {
    for (unsigned char c : s) {
        switch (c) {
            case '&':
                os << "&amp;";
                break;
            case '"':
                os << "&quot;";
                break;
            case '<':
                os << "&lt;";
                break;
            case '>':
                os << "&gt;";
                break;
            default:
                os << static_cast<char>(c);
                break;
        }
    }
}

static std::string xmlUnescapeAttr(std::string_view s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size();) {
        if (s[i] == '&') {
            if (s.size() - i >= 5 && s.substr(i, 5) == "&amp;") {
                out += '&';
                i += 5;
                continue;
            }
            if (s.size() - i >= 4 && s.substr(i, 4) == "&lt;") {
                out += '<';
                i += 4;
                continue;
            }
            if (s.size() - i >= 4 && s.substr(i, 4) == "&gt;") {
                out += '>';
                i += 4;
                continue;
            }
            if (s.size() - i >= 6 && s.substr(i, 6) == "&quot;") {
                out += '"';
                i += 6;
                continue;
            }
        }
        out += s[i++];
    }
    return out;
}

static std::string readTagAttr(std::string_view tag, const char* attrName) {
    const std::string pref = std::string(attrName) + "=\"";
    size_t p = tag.find(pref);
    if (p == std::string::npos)
        return "";
    p += pref.size();
    size_t end = p;
    while (end < tag.size() && tag[end] != '"')
        ++end;
    return xmlUnescapeAttr(tag.substr(p, end - p));
}

static bool loadPresetParamsFromJsonText(const std::string& json, std::map<std::string, std::string>& params) {
    size_t paramsStart = json.find("\"parameters\"");
    if (paramsStart == std::string::npos)
        return false;
    paramsStart = json.find("{", paramsStart);
    if (paramsStart == std::string::npos)
        return false;
    size_t paramsEnd = json.find_last_of("}");
    if (paramsEnd == std::string::npos || paramsEnd <= paramsStart)
        return false;
    std::string paramsJson = json.substr(paramsStart, paramsEnd - paramsStart + 1);
    size_t pos = 0;
    while ((pos = paramsJson.find("\"", pos)) != std::string::npos) {
        size_t keyStart = pos + 1;
        size_t keyEnd = paramsJson.find("\"", keyStart);
        if (keyEnd == std::string::npos)
            break;
        std::string key = paramsJson.substr(keyStart, keyEnd - keyStart);
        pos = paramsJson.find(":", keyEnd);
        if (pos == std::string::npos)
            break;
        pos++;
        while (pos < paramsJson.length() && (paramsJson[pos] == ' ' || paramsJson[pos] == '\t'))
            pos++;
        size_t valueStart = pos;
        size_t valueEnd = valueStart;
        if (paramsJson[valueStart] == '"') {
            valueStart++;
            valueEnd = paramsJson.find("\"", valueStart);
            if (valueEnd == std::string::npos)
                break;
        } else {
            while (valueEnd < paramsJson.length() && paramsJson[valueEnd] != ',' && paramsJson[valueEnd] != '}' &&
                   paramsJson[valueEnd] != '\n' && paramsJson[valueEnd] != ' ')
                valueEnd++;
        }
        params[key] = paramsJson.substr(valueStart, valueEnd - valueStart);
        pos = valueEnd + 1;
    }
    return true;
}

static bool loadPresetParamsFromXmlText(const std::string& content, std::map<std::string, std::string>& params) {
    size_t lp = content.find("<lspPreset");
    if (lp != std::string::npos) {
        size_t gt = content.find('>', lp);
        if (gt != std::string::npos) {
            std::string_view openTag(content.data() + lp, gt - lp + 1);
            std::string pv = readTagAttr(openTag, "pluginVersion");
            if (!pv.empty())
                params["__preset_plugin_version__"] = pv;
        }
    }
    size_t start = content.find("<parameters>");
    size_t end = content.find("</parameters>");
    if (start == std::string::npos || end == std::string::npos || end <= start)
        return false;
    size_t pos = start;
    while (pos < end) {
        pos = content.find("<e", pos);
        if (pos == std::string::npos || pos >= end)
            break;
        size_t close = content.find("/>", pos);
        if (close == std::string::npos || close > end)
            break;
        std::string_view tag(content.data() + pos, close + 2 - pos);
        std::string k = readTagAttr(tag, "k");
        std::string v = readTagAttr(tag, "v");
        if (!k.empty())
            params[k] = v;
        pos = close + 2;
    }
    return true;
}

static void stripUtf8Bom(std::string& s) {
    if (s.size() >= 3 && static_cast<unsigned char>(s[0]) == 0xEF && static_cast<unsigned char>(s[1]) == 0xBB &&
        static_cast<unsigned char>(s[2]) == 0xBF)
        s.erase(0, 3);
}

static std::vector<std::string> listUserSubfolderNamesWithPresets(const std::string& userPresetsRoot) {
    std::vector<std::string> names;
    if (userPresetsRoot.empty())
        return names;
    namespace fs = std::filesystem;
    std::error_code ec;
    fs::path root(userPresetsRoot);
    if (!fs::is_directory(root, ec))
        return names;
    for (const auto& entry : fs::directory_iterator(root, ec)) {
        if (ec)
            break;
        if (!entry.is_directory(ec))
            continue;
        std::string fn = entry.path().filename().string();
        if (fn == "." || fn == "..")
            continue;
        if (scanOpenTexturePresetDirectory(entry.path().string()).empty())
            continue;
        names.push_back(std::move(fn));
    }
    std::sort(names.begin(), names.end());
    return names;
}

}

void LSPOpenTextureSetOFXPluginBundleRoot(const std::string& bundleRootFromHost) {
    if (bundleRootFromHost.empty())
        return;
    std::string root = bundleRootFromHost;
    while (!root.empty() && (root.back() == '/' || root.back() == '\\'))
        root.pop_back();
    if (root.empty())
        return;
    std::lock_guard<std::mutex> lock(g_ofxBundleRootMutex);
    g_ofxPluginBundleRoot = std::move(root);
}

std::string getOpenTextureBundleResourcesPath() {
    {
        std::lock_guard<std::mutex> lock(g_ofxBundleRootMutex);
        if (!g_ofxPluginBundleRoot.empty()) {
            std::string res = g_ofxPluginBundleRoot + "/Contents/Resources";
            std::error_code ec;
            if (std::filesystem::is_directory(res, ec))
                return res;
        }
    }
#ifdef __APPLE__
    std::string fromImage = tryPluginImageResourcesPath();
    if (!fromImage.empty())
        return fromImage;
#endif
    return "";
}

std::string getOpenTextureUserPresetsPath() {
#if defined(_WIN32)
    const char* appData = getenv("APPDATA");
    if (!appData || appData[0] == '\0')
        return {};
    std::string appFolder = std::string(appData) + "\\LSP\\OpenTexture";
    std::string presetsDir = appFolder + "\\Presets";
    std::error_code ec;
    std::filesystem::create_directories(presetsDir, ec);
    return presetsDir;
#elif defined(__APPLE__)
    const char* home = getenv("HOME");
    if (home) {
        std::string homeStr(home);
        std::string appFolder = homeStr + "/Library/Application Support/LSP/OpenTexture";
        std::string presetsDir = appFolder + "/Presets";
        struct stat st;
        if (stat(presetsDir.c_str(), &st) != 0) {
            mkdir((homeStr + "/Library/Application Support/LSP").c_str(), 0755);
            mkdir(appFolder.c_str(), 0755);
            mkdir(presetsDir.c_str(), 0755);
        }
        return presetsDir;
    }
#endif
    return "";
}

std::vector<std::string> scanOpenTexturePresetDirectory(const std::string& dirPath) {
    std::map<std::string, std::string> byBaseName;
    if (dirPath.empty())
        return {};
#ifdef _WIN32
    namespace fs = std::filesystem;
    std::error_code ec;
    if (!fs::is_directory(dirPath, ec))
        return {};
    for (const auto& entry : fs::directory_iterator(dirPath, ec)) {
        if (ec)
            break;
        if (!entry.is_regular_file(ec))
            continue;
        std::string filename = entry.path().filename().string();
        if (endsWithExtension(filename, ".xml")) {
            std::string full = entry.path().string();
            byBaseName[presetBasenameOnly(full)] = full;
        } else if (endsWithExtension(filename, ".json")) {
            std::string base = presetBasenameOnly(filename);
            if (byBaseName.find(base) == byBaseName.end())
                byBaseName[base] = entry.path().string();
        }
    }
#else
    DIR* d = opendir(dirPath.c_str());
    if (!d)
        return {};
    struct dirent* entry;
    while ((entry = readdir(d)) != nullptr) {
        std::string filename(entry->d_name);
        if (endsWithExtension(filename, ".xml")) {
            std::string full = dirPath + "/" + filename;
            byBaseName[presetBasenameOnly(full)] = full;
        } else if (endsWithExtension(filename, ".json")) {
            std::string base = presetBasenameOnly(filename);
            if (byBaseName.find(base) == byBaseName.end())
                byBaseName[base] = dirPath + "/" + filename;
        }
    }
    closedir(d);
#endif
    std::vector<std::string> presets;
    presets.reserve(byBaseName.size());
    for (const auto& p : byBaseName)
        presets.push_back(p.second);
    return presets;
}

std::string getOpenTexturePresetBasenameForLookMenu(const std::string& presetPath) {
    return presetBasenameOnly(presetPath);
}

void orderOpenTexturePresetPathsForLookMenu(const LSPOpenTexturePresetFolderEntry& folder, std::vector<std::string>& paths) {
    (void)folder;
    std::sort(paths.begin(), paths.end(), [](const std::string& a, const std::string& b) {
        return getOpenTexturePresetBasenameForLookMenu(a) < getOpenTexturePresetBasenameForLookMenu(b);
    });
}

bool formatOpenTextureLookPresetFolderMenuLabel(const LSPOpenTexturePresetFolderEntry& e, std::string& outLabel) {
    switch (e.kind) {
        case kLSPOpenTexturePresetFolderBundle:
            outLabel = "LSP";
            return true;
        case kLSPOpenTexturePresetFolderUserRoot:
            outLabel = "User";
            return true;
        case kLSPOpenTexturePresetFolderUserSub:
            outLabel = e.userSubfolderName;
            return true;
        default:
            return false;
    }
}

std::string resolveOpenTextureLookPresetFolderDirectory(const LSPOpenTexturePresetFolderEntry& e) {
    switch (e.kind) {
        case kLSPOpenTexturePresetFolderBundle:
            return getOpenTextureBundleResourcesPath() + "/Presets";
        case kLSPOpenTexturePresetFolderUserRoot:
            return getOpenTextureUserPresetsPath();
        case kLSPOpenTexturePresetFolderUserSub: {
            std::string ur = getOpenTextureUserPresetsPath();
            if (ur.empty())
                return "";
            std::filesystem::path p(ur);
            p /= e.userSubfolderName;
            return p.string();
        }
        default:
            return "";
    }
}

void collectOpenTextureLookPresetFolderEntries(std::vector<LSPOpenTexturePresetFolderEntry>& out) {
    out.clear();
    std::string bundlePresetsPath = getOpenTextureBundleResourcesPath() + "/Presets";
    if (!scanOpenTexturePresetDirectory(bundlePresetsPath).empty()) {
        LSPOpenTexturePresetFolderEntry e{};
        e.kind = kLSPOpenTexturePresetFolderBundle;
        out.push_back(e);
    }
    std::string userRoot = getOpenTextureUserPresetsPath();
    if (!userRoot.empty() && !scanOpenTexturePresetDirectory(userRoot).empty()) {
        LSPOpenTexturePresetFolderEntry e{};
        e.kind = kLSPOpenTexturePresetFolderUserRoot;
        out.push_back(e);
    }
    for (const std::string& sub : listUserSubfolderNamesWithPresets(userRoot)) {
        LSPOpenTexturePresetFolderEntry e{};
        e.kind = kLSPOpenTexturePresetFolderUserSub;
        e.userSubfolderName = sub;
        out.push_back(e);
    }
}

bool loadOpenTexturePresetFromBuffer(const std::string& body, std::map<std::string, std::string>& params) {
    params.clear();
    std::string t = body;
    stripUtf8Bom(t);
    while (!t.empty() && (t[0] == ' ' || t[0] == '\t' || t[0] == '\n' || t[0] == '\r'))
        t.erase(0, 1);
    if (t.size() >= 5 && t.compare(0, 5, "<?xml") == 0)
        return loadPresetParamsFromXmlText(t, params);
    if (t.find("<lspPreset") != std::string::npos)
        return loadPresetParamsFromXmlText(t, params);
    return loadPresetParamsFromJsonText(t, params);
}

bool saveOpenTexturePresetToFile(const std::string& filepath, const std::map<std::string, std::string>& params) {
    std::ofstream file(filepath);
    if (!file.is_open())
        return false;
    file << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
    file << "<lspPreset version=\"3.0\" pluginVersion=\"";
    xmlEscapeAttr(file, PLUGIN_VERSION_STR);
    file << "\">\n";
    file << "<parameters>\n";
    for (const auto& pair : params) {
        file << "<e k=\"";
        xmlEscapeAttr(file, pair.first);
        file << "\" v=\"";
        xmlEscapeAttr(file, pair.second);
        file << "\"/>\n";
    }
    file << "</parameters>\n</lspPreset>\n";
    return true;
}

bool loadOpenTexturePresetFromFileHelper(const std::string& filepath, std::map<std::string, std::string>& params) {
    std::ifstream file(filepath);
    if (!file.is_open())
        return false;
    std::stringstream buffer;
    buffer << file.rdbuf();
    return loadOpenTexturePresetFromBuffer(buffer.str(), params);
}
