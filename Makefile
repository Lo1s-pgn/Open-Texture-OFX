# LSP - Open Texture OFX — macOS (CPU; Metal may follow after DCTL parity work)
# Prefer CMake: cmake -S . -B build/macos && cmake --build build/macos --target opentexture_all
# VERSION (first line) = MAJ.MIN.PATCH [optional label] → triplet for bundle/OFX id; full line for display string
# Intermediates (.o, linked .ofx, Info.plist) → build/ ; installable .ofx.bundle → release/

BUILDDIR := build
DISTDIR := release
VERSION_FILE := VERSION
VERSION_GEN := plugin/version_gen.h
VERSION_RAW := $(shell head -n1 $(VERSION_FILE) 2>/dev/null | sed 's/\r$$//')
VERSION_TRIPLET := $(shell echo "$(VERSION_RAW)" | awk '{print $$1}')
VERSION_MAJ := $(shell echo "$(VERSION_TRIPLET)" | cut -d. -f1)
VERSION_MIN := $(shell echo "$(VERSION_TRIPLET)" | cut -d. -f2)
VERSION_PATCH := $(shell echo "$(VERSION_TRIPLET)" | cut -d. -f3)
PLUGIN_DISPLAY := $(VERSION_MAJ).$(VERSION_MIN).$(VERSION_PATCH)
OFX_BUNDLE_STEM := LSP_Open_Texture_$(PLUGIN_DISPLAY)
OFX_BUNDLE := $(DISTDIR)/$(OFX_BUNDLE_STEM).ofx.bundle
OFX_BINARY := $(BUILDDIR)/$(OFX_BUNDLE_STEM).ofx
BUNDLE_DIR = $(OFX_BUNDLE)/Contents/MacOS/
RESOURCES_DIR = $(OFX_BUNDLE)/Contents/Resources

OFX_SDK_PATH ?= openfx-sdk
ARCH_FLAGS = -arch arm64 -arch x86_64
CXXFLAGS = -std=c++20 -O2 -Wno-dynamic-exception-spec -fvisibility=hidden -Iplugin -Iplugin/core -Iplugin/presets -I"$(OFX_SDK_PATH)/include" -I"$(OFX_SDK_PATH)/Support/include" -I"$(OFX_SDK_PATH)/Support/Library" $(ARCH_FLAGS)
LDFLAGS = -bundle -fvisibility=hidden -framework Foundation -framework AppKit -framework Metal -framework MetalPerformanceShaders -Wl,-rpath,@loader_path $(ARCH_FLAGS)

PLUGIN_ICON_NAME := com.LSP.OpenTexture.$(PLUGIN_DISPLAY).png

PLUGIN_OBJ = $(BUILDDIR)/LSPOpenTextureDescribe.o $(BUILDDIR)/LSPOpenTextureProcessor.o $(BUILDDIR)/LSPOpenTexturePlugin.o $(BUILDDIR)/LSPOpenTexturePresetMenus.o $(BUILDDIR)/LSPOpenTexturePresetHelpers.o $(BUILDDIR)/LSPOpenTextureTfMapping.o $(BUILDDIR)/LSPOpenTextureGamut.o $(BUILDDIR)/LSPOpenTextureMetal.o $(BUILDDIR)/LSPOpenTexturePresetDialogs.o $(BUILDDIR)/LSPOpenTextureFreqEQBridge.o $(BUILDDIR)/LSPOpenTextureGlareBridge.o
METAL_AIR := $(BUILDDIR)/LSPOpenTextureMetal.air $(BUILDDIR)/LSPOpenTextureFreqEQ.air $(BUILDDIR)/LSPOpenTextureGlare.air
METAL_LIB := $(BUILDDIR)/LSPOpenTextureMetal.metallib
SUPPORT_OBJ = $(BUILDDIR)/ofxsCore.o $(BUILDDIR)/ofxsImageEffect.o $(BUILDDIR)/ofxsInteract.o $(BUILDDIR)/ofxsLog.o \
	$(BUILDDIR)/ofxsMultiThread.o $(BUILDDIR)/ofxsParams.o $(BUILDDIR)/ofxsProperty.o $(BUILDDIR)/ofxsPropertyValidation.o

all: $(OFX_BUNDLE) resources

resources: $(OFX_BUNDLE)
	@if [ -f ICON.png ]; then cp ICON.png $(RESOURCES_DIR)/$(PLUGIN_ICON_NAME); echo "Icon: $(RESOURCES_DIR)/$(PLUGIN_ICON_NAME)"; else echo "No ICON.png — effect icon skipped."; fi
	@cp tools/install_lsp_open_texture_ofx.command $(DISTDIR)/ && chmod +x $(DISTDIR)/install_lsp_open_texture_ofx.command && echo "Installer: $(DISTDIR)/install_lsp_open_texture_ofx.command"
	@cp tools/purge_resolve_ofx_cache.command $(DISTDIR)/ && chmod +x $(DISTDIR)/purge_resolve_ofx_cache.command && echo "Purge cache: $(DISTDIR)/purge_resolve_ofx_cache.command"

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(OFX_BINARY): $(PLUGIN_OBJ) $(SUPPORT_OBJ)
	$(CXX) $^ -o $@ $(LDFLAGS)
ifneq ($(NOSTRIP),1)
	strip -x $@
endif

$(OFX_BUNDLE): $(OFX_BINARY) $(BUILDDIR)/Info.plist $(VERSION_GEN) $(METAL_LIB)
	@mkdir -p $(DISTDIR)
	rm -rf $(OFX_BUNDLE)
	mkdir -p $(BUNDLE_DIR)
	mkdir -p $(RESOURCES_DIR)
	cp $(OFX_BINARY) $(BUNDLE_DIR)$(OFX_BUNDLE_STEM).ofx
	cp $(BUILDDIR)/Info.plist $(OFX_BUNDLE)/Contents/Info.plist
	cp $(METAL_LIB) $(RESOURCES_DIR)/LSPOpenTextureMetal.metallib
	@mkdir -p $(RESOURCES_DIR)/Presets
	@if [ -d Presets ] && [ -n "$$(find Presets -maxdepth 1 -name '*.xml' -print -quit 2>/dev/null)" ]; then \
	  cp Presets/*.xml $(RESOURCES_DIR)/Presets/; \
	  echo "Presets: copied $$(ls Presets/*.xml 2>/dev/null | wc -l | tr -d ' ') factory preset(s)"; \
	else \
	  echo "Presets: no factory XML in Presets/ (user export/import still works)"; \
	fi
	@exe=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$(OFX_BUNDLE)/Contents/Info.plist" 2>/dev/null); \
	if [ -z "$$exe" ]; then echo "ERROR: Could not read CFBundleExecutable from Info.plist"; exit 1; fi; \
	if [ ! -f "$(OFX_BUNDLE)/Contents/MacOS/$$exe" ]; then \
	  echo "ERROR: CFBundleExecutable ($$exe) must match the Mach-O basename in Contents/MacOS/."; \
	  exit 1; \
	fi; \
	bundle_base=$$(basename "$(OFX_BUNDLE)" .bundle); \
	if [ "$$bundle_base" != "$$exe" ]; then \
	  echo "ERROR: Bundle folder (minus .bundle) should equal executable name: expected $$exe, got $$bundle_base"; exit 1; \
	fi; \
	echo "Bundle ready: $(OFX_BUNDLE) (executable $$exe OK)"

$(VERSION_GEN) $(BUILDDIR)/Info.plist: Info.plist.in $(VERSION_FILE) | $(BUILDDIR)
	@raw=$$(head -n1 $(VERSION_FILE) | sed 's/\r$$//'); \
	triplet=$$(echo "$$raw" | awk '{print $$1}'); \
	suffix=$$(echo "$$raw" | cut -s -d' ' -f2-); \
	maj=$$(echo "$$triplet" | cut -d. -f1); min=$$(echo "$$triplet" | cut -d. -f2); pat=$$(echo "$$triplet" | cut -d. -f3); \
	numeric="$$maj.$$min.$$pat"; \
	if [ -n "$$suffix" ]; then display="$$triplet $$suffix"; else display="$$numeric"; fi; \
	ofxid="com.LSP.OpenTexture.$$numeric"; \
	{ echo "/* Generated from VERSION (first line) — do not edit */"; \
	  echo "#ifndef VERSION_GEN_H"; \
	  echo "#define VERSION_GEN_H"; \
	  echo "#define PLUGIN_VERSION_STR \"$$display\""; \
	  echo "#define PLUGIN_VERSION_MAJOR $$maj"; \
	  echo "#define PLUGIN_VERSION_MINOR $$min"; \
	  echo "#define PLUGIN_VERSION_PATCH $$pat"; \
	  echo "#define PLUGIN_OFX_IDENTIFIER \"$$ofxid\""; \
	  echo "#endif"; \
	} > $(VERSION_GEN); \
	stem="LSP_Open_Texture_$$numeric"; \
	exe="$$stem.ofx"; \
	sed -e "s|@PLUGIN_NUMERIC_VERSION@|$$numeric|g" \
	    -e "s|@PLUGIN_DISPLAY_VERSION@|$$display|g" \
	    -e "s|@OFX_EXECUTABLE_NAME@|$$exe|g" \
	    -e "s|@PLUGIN_OFX_IDENTIFIER@|$$ofxid|g" Info.plist.in > $(BUILDDIR)/Info.plist; \
	echo "Generated $(VERSION_GEN) + $(BUILDDIR)/Info.plist ($$display, $$exe)"

$(BUILDDIR)/LSPOpenTextureDescribe.o: plugin/core/LSPOpenTextureDescribe.cpp $(VERSION_GEN) plugin/core/LSPOpenTextureDescribe.h plugin/core/LSPOpenTextureConstants.h | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILDDIR)/LSPOpenTextureProcessor.o: plugin/core/LSPOpenTextureProcessor.cpp $(VERSION_GEN) plugin/core/LSPOpenTextureProcessor.h plugin/core/LSPOpenTextureLog.h plugin/core/LSPOpenTextureConstants.h plugin/core/LSPOpenTextureTfMapping.h | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILDDIR)/LSPOpenTexturePlugin.o: plugin/core/LSPOpenTexturePlugin.cpp $(VERSION_GEN) plugin/core/LSPOpenTexturePlugin.h plugin/core/LSPOpenTexturePluginInternal.h plugin/core/LSPOpenTextureDescribe.h plugin/core/LSPOpenTextureProcessor.h plugin/core/LSPOpenTextureConstants.h plugin/core/LSPOpenTextureLog.h plugin/presets/LSPOpenTexturePresetHelpers.h | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILDDIR)/LSPOpenTexturePresetMenus.o: plugin/core/LSPOpenTexturePresetMenus.cpp $(VERSION_GEN) plugin/core/LSPOpenTexturePluginInternal.h plugin/core/LSPOpenTexturePresetMenus.h plugin/core/LSPOpenTextureParamSchema.h plugin/presets/LSPOpenTexturePresetHelpers.h plugin/presets/LSPOpenTexturePresetDialogs.h plugin/core/LSPOpenTextureLog.h | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILDDIR)/LSPOpenTexturePresetHelpers.o: plugin/presets/LSPOpenTexturePresetHelpers.cpp $(VERSION_GEN) plugin/presets/LSPOpenTexturePresetHelpers.h | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILDDIR)/LSPOpenTexturePresetDialogs.o: plugin/metal/LSPOpenTexturePresetDialogs.mm plugin/presets/LSPOpenTexturePresetDialogs.h | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILDDIR)/LSPOpenTextureTfMapping.o: plugin/core/LSPOpenTextureTfMapping.cpp plugin/core/LSPOpenTextureTfMapping.h | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILDDIR)/LSPOpenTextureGamut.o: plugin/core/LSPOpenTextureGamut.cpp plugin/core/LSPOpenTextureGamut.h plugin/core/LSPOpenTextureHostParams.h | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILDDIR)/LSPOpenTextureMetal.o: plugin/metal/LSPOpenTextureMetal.mm plugin/metal/LSPOpenTextureMetal.h plugin/metal/LSPOpenTextureFreqEQBridge.h plugin/metal/LSPOpenTextureGlareBridge.h plugin/core/LSPOpenTextureTfMapping.h plugin/core/LSPOpenTextureGamut.h plugin/core/LSPOpenTextureHostParams.h | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILDDIR)/LSPOpenTextureFreqEQBridge.o: plugin/metal/LSPOpenTextureFreqEQBridge.mm plugin/metal/LSPOpenTextureFreqEQBridge.h | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILDDIR)/LSPOpenTextureGlareBridge.o: plugin/metal/LSPOpenTextureGlareBridge.mm plugin/metal/LSPOpenTextureGlareBridge.h | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

$(BUILDDIR)/LSPOpenTextureMetal.air: plugin/metal/LSPOpenTextureMetal.metal plugin/core/LSPOpenTextureTransfers.inc | $(BUILDDIR)
	xcrun -sdk macosx metal -c $< -o $@ -Iplugin/metal -Iplugin/core

$(BUILDDIR)/LSPOpenTextureFreqEQ.air: plugin/metal/LSPOpenTextureFreqEQ.metal plugin/core/LSPOpenTextureTransfers.inc | $(BUILDDIR)
	xcrun -sdk macosx metal -c $< -o $@ -Iplugin/metal -Iplugin/core

$(BUILDDIR)/LSPOpenTextureGlare.air: plugin/metal/LSPOpenTextureGlare.metal plugin/core/LSPOpenTextureTransfers.inc | $(BUILDDIR)
	xcrun -sdk macosx metal -c $< -o $@ -Iplugin/metal -Iplugin/core

$(METAL_LIB): $(METAL_AIR) | $(BUILDDIR)
	xcrun -sdk macosx metallib $(METAL_AIR) -o $@

$(BUILDDIR)/ofxsCore.o: $(OFX_SDK_PATH)/Support/Library/ofxsCore.cpp | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)
$(BUILDDIR)/ofxsImageEffect.o: $(OFX_SDK_PATH)/Support/Library/ofxsImageEffect.cpp | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)
$(BUILDDIR)/ofxsInteract.o: $(OFX_SDK_PATH)/Support/Library/ofxsInteract.cpp | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)
$(BUILDDIR)/ofxsLog.o: $(OFX_SDK_PATH)/Support/Library/ofxsLog.cpp | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)
$(BUILDDIR)/ofxsMultiThread.o: $(OFX_SDK_PATH)/Support/Library/ofxsMultiThread.cpp | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)
$(BUILDDIR)/ofxsParams.o: $(OFX_SDK_PATH)/Support/Library/ofxsParams.cpp | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)
$(BUILDDIR)/ofxsProperty.o: $(OFX_SDK_PATH)/Support/Library/ofxsProperty.cpp | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)
$(BUILDDIR)/ofxsPropertyValidation.o: $(OFX_SDK_PATH)/Support/Library/ofxsPropertyValidation.cpp | $(BUILDDIR)
	$(CXX) -c $< -o $@ $(CXXFLAGS)

clean:
	@chmod -R u+w $(BUILDDIR) 2>/dev/null || true
	rm -rf $(BUILDDIR)
	@if [ -d "$(DISTDIR)" ]; then \
	  chmod -R u+w "$(DISTDIR)" 2>/dev/null || true; \
	  rm -rf "$(DISTDIR)"/LSP_Open_Texture_*.ofx.bundle "$(DISTDIR)"/LSP_Open_Texture_*.ofx.bundle 2>/dev/null || true; \
	  rm -f "$(DISTDIR)"/*.zip 2>/dev/null || true; \
	fi

ifeq ($(SUDO_USER),)
RESOLVE_OFX_CACHE_HOME := $(HOME)
else
RESOLVE_OFX_CACHE_HOME := $(shell dscl . -read /Users/$(SUDO_USER) NFSHomeDirectory 2>/dev/null | sed 's/^[^:]*: *//')
ifeq ($(RESOLVE_OFX_CACHE_HOME),)
RESOLVE_OFX_CACHE_HOME := $(HOME)
endif
endif
RESOLVE_OFX_CACHE_V2 := $(RESOLVE_OFX_CACHE_HOME)/Library/Application Support/Blackmagic Design/DaVinci Resolve/OFXPluginCacheV2.xml
RESOLVE_OFX_CACHE_V1 := $(RESOLVE_OFX_CACHE_HOME)/Library/Application Support/Blackmagic Design/DaVinci Resolve/OFXPluginCache.xml

install: all
	cp -R $(OFX_BUNDLE) /Library/OFX/Plugins
	@if [ "$(SKIP_RESOLVE_OFX_CACHE_PURGE)" != 1 ]; then \
	  $(MAKE) purge; \
	  echo "Quit Resolve if it was open, then restart."; \
	else \
	  echo "Skipped OFX cache purge (SKIP_RESOLVE_OFX_CACHE_PURGE=1)."; \
	fi
	@echo "Installed $(OFX_BUNDLE_STEM).ofx.bundle — restart your OFX host."

purge_resolve_ofx_cache: purge

purge:
	@rm -f "$(RESOLVE_OFX_CACHE_V2)" "$(RESOLVE_OFX_CACHE_V1)" 2>/dev/null || true
	@echo "Purged Resolve OFX cache for $(RESOLVE_OFX_CACHE_HOME):"
	@echo "  $(RESOLVE_OFX_CACHE_V2)"
	@echo "  $(RESOLVE_OFX_CACHE_V1)"

archive:
	@./scripts/archive_version.sh

.PHONY: all clean install resources purge_resolve_ofx_cache purge archive
