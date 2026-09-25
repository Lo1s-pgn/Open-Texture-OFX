# LSP - Open Texture (OFX)

Open Texture is an OFX plug-in for DaVinci Resolve. Add realtime halation, MTF curve, and highlight Diffusion in one node, with factory presets and an optional effect window.

## What it does

- **Halation** — Exposure-lost bleed with fast blur, mostly code from [Thatcher Freeman](https://github.com/thatcherfreeman).
- **MTF curve** — Six-band frequency EQ on LAB, from [Paul Dore](https://github.com/baldavenger)'s FreqEQ plugin.
- **Diffusion** — Bloom on highlights, based on Blender's glare effect.
- **Presets** — 2 default looks ship in the bundle; save and load user XML.
- **Effect window** — Optional aspect crop when working with black letterbox.

## Platform


| OS              | Notes                                      |
| --------------- | ------------------------------------------ |
| **macOS** 11.0+ | Universal arm64 + x86_64 by default, Metal |
| **Windows**     | 64-bit (DaVinci Resolve), CUDA             |


Build on each platform separately. Each build writes a versioned release folder:


| Platform | Release folder                                |
| -------- | --------------------------------------------- |
| macOS    | `release/LSP_Open_Texture_<version>_macos/`   |
| Windows  | `release/LSP_Open_Texture_<version>_windows/` |


## Build

**CMake** is the only build system. See [tools/README.md](tools/README.md) for helper scripts.

### Prerequisites

- **CMake** 3.22+
- **macOS:** Xcode Command Line Tools
- **Windows:** Visual Studio 2022 (MSVC), **Ninja**, **CUDA Toolkit**



### macOS

```bash
cmake -S . -B build/macos -DCMAKE_BUILD_TYPE=Release
cmake --build build/macos --target opentexture_all --parallel
```

Configure options: `-DOPENTEXTURE_OFX_FAT_ARCHS=OFF` (single-arch), `-DOFX_SDK_PATH=...`

### Windows

```powershell
cmake -S . -B build/windows -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl
cmake --build build/windows --target opentexture_all --parallel
```

## Installation

Copy the bundle from your platform’s release folder into the host OFX plug-ins directory, then restart DaVinci Resolve.


| Platform          | OFX folder                                   |
| ----------------- | -------------------------------------------- |
| macOS (all users) | `/Library/OFX/Plugins/`                      |
| Windows           | `C:\Program Files\Common Files\OFX\Plugins\` |


**Resolve OFX cache** (delete if the plug-in does not appear after upgrade):

- macOS: `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/OFXPluginCacheV2.xml`
- Windows: `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\OFXPluginCacheV2.xml`

## Log file


| Platform | Path                                                |
| -------- | --------------------------------------------------- |
| macOS    | `~/Library/Application Support/LSP/OpenTexture.log` |
| Windows  | `%LOCALAPPDATA%\LSP\OpenTexture.log`                |


Use **Open Log** in the plug-in SUPPORT section.

## macOS Gatekeeper (unsigned release)

```bash
BUNDLE="/Library/OFX/Plugins/LSP_Open_Texture_<version>.ofx.bundle"

sudo chmod -R 755 "$BUNDLE"
sudo chown -R root:wheel "$BUNDLE"   # skip for ~/Library/OFX/Plugins/
sudo xattr -dr com.apple.quarantine "$BUNDLE"
sudo codesign --force --deep --sign - "$BUNDLE"
```

Quit and relaunch Resolve.

## SDK

Vendored minimal OpenFX SDK in `openfx-sdk/`. Override with `-DOFX_SDK_PATH=...` if needed.

## License

This project is licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE).
