#ifndef LSP_OPEN_TEXTURE_PLUGIN_H
#define LSP_OPEN_TEXTURE_PLUGIN_H

#include "ofxsImageEffect.h"

class LSPOpenTexturePluginFactory : public OFX::PluginFactoryHelper<LSPOpenTexturePluginFactory> {
public:
    LSPOpenTexturePluginFactory();
    void load() override {}
    void unload() override {}
    void describe(OFX::ImageEffectDescriptor& p_Desc) override;
    void describeInContext(OFX::ImageEffectDescriptor& p_Desc, OFX::ContextEnum p_Context) override;
    OFX::ImageEffect* createInstance(OfxImageEffectHandle p_Handle, OFX::ContextEnum p_Context) override;
};

#endif
