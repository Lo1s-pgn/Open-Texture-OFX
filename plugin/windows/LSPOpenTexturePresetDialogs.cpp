#include "../presets/LSPOpenTexturePresetDialogs.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
#include <shobjidl.h>
#include <objbase.h>
#include <string>

static std::string otWideToUtf8(const wchar_t* wide) {
    if (!wide || !*wide)
        return {};
    int needed = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
    if (needed <= 1)
        return {};
    std::string out(static_cast<size_t>(needed - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), needed, nullptr, nullptr);
    return out;
}

static std::wstring otUtf8ToWide(const char* utf8) {
    if (!utf8 || !*utf8)
        return {};
    int needed = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    if (needed <= 1)
        return {};
    std::wstring out(static_cast<size_t>(needed - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out.data(), needed);
    return out;
}

struct OtComApartmentScope {
    bool uninit = false;
    OtComApartmentScope() {
        const HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        if (hr == S_OK)
            uninit = true;
    }
    ~OtComApartmentScope() {
        if (uninit)
            CoUninitialize();
    }
};

std::string LSPOpenTextureShowSavePresetDialog(const char* defaultDir) {
    OtComApartmentScope com;
    std::string result;

    IFileSaveDialog* dialog = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_ALL, IID_IFileSaveDialog,
                                  reinterpret_cast<void**>(&dialog));
    if (FAILED(hr) || !dialog)
        return result;

    COMDLG_FILTERSPEC filter[] = {{L"XML preset", L"*.xml"}};
    dialog->SetFileTypes(1, filter);
    dialog->SetTitle(L"Export Open Texture Preset");
    dialog->SetDefaultExtension(L"xml");

    if (defaultDir && defaultDir[0] != '\0') {
        std::wstring wdir = otUtf8ToWide(defaultDir);
        if (!wdir.empty()) {
            IShellItem* item = nullptr;
            if (SUCCEEDED(SHCreateItemFromParsingName(wdir.c_str(), nullptr, IID_IShellItem,
                                                      reinterpret_cast<void**>(&item)))
                && item) {
                dialog->SetFolder(item);
                item->Release();
            }
        }
    }

    if (SUCCEEDED(dialog->Show(nullptr))) {
        IShellItem* item = nullptr;
        if (SUCCEEDED(dialog->GetResult(&item)) && item) {
            PWSTR path = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
                result = otWideToUtf8(path);
                CoTaskMemFree(path);
            }
            item->Release();
        }
    }
    dialog->Release();
    return result;
}

std::string LSPOpenTextureShowOpenPresetDialog() {
    OtComApartmentScope com;
    std::string result;

    IFileOpenDialog* dialog = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_ALL, IID_IFileOpenDialog,
                                  reinterpret_cast<void**>(&dialog));
    if (FAILED(hr) || !dialog)
        return result;

    COMDLG_FILTERSPEC filter[] = {{L"Preset files", L"*.xml;*.json"}};
    dialog->SetFileTypes(1, filter);
    dialog->SetTitle(L"Import Open Texture Preset");

    if (SUCCEEDED(dialog->Show(nullptr))) {
        IShellItem* item = nullptr;
        if (SUCCEEDED(dialog->GetResult(&item)) && item) {
            PWSTR path = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
                result = otWideToUtf8(path);
                CoTaskMemFree(path);
            }
            item->Release();
        }
    }
    dialog->Release();
    return result;
}

void LSPOpenTextureShowPresetAlreadyExistsAlert(const char* presetName) {
    std::wstring msg = L"A preset named \"";
    if (presetName && presetName[0] != '\0')
        msg += otUtf8ToWide(presetName);
    msg += L"\" already exists in the user presets folder.";
    MessageBoxW(nullptr, msg.c_str(), L"Preset already exists", MB_OK | MB_ICONWARNING);
}
