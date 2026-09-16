#pragma once

#include <string>

std::string LSPOpenTextureShowSavePresetDialog(const char* defaultDir);
std::string LSPOpenTextureShowOpenPresetDialog();
void LSPOpenTextureShowPresetAlreadyExistsAlert(const char* presetName);
