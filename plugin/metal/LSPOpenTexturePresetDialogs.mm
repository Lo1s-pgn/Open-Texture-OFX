#import <AppKit/AppKit.h>

#include "LSPOpenTexturePresetDialogs.h"

#include <string>

namespace {

static std::string LSPOpenTextureRunOnMainThreadReturnString(std::string (^block)(void)) {
    if ([NSThread isMainThread])
        return block();
    __block std::string result;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = block(); });
    return result;
}

static std::string LSPOpenTextureShowSavePresetDialogImpl(const char* defaultDir) {
    std::string result;
    @autoreleasepool {
        NSSavePanel* panel = [NSSavePanel savePanel];
        [panel setTitle:@"Export Open Texture Preset"];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [panel setAllowedFileTypes:@[ @"xml" ]];
#pragma clang diagnostic pop
        [panel setCanCreateDirectories:YES];
        if (defaultDir && defaultDir[0] != '\0') {
            NSString* dir = [NSString stringWithUTF8String:defaultDir];
            if (dir)
                [panel setDirectoryURL:[NSURL fileURLWithPath:dir]];
        }
        if ([panel runModal] == NSModalResponseOK) {
            NSURL* url = [panel URL];
            if (url)
                result = [[url path] UTF8String];
        }
    }
    return result;
}

static std::string LSPOpenTextureShowOpenPresetDialogImpl() {
    std::string result;
    @autoreleasepool {
        NSOpenPanel* panel = [NSOpenPanel openPanel];
        [panel setTitle:@"Import Open Texture Preset"];
        [panel setCanChooseFiles:YES];
        [panel setCanChooseDirectories:NO];
        [panel setAllowsMultipleSelection:NO];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [panel setAllowedFileTypes:@[ @"xml", @"json" ]];
#pragma clang diagnostic pop
        if ([panel runModal] == NSModalResponseOK) {
            NSURL* url = [[panel URLs] firstObject];
            if (url)
                result = [[url path] UTF8String];
        }
    }
    return result;
}

static void LSPOpenTextureShowPresetAlreadyExistsAlertImpl(const char* presetName) {
    @autoreleasepool {
        NSAlert* alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Preset already exists"];
        NSString* info = [NSString stringWithFormat:@"A preset named \"%s\" already exists in the user presets folder.", presetName ? presetName : ""];
        [alert setInformativeText:info];
        [alert setAlertStyle:NSAlertStyleWarning];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
    }
}

}

std::string LSPOpenTextureShowSavePresetDialog(const char* defaultDir) {
    return LSPOpenTextureRunOnMainThreadReturnString(^{ return LSPOpenTextureShowSavePresetDialogImpl(defaultDir); });
}

std::string LSPOpenTextureShowOpenPresetDialog() {
    return LSPOpenTextureRunOnMainThreadReturnString(^{ return LSPOpenTextureShowOpenPresetDialogImpl(); });
}

void LSPOpenTextureShowPresetAlreadyExistsAlert(const char* presetName) {
    LSPOpenTextureRunOnMainThreadReturnString(^{ LSPOpenTextureShowPresetAlreadyExistsAlertImpl(presetName); return std::string(); });
}
