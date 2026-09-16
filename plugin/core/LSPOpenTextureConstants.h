#ifndef LSP_OPEN_TEXTURE_CONSTANTS_H
#define LSP_OPEN_TEXTURE_CONSTANTS_H

#include "version_gen.h"

#define kPluginName "LSP - Open Texture " PLUGIN_VERSION_STR
#define kPluginGrouping "LSP - Color"
#define kPluginDescription "LSP - Open Texture — Thatcher Freeman exposure-lost halation with Matrix red-shift (OFX Metal)."
#define kPluginIdentifier PLUGIN_OFX_IDENTIFIER
#define kPluginVersionMajor PLUGIN_VERSION_MAJOR
#define kPluginVersionMinor PLUGIN_VERSION_MINOR
#define kSupportsTiles false
#define kSupportsMultiResolution false
#define kSupportsMultipleClipPARs false

#define kOpenTextureRepoUrl "https://github.com/Lo1s-pgn/Open-Texture-OFX"
#define kOpenTextureIssuesUrl "https://github.com/Lo1s-pgn/Open-Texture-OFX/issues"

// UHD frame diag in px; halation footprint stays same on proxy / diffrent res
#define kOpenTextureReferenceDiagonalPixels (4405.814453125f)

#define kOpenTextureMtfBaseFreqFixed (2.0f)

#define kOpenTextureMtfBaseFreqUnderHoodScale (2.0f)

#endif
