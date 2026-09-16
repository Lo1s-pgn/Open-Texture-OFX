# Plugin sources — LSP - Open Texture

Metal-first OFX filter (macOS): halation bloom + optional six-band MTF curve + DIFFUSION bloom. Windows uses CUDA (`plugin/cuda/`) with Van Vliet IIR blur (MPS-equivalent σ ladder via pyramid dispatch).

## Source map

### `core/`

| File | Purpose |
|------|---------|
| `LSPOpenTextureDescribe.cpp` | All OFX parameter + page descriptors |
| `LSPOpenTexturePlugin.cpp` | `render`, `isIdentity`, `changedParam`, preset hooks |
| `LSPOpenTextureProcessor.cpp` | `ImageProcessor`: macOS `processImagesMetal`, Windows `processImagesCuda`, or CPU halation fallback |
| `LSPOpenTextureMtfIdentity.h` | MTF identity check + **UI→effective EQ** (`openTextureMtfBuildEffectiveEq`) |
| `LSPOpenTextureMtfPyramid.h` | MTF half-res pyramid blur plan (σ ladder) |
| `LSPOpenTextureGlareMapping.h` | Min/Max Highlights log-nits maps, spread/threshold UI, bloom chain plan |
| `LSPOpenTextureGlareIdentity.h` | Glare identity bypass |
| `LSPOpenTextureParamSchema.h` | Stable numeric preset IDs (≥2000) |
| `LSPOpenTextureProfile.h` | Optional stage timers (`OPEN_TEXTURE_PROFILE=1`) |
| `LSPOpenTextureTextureFormats.h` | FP32 intermediate buffer size helpers |
| `LSPOpenTextureConstants.h` | Plugin id, URLs, reference diagonal, MTF base-freq scale |
| `LSPOpenTextureEffectWindow.h` | Aspect window geometry (cover-fit, edge replicate, black mask) |
| `LSPOpenTextureGamut.*` / `LSPOpenTextureTfMapping.*` | Input gamut/transfer ↔ DWG working space |
| `LSPOpenTexturePresetMenus.cpp` | Preset save/load/refresh UI |

### `metal/`

| File | Purpose |
|------|---------|
| `LSPOpenTextureMetal.mm` | `renderHost`: halation MPS blur, MTF post, effect-window finish |
| `LSPOpenTextureMetal.metal` | Preprocess, composite, region copy, global blend, window kernels |
| `LSPOpenTextureFreqEQBridge.mm` | Presplit octave bands, MPS blur cache, texture-native FreqEQ encode |
| `LSPOpenTextureFreqEQ.metal` | Paul Dore Lab L\* (working RGB as Rec.709), fused presplit / preview |
| `LSPOpenTextureGlareBridge.mm` | Bloom glare bridge: MPS pyramid blur, tent upscale, mix |
| `LSPOpenTextureGlare.metal` | Glare decode, highlights, bloom down/up, exposure shift, mix+encode |
| `LSPOpenTextureGlareParams.h` | Host param build (`openTextureGlareBuildHostParams`) |

Bundled as `LSPOpenTextureMetal.metallib` in the macOS `.ofx.bundle` Resources folder.

### `cuda/` (Windows)

| File | Purpose |
|------|---------|
| `LSPOpenTextureCuda.cpp` | `renderHost`: halation blur, MTF post, glare, effect-window finish |
| `LSPOpenTextureFreqEQCuda.cpp` | Presplit octave bands, L\* blur cache, FreqEQ encode |
| `LSPOpenTextureGlareCuda.cpp` | DIFFUSION bloom bridge (pyramid blur, mix) |
| `LSPOpenTextureGlareKernels.cu` | Glare highlights, mix, upscale kernels |
| `LSPOpenTextureVanVliet.cu` | Van Vliet IIR blur kernels (RGBA + scalar) |
| `LSPOpenTextureCudaBlur.cu` | σ ladder + pyramid dispatch (Van Vliet blur) |
| `LSPOpenTextureKernels.cu` / `LSPOpenTextureFreqEQKernels.cu` | Device kernels ported from Metal |

### `presets/`

User XML (`lspPreset` v3.0): macOS `~/Library/Application Support/LSP/OpenTexture/Presets/`; Windows `%APPDATA%\LSP\OpenTexture\Presets\`.

**Factory looks** in repo `Presets/` (`Digital.xml`, `Film.xml`) copy into the bundle at build (`Contents/Resources/Presets/`).

**Saved in presets (look only):** pipeline operation order, halation, MTF curve (incl. luma blend), DIFFUSION bloom/highlights.

**Not saved:** input gamut, transfer function, effect window, overlay display modes (Show Distribution, MTF band, Diffusion display), nits readouts, preset UI controls.

## Controls page structure

```
PRESET
INPUT          (gamut, transfer)
PIPELINE       (operation order)
EFFECT WINDOW  (enable, aspect preset, aspect, vertical, show border)
HALATION       (enable, reset, global blend, intensity, spread, hue, saturation, distribution)
  └─ ⭕ Overlay → Show Distribution
MTF CURVE      (enable, reset, global blend, global strength, EQ 1–6, luma blend)
  └─ ⭕ Overlay → Display band
DIFFUSION      (enable, reset, global blend)
  ├─ Bloom      → Spread, Strength, Exposure shift, Saturation, Temperature
  ├─ Highlights → Min Highlights, Min Nits, Smoothness, Limit Highlights, Max Highlights, Max Nits
  └─ ⭕ Overlay  → Display (Render / Source / Diffusion)
SUPPORT
```

## MTF CURVE parameters

| Control | Range | Default | Notes |
|---------|-------|---------|-------|
| Global blend | 0–1 | 1 | Mix MTF output vs image before MTF |
| Global strength | 0–2 | 1 | Scales band **delta from neutral** (see below) |
| EQ band 1–6 | −1–1 | 0 | UI gain before remap |
| Luma blend | 0–1 | 0 | 0 = keep chroma, scale Rec.709-Y to the EQd L\*. 1 = exact Paul Dore Lab (a\*/b\* unchanged). Working RGB is treated as Rec.709 — no gamut convert. |
| Display band | choice | None | Solo band for inspection; not preset-saved |

**Remap + strength** (`LSPOpenTextureMtfIdentity.h`):

```
gainLin     = uiGain + 1.0        // −1→0, 0→1, +1→2
effective   = 1.0 + strength × (gainLin − 1.0)
```

- Strength **0** → all bands at linear **1.0** (no shaping).
- Strength **1** → bands at `gainLin`.
- Strength **2** → double the deviation from neutral.

Processing: Paul Dore / Baldavenger Lab L\* presplit on working-space RGB **as if Rec.709** (his RGB↔XYZ + Lab white point; no DWG↔XYZ and no Rec.709 OETF). Per-band Gaussian blur, additive L\* reconstruction. Base frequency is fixed via `kOpenTextureMtfBaseFreqUnderHoodScale`.

## DIFFUSION (Bloom)

Blender compositor bloom: HSV highlight extraction, quarter-res pyramid (**MPS Gaussian** on macOS, **CUDA Van Vliet** on Windows), tent-filter upscale, additive mix. Runs **after** Halation and MTF.

**Nits convention:** 100 nits = 1.0 linear in working space. Min/Max Highlights and nits readouts affect the **bloom source only** — they do not clamp image highlights in the final composite.

| Control | Range | Default | Notes |
|---------|-------|---------|-------|
| Enable | — | off | macOS Metal / Windows CUDA |
| Global blend | 0–1 | 1 | Mix glare vs upstream image |
| Spread | 0–1 UI | 0.5 | Log-scaled; resolution-independent bloom size (chain-1 + scaled σ at low spread; pyramid lerp from chainF ≥ 1) |
| Strength | 0–2 | 1 | Additive bloom brightness |
| Exposure shift | 0.5–2.5 | 1 | Core vs halo bloom scale (1 = identity) |
| Saturation | 0–2 | 1 | 0 = gray bloom, 2 = 2× chroma |
| Temperature | 0–1 | 0.5 | Cool ↔ warm |
| Min Highlights | 0–1 UI | 0.0 | Log-scaled bloom-source floor (100–10000 nits); cannot exceed Max |
| Min Nits | 100–10000 | 100 | Read-only nits readout synced with Min Highlights |
| Smoothness | 0–1 | 0.4 | Soft fade from Min Highlights toward shadows |
| Limit Highlights | — | on | Hard peak on bloom source only (not image highlights) |
| Max Highlights | 0–1 UI | 0.25 | Log-scaled bloom-source peak (100–10000 nits) |
| Max Nits | 100–10000 | ~316 | Read-only nits readout synced with Max Highlights |
| Display | choice | Render | Overlay: Render / Source / Diffusion |

Quality is fixed to **Low** (quarter res) internally. Source overlay uses full-res highlight extraction.

## Halation

Thatcher Freeman exposure-lost model + matrix red-shift; spread scaled to UHD reference diagonal. Optional **Effect window** masks letterbox (black outside window, edge-replicate at boundary) for both halation and MTF.

## Render path

Resolve Metal: single command buffer per frame in `LSPOpenTextureMetal::renderHost` — copy → optional MTF → halation preprocess/blur/composite → global blends → optional glare (last) → window mask/border.

Windows CUDA: `LSPOpenTextureCuda::renderHost` mirrors the same order; glare via `LSPOpenTextureGlareCuda::EncodeCuda`.

CPU fallback: halation only (`multiThreadProcessImages`); MTF enable is ignored when Metal render is off.

## Performance profiling

Set `OPEN_TEXTURE_PROFILE=1` to log per-stage ms breakdown (`halation`, `mtf`, `glare`, `total`) to `OpenTexture.log`. All GPU blur intermediates use FP32.
